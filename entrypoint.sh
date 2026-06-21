#!/usr/bin/env bash
# Entrypoint for the dev-container pod.
#
# Two jobs:
#  1. Populate the ephemeral workspace from git (blast radius = last push).
#  2. Start `code tunnel` so local VS Code (Remote-Tunnels) can attach,
#     wherever in the cluster this pod was scheduled.
#
# Auth persistence:
#   `code tunnel` stores its login + tunnel registration under
#   $HOME/.vscode-cli. We point that at a mounted Secret-backed dir so a
#   rescheduled pod reuses the same tunnel identity instead of forcing a
#   fresh GitHub device-login every time. The WORKSPACE stays ephemeral;
#   only the tiny auth blob persists. See the guide for the tradeoff.

set -euo pipefail

WORKSPACE="${WORKSPACE:-/home/dev/workspace}"
REPO_URL="${REPO_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-main}"
TUNNEL_NAME="${TUNNEL_NAME:-homelab-dev}"

echo "[entrypoint] workspace=${WORKSPACE} repo=${REPO_URL:-<none>} branch=${REPO_BRANCH}"

# --- 1a. GitHub credentials (scoped PAT) -----------------------------------
# The agent/git get EXACTLY the repo this PAT is scoped to — not the account.
# Closes the GIT_ASKPASS leak: without this, git brokered creds through the
# signed-in editor session = account-wide push. We force the scoped PAT only.
GITHUB_PAT_FILE="${GITHUB_PAT_FILE:-/var/run/secrets/devbox/github-pat}"

# Drop the editor's ambient credential broker so git can't fall back to the
# account-wide VS Code session. (Exported empty for all child processes.)
unset GIT_ASKPASS VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN \
      VSCODE_GIT_ASKPASS_EXTRA_ARGS VSCODE_GIT_IPC_HANDLE || true

if [ -s "${GITHUB_PAT_FILE}" ]; then
  echo "[entrypoint] configuring git with scoped PAT"
  export GH_TOKEN="$(tr -d '\n' < "${GITHUB_PAT_FILE}")"
  # Route git over HTTPS through the token. No gh dependency required:
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "${GH_TOKEN}" \
    > "${HOME}/.git-credentials"
  chmod 600 "${HOME}/.git-credentials"
  git config --global user.name  "${GIT_AUTHOR_NAME:-devbox}"
  git config --global user.email "${GIT_AUTHOR_EMAIL:-devbox@packetcraft.dev}"
else
  echo "[entrypoint] WARN: no PAT at ${GITHUB_PAT_FILE} — pushes will fail"
fi

# --- 1. populate workspace --------------------------------------------------
if [ -n "${REPO_URL}" ]; then
  if [ -z "$(ls -A "${WORKSPACE}" 2>/dev/null)" ]; then
    echo "[entrypoint] cloning ${REPO_URL} (${REPO_BRANCH}) into ${WORKSPACE}"
    git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${WORKSPACE}" \
      || echo "[entrypoint] WARN: clone failed (egress policy? bad URL?) — starting empty"
  else
    echo "[entrypoint] workspace not empty — skipping clone"
  fi
else
  echo "[entrypoint] no REPO_URL set — starting with empty workspace"
fi

cd "${WORKSPACE}"

# --- 2. start the tunnel ----------------------------------------------------
# --accept-server-license-terms: required for unattended start
# --name: stable tunnel name so it shows up predictably in your VS Code
# If auth isn't present yet, `code tunnel` prints a one-time device-login URL
# to the pod logs (kubectl logs). After first login the token is reused.
echo "[entrypoint] starting code tunnel as '${TUNNEL_NAME}'"
exec code tunnel \
  --accept-server-license-terms \
  --name "${TUNNEL_NAME}" 
