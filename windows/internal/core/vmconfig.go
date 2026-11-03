package core

import (
	"crypto/rand"
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type HostForward struct {
	HostPort  int
	GuestPort int
}

var forwardPattern = regexp.MustCompile(`^([0-9]+):([0-9]+)$`)

func ParseHostForward(text string) (HostForward, error) {
	m := forwardPattern.FindStringSubmatch(text)
	if m == nil {
		return HostForward{}, fmt.Errorf("forward must be HOSTPORT:GUESTPORT on 127.0.0.1, got '%s'", text)
	}
	h, _ := strconv.Atoi(m[1])
	g, _ := strconv.Atoi(m[2])
	return HostForward{h, g}, nil
}

func (f HostForward) String() string { return fmt.Sprintf("%d:%d", f.HostPort, f.GuestPort) }

type VMPaths struct {
	QEMU         string
	FirmwareCode string
	EFIVars      string
	Disk         string
	Console      string
	QEMULog      string
	QMPSocket    string
}

const (
	MinCPUs        = 2
	MinMemoryMiB   = 2048
	HostReserveMiB = 2048
	// sockaddr_un.sun_path is 108 bytes including the terminating NUL.
	MaxSocketPath = 107
)

type VMConfig struct {
	CPUs         int
	MemoryMiB    int
	FullScreen   bool
	Microphone   bool
	CPUFallback  bool
	HostForwards []HostForward
	Paths        VMPaths
	MAC          string
}

var macPattern = regexp.MustCompile(`^[0-9a-f]{2}(:[0-9a-f]{2}){5}$`)

func isWindowsAbs(p string) bool {
	if strings.HasPrefix(p, `\\`) {
		return true
	}
	return len(p) >= 3 && p[1] == ':' && (p[2] == '\\' || p[2] == '/') &&
		(p[0]|0x20 >= 'a' && p[0]|0x20 <= 'z')
}

func (c *VMConfig) Validate(host HostInfo) error {
	if c.CPUs < MinCPUs || c.CPUs > host.LogicalCPUs {
		return fmt.Errorf("cpus must be %d...%d, got %d", MinCPUs, host.LogicalCPUs, c.CPUs)
	}
	maxMemory := host.MemoryMiB - HostReserveMiB
	if c.MemoryMiB < MinMemoryMiB || c.MemoryMiB > maxMemory {
		return fmt.Errorf("memory must be %d...%d MiB, got %d", MinMemoryMiB, maxMemory, c.MemoryMiB)
	}
	seen := map[int]bool{}
	for _, f := range c.HostForwards {
		if f.HostPort < 1 || f.HostPort > 65535 || f.GuestPort < 1 || f.GuestPort > 65535 {
			return fmt.Errorf("forward ports must be 1...65535, got %s", f)
		}
		if seen[f.HostPort] {
			return fmt.Errorf("host port %d forwarded twice", f.HostPort)
		}
		seen[f.HostPort] = true
	}
	if !macPattern.MatchString(c.MAC) {
		return fmt.Errorf("MAC must be a lowercase locally administered unicast address, got '%s'", c.MAC)
	}
	if first, _ := strconv.ParseUint(c.MAC[:2], 16, 8); first&0x03 != 0x02 {
		return fmt.Errorf("MAC must be a lowercase locally administered unicast address, got '%s'", c.MAC)
	}
	p := c.Paths
	for _, e := range []struct{ name, value string }{
		{"qemu", p.QEMU}, {"firmware", p.FirmwareCode}, {"efi vars", p.EFIVars}, {"disk", p.Disk},
		{"console", p.Console}, {"qemu log", p.QEMULog}, {"qmp socket", p.QMPSocket},
	} {
		if !filepath.IsAbs(e.value) && !isWindowsAbs(e.value) {
			return fmt.Errorf("%s path must be absolute: %s", e.name, e.value)
		}
		if strings.Contains(e.value, ",") {
			return fmt.Errorf("%s path must not contain a comma: %s", e.name, e.value)
		}
	}
	if len(p.QMPSocket) > MaxSocketPath {
		return fmt.Errorf("qmp socket path longer than %d bytes: %s", MaxSocketPath, p.QMPSocket)
	}
	return nil
}

// HostMem sizes the virtio-gpu blob window by guest RAM.
func HostMem(memoryMiB int) string {
	switch {
	case memoryMiB <= 4096:
		return "1G"
	case memoryMiB <= 8192:
		return "2G"
	default:
		return "4G"
	}
}

// Argv follows the QEMU contract in docs/windows.md. Every PCI device has a
// fixed addr= because edk2 stores the boot entry by PCI path in efi-vars.fd.
func (c *VMConfig) Argv(host HostInfo) ([]string, error) {
	if err := c.Validate(host); err != nil {
		return nil, err
	}
	p := c.Paths
	cpu := "host"
	if c.CPUFallback {
		cpu = "qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes"
	}
	netdev := "user,id=net"
	for _, f := range c.HostForwards {
		netdev += fmt.Sprintf(",hostfwd=tcp:127.0.0.1:%d-:%d", f.HostPort, f.GuestPort)
	}
	display := "sdl,gl=on,show-cursor=off"
	if c.FullScreen {
		display += ",full-screen=on"
	}
	codec := "hda-output"
	if c.Microphone {
		codec = "hda-micro"
	}
	return []string{
		p.QEMU,
		"-name", "Try FydeOS",
		"-machine", "q35,accel=whpx", "-cpu", cpu, "-smp", strconv.Itoa(c.CPUs),
		"-m", fmt.Sprintf("%dM", c.MemoryMiB), "-nodefaults",
		"-action", "reboot=shutdown,shutdown=poweroff",
		"-drive", "if=pflash,format=raw,unit=0,readonly=on,file=" + p.FirmwareCode,
		"-drive", "if=pflash,format=raw,unit=1,file=" + p.EFIVars,
		"-drive", "if=none,id=root,file=" + p.Disk + ",format=raw,cache=writeback,discard=unmap",
		"-device", "virtio-blk-pci,drive=root,serial=TRYFYDEOS,bootindex=0,romfile=,addr=0x3",
		"-netdev", netdev,
		"-device", "virtio-net-pci,id=nic,netdev=net,mac=" + c.MAC + ",romfile=,addr=0x4",
		"-device", "virtio-vga-gl,id=gpu,blob=on,hostmem=" + HostMem(c.MemoryMiB) + ",addr=0x5",
		"-display", display,
		"-device", "virtio-keyboard-pci,id=keyboard,romfile=,addr=0x6",
		"-device", "virtio-tablet-pci,id=tablet,romfile=,addr=0x7",
		"-audiodev", "sdl,id=audio", "-device", "intel-hda,id=hda,romfile=,addr=0x1b",
		"-device", codec + ",bus=hda.0,audiodev=audio",
		"-device", "virtio-rng-pci,id=rng,romfile=,addr=0x8",
		"-chardev", "qemu-vdagent,id=vdagent,clipboard=on,mouse=off",
		"-device", "virtio-serial-pci,id=vserial,romfile=,addr=0x9",
		"-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0",
		"-serial", "file:" + p.Console, "-D", p.QEMULog, "-monitor", "none",
		"-qmp", "unix:" + p.QMPSocket + ",server=on,wait=off",
	}, nil
}

func RandomMAC() string {
	b := make([]byte, 3)
	rand.Read(b)
	return fmt.Sprintf("52:54:00:%02x:%02x:%02x", b[0], b[1], b[2])
}
