package app

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"

	"tryfydeos.io/windows/internal/core"
)

const MemoryStepMiB = 1024

// Preferences are the start menu's settings. They share preferences.json with
// the hidden workspace and forwards keys that core.DiscoverLocations reads.
type Preferences struct {
	CPUs       int
	MemoryMiB  int
	FullScreen bool
	Microphone bool
}

func CPUChoices(host core.HostInfo) []int {
	var c []int
	for n := core.MinCPUs; n <= max(core.MinCPUs, host.LogicalCPUs); n++ {
		c = append(c, n)
	}
	return c
}

func MemoryChoices(host core.HostInfo) []int {
	var c []int
	top := max(core.MinMemoryMiB, host.MemoryMiB-core.HostReserveMiB)
	for m := core.MinMemoryMiB; m <= top; m += MemoryStepMiB {
		c = append(c, m)
	}
	return c
}

func DefaultPreferences(host core.HostInfo) Preferences {
	return Preferences{CPUs: 4, MemoryMiB: 8192, FullScreen: true}.Clamped(host)
}

// Clamped snaps CPUs and memory to the nearest offered choice at or below the value.
func (p Preferences) Clamped(host core.HostInfo) Preferences {
	cpus := CPUChoices(host)
	p.CPUs = min(max(p.CPUs, cpus[0]), cpus[len(cpus)-1])
	memory := MemoryChoices(host)
	snapped := memory[0]
	for _, m := range memory {
		if m <= p.MemoryMiB {
			snapped = m
		}
	}
	p.MemoryMiB = snapped
	return p
}

type preferencesFile struct {
	CPUs       *int  `json:"cpus"`
	MemoryMiB  *int  `json:"memoryMiB"`
	FullScreen *bool `json:"fullScreen"`
	Microphone *bool `json:"microphone"`
}

// LoadPreferences returns the defaults for keys the file lacks; a missing file is no error,
// an unreadable one returns the defaults with the error.
func LoadPreferences(path string, host core.HostInfo) (Preferences, error) {
	p := DefaultPreferences(host)
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return p, nil
	}
	var f preferencesFile
	if err == nil {
		err = json.Unmarshal(data, &f)
	}
	if err != nil {
		return p, err
	}
	if f.CPUs != nil {
		p.CPUs = *f.CPUs
	}
	if f.MemoryMiB != nil {
		p.MemoryMiB = *f.MemoryMiB
	}
	if f.FullScreen != nil {
		p.FullScreen = *f.FullScreen
	}
	if f.Microphone != nil {
		p.Microphone = *f.Microphone
	}
	return p.Clamped(host), nil
}

// Save rewrites the four keys and keeps every other key of the file.
func (p Preferences) Save(path string) error {
	all := map[string]any{}
	if data, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(data, &all); err != nil {
			return err
		}
	}
	all["cpus"] = p.CPUs
	all["memoryMiB"] = p.MemoryMiB
	all["fullScreen"] = p.FullScreen
	all["microphone"] = p.Microphone
	data, err := json.MarshalIndent(all, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (p Preferences) LaunchOptions(forwards []core.HostForward) core.LaunchOptions {
	return core.LaunchOptions{CPUs: p.CPUs, MemoryMiB: p.MemoryMiB, FullScreen: p.FullScreen, Microphone: p.Microphone, HostForwards: forwards}
}
