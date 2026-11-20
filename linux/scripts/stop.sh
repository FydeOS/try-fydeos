#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${TRY_FYDEOS_DATA:-$HOME/.local/share/Try FydeOS}"
PID_DIR="$DATA_DIR/run"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  export TRY_FYDEOS_GUAC_HOME="$DATA_DIR/guacamole/config"
  export TRY_FYDEOS_GUAC_PORT="${TRY_FYDEOS_GUAC_PORT:-8080}"
  docker compose -f "$ROOT/linux/guacamole-compose.yml" down
fi

for name in novnc vnc qemu xvfb; do
  pid_file="$PID_DIR/$name.pid"
  if [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      for _ in {1..50}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "linux/stop: $name did not stop (pid $pid)" >&2
        exit 1
      fi
    fi
    rm -f "$pid_file"
  fi
done
