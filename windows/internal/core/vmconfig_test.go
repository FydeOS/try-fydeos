package core

import (
	"reflect"
	"strings"
	"testing"
)

var testHost = HostInfo{LogicalCPUs: 8, MemoryMiB: 16384}

func testConfig() *VMConfig {
	return &VMConfig{
		CPUs: 2, MemoryMiB: 3072, MAC: "52:54:00:12:34:56",
		HostForwards: []HostForward{{2201, 22}},
		Paths: VMPaths{
			QEMU:         `D:\rt\bin\qemu-system-x86_64w.exe`,
			FirmwareCode: `D:\rt\bin\share\edk2-x86_64-code.fd`,
			EFIVars:      `D:\vm\efi-vars.fd`,
			Disk:         `D:\vm\disk.raw`,
			Console:      `D:\vm\runs\1\console.log`,
			QEMULog:      `D:\vm\runs\1\qemu.log`,
			QMPSocket:    `D:\vm\qmp.sock`,
		},
	}
}

func TestArgvMatchesContract(t *testing.T) {
	argv, err := testConfig().Argv(testHost)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		`D:\rt\bin\qemu-system-x86_64w.exe`,
		"-name", "Try FydeOS",
		"-machine", "q35,accel=whpx", "-cpu", "host", "-smp", "2", "-m", "3072M", "-nodefaults",
		"-action", "reboot=shutdown,shutdown=poweroff",
		"-drive", `if=pflash,format=raw,unit=0,readonly=on,file=D:\rt\bin\share\edk2-x86_64-code.fd`,
		"-drive", `if=pflash,format=raw,unit=1,file=D:\vm\efi-vars.fd`,
		"-drive", `if=none,id=root,file=D:\vm\disk.raw,format=raw,cache=writeback,discard=unmap`,
		"-device", "virtio-blk-pci,drive=root,serial=TRYFYDEOS,bootindex=0,romfile=,addr=0x3",
		"-netdev", "user,id=net,hostfwd=tcp:127.0.0.1:2201-:22",
		"-device", "virtio-net-pci,id=nic,netdev=net,mac=52:54:00:12:34:56,romfile=,addr=0x4",
		"-device", "virtio-vga-gl,id=gpu,blob=on,hostmem=1G,addr=0x5",
		"-display", "sdl,gl=on,show-cursor=off",
		"-device", "virtio-keyboard-pci,id=keyboard,romfile=,addr=0x6",
		"-device", "virtio-tablet-pci,id=tablet,romfile=,addr=0x7",
		"-audiodev", "sdl,id=audio", "-device", "intel-hda,id=hda,romfile=,addr=0x1b",
		"-device", "hda-output,bus=hda.0,audiodev=audio",
		"-device", "virtio-rng-pci,id=rng,romfile=,addr=0x8",
		"-chardev", "qemu-vdagent,id=vdagent,clipboard=on,mouse=off",
		"-device", "virtio-serial-pci,id=vserial,romfile=,addr=0x9",
		"-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0",
		"-serial", `file:D:\vm\runs\1\console.log`, "-D", `D:\vm\runs\1\qemu.log`, "-monitor", "none",
		"-qmp", `unix:D:\vm\qmp.sock,server=on,wait=off`,
	}
	if !reflect.DeepEqual(argv, want) {
		t.Fatalf("argv\n%s\nwant\n%s", strings.Join(argv, "\n"), strings.Join(want, "\n"))
	}
}

func TestArgvOptions(t *testing.T) {
	c := testConfig()
	c.FullScreen = true
	c.Microphone = true
	c.CPUFallback = true
	c.HostForwards = nil
	argv, err := c.Argv(testHost)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(argv, " ")
	for _, s := range []string{"-cpu qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes ", "-display sdl,gl=on,show-cursor=off,full-screen=on ", "-netdev user,id=net ", "-device hda-micro,bus=hda.0,audiodev=audio "} {
		if !strings.Contains(joined, s) {
			t.Errorf("missing %q in %s", s, joined)
		}
	}
}

func TestHostMem(t *testing.T) {
	for mem, want := range map[int]string{2048: "1G", 4096: "1G", 4097: "2G", 8192: "2G", 8193: "4G", 12288: "4G"} {
		if got := HostMem(mem); got != want {
			t.Errorf("HostMem(%d) = %s, want %s", mem, got, want)
		}
	}
}

func TestValidateRejects(t *testing.T) {
	for name, mutate := range map[string]func(*VMConfig){
		"cpus low":      func(c *VMConfig) { c.CPUs = 1 },
		"cpus high":     func(c *VMConfig) { c.CPUs = 9 },
		"memory low":    func(c *VMConfig) { c.MemoryMiB = 1024 },
		"memory high":   func(c *VMConfig) { c.MemoryMiB = 16384 },
		"forward port":  func(c *VMConfig) { c.HostForwards = []HostForward{{70000, 22}} },
		"forward twice": func(c *VMConfig) { c.HostForwards = []HostForward{{2201, 22}, {2201, 23}} },
		"mac multicast": func(c *VMConfig) { c.MAC = "53:54:00:12:34:56" },
		"mac upper":     func(c *VMConfig) { c.MAC = "52:54:00:AB:34:56" },
		"relative":      func(c *VMConfig) { c.Paths.Disk = `vm\disk.raw` },
		"comma":         func(c *VMConfig) { c.Paths.Disk = `D:\a,b\disk.raw` },
		"long socket":   func(c *VMConfig) { c.Paths.QMPSocket = `D:\` + strings.Repeat("x", 120) },
	} {
		c := testConfig()
		mutate(c)
		if _, err := c.Argv(testHost); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestParseHostForward(t *testing.T) {
	if f, err := ParseHostForward("2201:22"); err != nil || f != (HostForward{2201, 22}) {
		t.Fatalf("got %v %v", f, err)
	}
	for _, bad := range []string{"", "22", "a:b", "1:2:3", "-1:22", " 1:2"} {
		if _, err := ParseHostForward(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
	if !macPattern.MatchString(RandomMAC()) {
		t.Error("RandomMAC malformed")
	}
}
