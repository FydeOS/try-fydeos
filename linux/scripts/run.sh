#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATA_DIR="${TRY_FYDEOS_DATA:-$HOME/.local/share/Try FydeOS}"
VM_DIR="$DATA_DIR/VM/v1"
DISK="$VM_DIR/fydeos.raw"
GUAC_PORT="${TRY_FYDEOS_GUAC_PORT:-8080}"
VNC_PORT="${TRY_FYDEOS_VNC_PORT:-5901}"
PID_DIR="$DATA_DIR/run"
X_DISPLAY="${TRY_FYDEOS_X_DISPLAY:-:99}"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "linux/run: Docker Engine and Compose are required for Apache Guacamole" >&2
  exit 1
fi

if ! DOCKER_GATEWAY="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"; then
  echo "linux/run: could not determine the Docker bridge address for VNC" >&2
  exit 1
fi
if [[ -z "$DOCKER_GATEWAY" ]]; then
  echo "linux/run: Docker bridge has no gateway address" >&2
  exit 1
fi

"$ROOT/linux/scripts/prepare.sh"
mkdir -p "$PID_DIR"

find_ovmf() {
  for candidate in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/qemu/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [[ -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

OVMF_CODE="$(find_ovmf)" || {
  echo "linux/run: OVMF code firmware not found" >&2
  exit 1
}

if [[ -f "$PID_DIR/qemu.pid" ]] && kill -0 "$(cat "$PID_DIR/qemu.pid")" 2>/dev/null; then
  echo "FydeOS is already running"
else
  if [[ -f "$PID_DIR/xvfb.pid" ]] && kill -0 "$(cat "$PID_DIR/xvfb.pid")" 2>/dev/null; then
    :
  else
    Xvfb "$X_DISPLAY" -screen 0 1920x1080x24 +extension GLX -noreset \
      >"$PID_DIR/xvfb.log" 2>&1 &
    echo $! >"$PID_DIR/xvfb.pid"
    for _ in {1..50}; do
      [[ -S "/tmp/.X11-unix/X${X_DISPLAY#:}" ]] && break
      sleep 0.1
    done
    if ! kill -0 "$(cat "$PID_DIR/xvfb.pid")" 2>/dev/null; then
      echo "linux/run: Xvfb failed to start; see $PID_DIR/xvfb.log" >&2
      exit 1
    fi
  fi

  if [[ -f "$PID_DIR/vnc.pid" ]] && kill -0 "$(cat "$PID_DIR/vnc.pid")" 2>/dev/null; then
    :
  else
    x11vnc -display "$X_DISPLAY" -forever -shared -listen "$DOCKER_GATEWAY" -noxdamage \
      -rfbport "$VNC_PORT" >"$PID_DIR/vnc.log" 2>&1 &
    echo $! >"$PID_DIR/vnc.pid"
    sleep 1
    if ! kill -0 "$(cat "$PID_DIR/vnc.pid")" 2>/dev/null; then
      echo "linux/run: x11vnc failed to start; see $PID_DIR/vnc.log" >&2
      exit 1
    fi
  fi

  ACCEL="tcg"
  CPU="qemu64"
  if [[ -e /dev/kvm ]] && [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ACCEL="kvm"
    CPU="host"
  fi

  DISPLAY="$X_DISPLAY" \
    LIBGL_ALWAYS_SOFTWARE=1 \
    qemu-system-x86_64 \
    -name "Try FydeOS" \
    -machine "q35,accel=$ACCEL" \
    -cpu "$CPU" \
    -smp "$(getconf _NPROCESSORS_ONLN)" \
    -m 4096 \
    -nodefaults \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,unit=1,file=$VM_DIR/OVMF_VARS.fd" \
    -drive "if=none,id=root,file=$DISK,format=raw,cache=writeback,discard=unmap" \
    -device "virtio-blk-pci,drive=root,serial=TRYFYDEOS,bootindex=0" \
    -netdev "user,id=net,hostfwd=tcp:127.0.0.1:2200-:22" \
    -device "virtio-net-pci,id=nic,netdev=net" \
    -device "virtio-vga-gl,id=gpu,xres=1920,yres=1080" \
    -display gtk,gl=on,full-screen=on,zoom-to-fit=on \
    -device "virtio-keyboard-pci" \
    -device "virtio-tablet-pci" \
    -object "rng-random,id=rng,filename=/dev/urandom" \
    -device "virtio-rng-pci,rng=rng" \
    -serial "file:$VM_DIR/console.log" \
    -monitor none \
    -qmp "unix:$VM_DIR/qmp.sock,server=on,wait=off" \
    -daemonize \
    -pidfile "$PID_DIR/qemu.pid"
fi

# Xvfb has no window manager to apply GTK's fullscreen hint.
if ! command -v xwininfo >/dev/null 2>&1; then
  echo "linux/run: xwininfo is required to size the virtual display (run make linux-install)" >&2
  exit 1
fi
QEMU_WINDOW=""
for _ in {1..50}; do
  QEMU_WINDOW="$(xwininfo -display "$X_DISPLAY" -root -tree 2>/dev/null | awk '/"QEMU \(Try FydeOS/ {print $1; exit}')"
  [[ -n "$QEMU_WINDOW" ]] && break
  sleep 0.1
done
if [[ -z "$QEMU_WINDOW" ]]; then
  echo "linux/run: could not find the FydeOS display window" >&2
  exit 1
fi
python3 - "$X_DISPLAY" "$QEMU_WINDOW" <<'PY'
import ctypes
import sys

x11 = ctypes.CDLL("libX11.so.6")
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XMoveResizeWindow.argtypes = [
    ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
    ctypes.c_uint, ctypes.c_uint,
]
x11.XMoveResizeWindow.restype = ctypes.c_int
x11.XFlush.argtypes = [ctypes.c_void_p]
x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
x11.XCloseDisplay.restype = ctypes.c_int

display = x11.XOpenDisplay(sys.argv[1].encode())
if not display:
    raise SystemExit(f"linux/run: could not open X display {sys.argv[1]}")
try:
    if not x11.XMoveResizeWindow(display, int(sys.argv[2], 16), 0, 0, 1920, 1080):
        raise SystemExit("linux/run: could not resize the FydeOS display window")
    x11.XFlush(display)
finally:
    x11.XCloseDisplay(display)
PY

GUAC_HOME="$DATA_DIR/guacamole"
CONFIG_DIR="$GUAC_HOME/config"
mkdir -p "$CONFIG_DIR"
chmod 700 "$GUAC_HOME"
chmod 755 "$CONFIG_DIR"
if [[ ! -s "$GUAC_HOME/password" ]]; then
  (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(24))' >"$GUAC_HOME/password")
fi
chmod 600 "$GUAC_HOME/password"
GUAC_PASSWORD="$(cat "$GUAC_HOME/password")"
cat >"$CONFIG_DIR/user-mapping.xml" <<XML
<user-mapping>
    <authorize username="fydeos" password="$GUAC_PASSWORD">
        <connection name="FydeOS">
            <protocol>vnc</protocol>
            <param name="hostname">host.docker.internal</param>
            <param name="port">$VNC_PORT</param>
        </connection>
    </authorize>
</user-mapping>
XML
chmod 644 "$CONFIG_DIR/user-mapping.xml"

export TRY_FYDEOS_GUAC_HOME="$CONFIG_DIR"
export TRY_FYDEOS_GUAC_PORT="$GUAC_PORT"
docker compose -f "$ROOT/linux/guacamole-compose.yml" up -d

ready=0
for _ in {1..60}; do
  if curl --fail --silent --output /dev/null "http://127.0.0.1:${GUAC_PORT}/"; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then
  echo "linux/run: Apache Guacamole did not become ready; see Docker Compose logs" >&2
  docker compose -f "$ROOT/linux/guacamole-compose.yml" logs >&2
  exit 1
fi

if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
  echo "FydeOS Apache Guacamole: https://${CODESPACE_NAME}-${GUAC_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/"
else
  echo "FydeOS Apache Guacamole: http://127.0.0.1:${GUAC_PORT}/"
fi
echo "Guacamole username: fydeos"
echo "Guacamole password file: $GUAC_HOME/password"
