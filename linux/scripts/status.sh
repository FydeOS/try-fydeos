#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${TRY_FYDEOS_DATA:-$HOME/.local/share/Try FydeOS}"
PID_DIR="$DATA_DIR/run"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUAC_PORT="${TRY_FYDEOS_GUAC_PORT:-8080}"
export TRY_FYDEOS_GUAC_HOME="$DATA_DIR/guacamole/config"
export TRY_FYDEOS_GUAC_PORT="$GUAC_PORT"

for name in qemu xvfb vnc; do
  pid_file="$PID_DIR/$name.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "$name: running (pid $(cat "$pid_file"))"
  else
    echo "$name: stopped"
  fi
done
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if docker compose -f "$ROOT/linux/guacamole-compose.yml" ps --status running --services | grep -qx guacamole; then
    echo "guacamole: running"
  else
    echo "guacamole: stopped"
  fi
else
  echo "guacamole: Docker Compose unavailable"
fi
if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
  echo "FydeOS in Apache Guacamole: https://${CODESPACE_NAME}-${GUAC_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/"
else
  echo "FydeOS in Apache Guacamole: http://127.0.0.1:${GUAC_PORT}/"
fi
echo "Log in as fydeos; password file: $DATA_DIR/guacamole/password"
