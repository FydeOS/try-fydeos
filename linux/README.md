# Try FydeOS in a browser

This Linux host setup runs the stock amd64 FydeOS VMware image under QEMU and
serves its VNC display through Apache Guacamole. It works on an x86-64
Chromebook with the Linux Development Environment enabled, or on a regular
Linux PC.

This setup needs KVM and a working OpenGL renderer. It uses Xvfb with Mesa's
software renderer when the container has no GPU render node; this is slower
than hardware graphics. KVM and Docker Compose must be available to the host.

## Install

On Debian or Ubuntu:

```sh
make linux-install
make linux-prepare
make linux-run
```

Docker Engine and the Docker Compose plugin must be installed separately.
`make linux-install` installs the QEMU/display dependencies only.

Open `http://localhost:8080/` in Chrome and sign in with username `fydeos`.
The generated password is stored at
`~/.local/share/Try FydeOS/guacamole/password`. The first boot opens FydeOS
setup; complete it in the browser. The virtual display is 1920x1080.
The QEMU display uses Virtio VGA at 1920x1080 and starts full-screen, so the
Guacamole view stays wide and centered.

On a local Chromebook Linux container, use `http://penguin.linux.test:8080/`.
In a remote VS Code workspace, open the URL printed by `make linux-run` or
open port `8080` from the Ports panel. Guacamole requires a login; keep the
forwarded port private.

Stop the VM and Guacamole with:

```sh
make linux-stop
```

The image is downloaded once and stored under
`~/.local/share/Try FydeOS/images`. VM data is stored under
`~/.local/share/Try FydeOS/VM/v1`. Set `TRY_FYDEOS_DATA` to use another
directory.
