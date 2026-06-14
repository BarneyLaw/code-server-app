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
  --name "${TUNNEL_NAME}" \
  --random-name=false
