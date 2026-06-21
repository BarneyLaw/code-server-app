# Dev-container image for the homelab cluster.
# Runs Microsoft's `code tunnel` host so your LOCAL VS Code (Remote-Tunnels)
# attaches to whatever node K3s schedules this onto.
#
# Design notes:
#  - Non-root user `dev` (uid 1000). The pod spec also enforces runAsNonRoot,
#    so the image must not need root at runtime.
#  - Toolchain is baked in at build time so a freshly-scheduled pod is ready
#    immediately — no apt-get on startup (which the egress policy would block
#    anyway, since the policy denies general internet).
#  - No secrets in the image. Tunnel auth happens at runtime (see entrypoint).
 
FROM debian:12-slim
 
ARG TARGETARCH=amd64
 
# --- base tooling -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git openssh-client gnupg \
        build-essential pkg-config \
        python3 python3-pip python3-venv \
        jq ripgrep fd-find less vim tini \
    && rm -rf /var/lib/apt/lists/*
 
# --- Go ---------------------------------------------------------------------
ARG GO_VERSION=1.22.4
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
      | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:/home/dev/go/bin:${PATH}"
ENV GOPATH="/home/dev/go"
 
# --- Rust (installed per-user below so it lands in the dev homedir) ---------
 
# --- kubectl ----------------------------------------------------------------
RUN curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl
 
# --- Node.js 24 ----------------------------------------------------------------
ARG NODE_VERSION=24
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*
 
# --- Codex CLI (for AI-assisted coding) ------------------------------------------------
RUN npm install -g @openai/codex
 
# --- Flutter prerequisites (system libs; SDK is installed per-user below) ----
# Added for the budget-app environment. Android SDK is NOT baked in here — for
# `flutter test` / analyze / desktop builds these suffice. Android cmdline-tools
# can be layered later if you need on-device/APK builds from the box.
RUN apt-get update && apt-get install -y --no-install-recommends \
        unzip xz-utils zip libglu1-mesa \
        clang cmake ninja-build pkg-config libgtk-3-dev \
    && rm -rf /var/lib/apt/lists/*
 
# --- VS Code CLI (the `code` binary that hosts the tunnel) ------------------
# Use the stable update API (returns the tarball directly). The old
# code.visualstudio.com/sha/download redirect endpoint 404s intermittently.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) VSCODE_ARCH="cli-linux-x64" ;; \
      arm64) VSCODE_ARCH="cli-linux-arm64" ;; \
      *) echo "unsupported arch ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL "https://update.code.visualstudio.com/latest/${VSCODE_ARCH}/stable" \
      -o /tmp/vscode-cli.tar.gz; \
    tar -xzf /tmp/vscode-cli.tar.gz -C /usr/local/bin; \
    rm /tmp/vscode-cli.tar.gz; \
    chmod +x /usr/local/bin/code
 
# --- non-root user ----------------------------------------------------------
RUN useradd -m -u 1000 -s /bin/bash dev
USER dev
WORKDIR /home/dev
 
# Rust for the dev user
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path
ENV PATH="/home/dev/.cargo/bin:${PATH}"
 
# Flutter SDK for the dev user (writable tool cache at runtime).
ARG FLUTTER_VERSION=3.27.1
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} \
        https://github.com/flutter/flutter.git /home/dev/flutter
ENV PATH="/home/dev/flutter/bin:/home/dev/flutter/bin/cache/dart-sdk/bin:${PATH}"
# Warm the cache + disable telemetry so first runtime `flutter` is fast/offline.
RUN flutter --version \
    && flutter config --no-analytics \
    && dart --disable-analytics \
    && flutter precache --universal
 
# Workspace mountpoint (an emptyDir is mounted here by the pod spec)
RUN mkdir -p /home/dev/workspace
WORKDIR /home/dev/workspace
 
# --- toolchain PATH + git-leak closure for ALL shell types ------------------
# The image ENV PATH and ~/.bashrc only reach SOME shells. Agents run
# `bash -c "..."` (non-interactive, non-login) which sources neither — that's
# why Codex couldn't find `flutter` while interactive shells could. Fix it at
# the two places every shell type actually reads:
#   - /etc/profile.d/*.sh : interactive login shells (you, VS Code terminal)
#   - $BASH_ENV file      : non-interactive `bash -c` (agents like Codex)
# The BASH_ENV file also unsets the VS Code GIT_ASKPASS broker so a leaked
# editor session can't override the scoped PAT in agent shells.
USER root
RUN PATHLINE='export PATH="/home/dev/flutter/bin:/home/dev/flutter/bin/cache/dart-sdk/bin:/home/dev/.cargo/bin:/usr/local/go/bin:/home/dev/go/bin:$PATH"' ; \
    printf '%s\n' "$PATHLINE" > /etc/profile.d/devbox-path.sh ; \
    { printf '%s\n' "$PATHLINE" ; \
      printf 'unset GIT_ASKPASS VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_EXTRA_ARGS VSCODE_GIT_IPC_HANDLE\n' ; \
    } > /etc/devbox-bashenv.sh ; \
    chmod 644 /etc/profile.d/devbox-path.sh /etc/devbox-bashenv.sh
 
# Git: force the scoped PAT (credential store) as the ONLY credential path,
# system-wide, independent of any shell/env. Empty askPass = git never shells
# out to GIT_ASKPASS even if the env var leaks back into a process tree.
RUN git config --system credential.helper store \
    && git config --system core.askPass ""
 
ENV BASH_ENV=/etc/devbox-bashenv.sh
USER dev
 
COPY --chown=dev:dev --chmod=755 entrypoint.sh /home/dev/entrypoint.sh
 
ENTRYPOINT ["/usr/bin/tini", "--", "/home/dev/entrypoint.sh"]
