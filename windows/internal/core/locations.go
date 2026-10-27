package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// QEMUNames in order of preference: the GUI-subsystem build opens no console window.
var QEMUNames = []string{"qemu-system-x86_64w.exe", "qemu-system-x86_64.exe"}

type Preferences struct {
	Forwards  []string `json:"forwards,omitempty"`
	Workspace string   `json:"workspace,omitempty"`
}

type Locations struct {
	AppData              string
	Runtime              string
	Spec                 string
	FactoryImageOverride string
	Workspace            string
	Forwards             []HostForward
}

func (l *Locations) LogsDir() string         { return filepath.Join(l.AppData, "Logs") }
func (l *Locations) PreferencesFile() string { return filepath.Join(l.AppData, "preferences.json") }
func (l *Locations) share() string           { return filepath.Join(l.Runtime, "bin", "share") }
func (l *Locations) FirmwareCode() string    { return filepath.Join(l.share(), "edk2-x86_64-code.fd") }
func (l *Locations) VarsTemplate() string    { return filepath.Join(l.share(), "edk2-i386-vars.fd") }

func (l *Locations) QEMU() string {
	bin := filepath.Join(l.Runtime, "bin")
	for _, name := range QEMUNames {
		if st, err := os.Stat(filepath.Join(bin, name)); err == nil && st.Mode().IsRegular() {
			return filepath.Join(bin, name)
		}
	}
	return filepath.Join(bin, QEMUNames[0])
}

// FactoryImageCandidates: TRY_FYDEOS_FACTORY_IMAGE, then the spec's own directory.
func (l *Locations) FactoryImageCandidates(spec *FactorySpec) []string {
	var c []string
	if l.FactoryImageOverride != "" {
		c = append(c, l.FactoryImageOverride)
	}
	return append(c, filepath.Join(filepath.Dir(l.Spec), spec.Image.File))
}

func (l *Locations) FactoryImage(spec *FactorySpec) (string, error) {
	candidates := l.FactoryImageCandidates(spec)
	for _, p := range candidates {
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() {
			return p, nil
		}
	}
	return "", fmt.Errorf("FydeOS image %s not found (looked at: %s)", spec.Image.File, strings.Join(candidates, ", "))
}

// DiscoverLocations resolves defaults next to the executable and under
// %LOCALAPPDATA%\Try FydeOS; preferences.json and then TRY_FYDEOS_* override them
// (TRY_FYDEOS_SPEC wins over the spec next to TRY_FYDEOS_FACTORY_IMAGE).
func DiscoverLocations(getenv func(string) string, exeDir string) (*Locations, error) {
	local := getenv("LOCALAPPDATA")
	if local == "" {
		return nil, errors.New("LOCALAPPDATA is not set")
	}
	l := &Locations{
		AppData: filepath.Join(local, "Try FydeOS"),
		Runtime: filepath.Join(exeDir, "runtime"),
		Spec:    filepath.Join(exeDir, "factory", SpecFileName),
	}
	l.Workspace = filepath.Join(l.AppData, "VM", "v1")

	var prefs Preferences
	data, err := os.ReadFile(l.PreferencesFile())
	switch {
	case err == nil:
		if err := json.Unmarshal(data, &prefs); err != nil {
			return nil, fmt.Errorf("%s: %w", l.PreferencesFile(), err)
		}
	case !errors.Is(err, fs.ErrNotExist):
		return nil, err
	}
	if prefs.Workspace != "" {
		l.Workspace = prefs.Workspace
	}
	forwards := prefs.Forwards
	if v := getenv("TRY_FYDEOS_FORWARDS"); v != "" {
		forwards = strings.Split(v, ",")
	}
	for _, f := range forwards {
		hf, err := ParseHostForward(strings.TrimSpace(f))
		if err != nil {
			return nil, err
		}
		l.Forwards = append(l.Forwards, hf)
	}
	if v := getenv("TRY_FYDEOS_WORKSPACE"); v != "" {
		l.Workspace = v
	}
	if v := getenv("TRY_FYDEOS_RUNTIME"); v != "" {
		l.Runtime = v
	}
	if v := getenv("TRY_FYDEOS_FACTORY_IMAGE"); v != "" {
		l.FactoryImageOverride = v
		l.Spec = filepath.Join(filepath.Dir(v), SpecFileName)
	}
	if v := getenv("TRY_FYDEOS_SPEC"); v != "" {
		l.Spec = v
	}
	return l, nil
}
