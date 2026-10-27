package main

import "testing"

func TestKeep(t *testing.T) {
	for rel, want := range map[string]bool{
		"README.txt": true, "LICENSES/qemu/COPYING": true, "provenance/build.json": true, "other.txt": false,
		"bin/qemu-system-x86_64w.exe": true, "bin/qemu-system-x86_64.exe": false, "bin/qemu-img.exe": false,
		"bin/SDL2.dll": true, "bin/share/edk2-x86_64-code.fd": true, "bin/share/edk2-i386-vars.fd": true,
		"bin/share/edk2-aarch64-code.fd": false, "bin/share/edk2-riscv-vars.fd": false, "bin/share/slof.bin": false,
		"bin/share/vgabios-virtio.bin": true, "bin/share/keymaps/en-us": true, "bin/share/firmware/60-edk2-arm.json": true,
	} {
		if keep(rel) != want {
			t.Errorf("keep(%s) = %t", rel, !want)
		}
	}
}
