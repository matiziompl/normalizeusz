#!/usr/bin/env bash
# entrypoint.sh - Container privilege wrapper for normalizeusz
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
QUEUE_BASE_DIR="/tmp/normalizeusz"

# Configure group for PGID
GROUP_NAME="$(getent group "${PGID}" 2>/dev/null | cut -d: -f1 || true)"
if [[ -z "${GROUP_NAME}" ]]; then
  GROUP_NAME="appgroup"
  addgroup -g "${PGID}" -S "${GROUP_NAME}" 2>/dev/null || true
fi

# Configure user for PUID
USER_NAME="$(getent passwd "${PUID}" 2>/dev/null | cut -d: -f1 || true)"
if [[ -z "${USER_NAME}" ]]; then
  USER_NAME="appuser"
  adduser -u "${PUID}" -G "${GROUP_NAME}" -S -D -H "${USER_NAME}" 2>/dev/null || true
fi

# Ensure queue and scanned directories exist with correct permissions
mkdir -p "${QUEUE_BASE_DIR}/queue" "${QUEUE_BASE_DIR}/scanned"
chown -R "${PUID}:${PGID}" "${QUEUE_BASE_DIR}"

TARGET_CMD=( "/usr/local/bin/watcher.sh" )
if [[ "$#" -gt 0 ]]; then
  TARGET_CMD=( "$@" )
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [normalizeusz-entrypoint] Dropping privileges to UID:GID (${PUID}:${PGID})..."

if [[ "${TEST_MODE:-false}" == "true" ]]; then
  su-exec "${PUID}:${PGID}" "${TARGET_CMD[@]}"
else
  exec su-exec "${PUID}:${PGID}" "${TARGET_CMD[@]}"
fi
