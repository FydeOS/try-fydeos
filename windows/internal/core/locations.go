package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"tryfydeos.io/windows/internal/payload"
)

// QEMUNames in order of preference: the GUI-subsystem build opens no console window.
var QEMUNames = []string{"qemu-system-x86_64w.exe", "qemu-system-x86_64.exe"}

type Preferences struct {
	Forwards  []string `json:"forwards,omitempty"`
	Workspace string   `json:"workspace,omitempty"`
}

type Locations struct {
	AppData string
	Runtime string
	// Spec is empty when the spec comes from the payload.
	Spec                 string
	FactoryImageOverride string
	Workspace            string
	Forwards             []HostForward
	// Payload is the data appended to a packaged exe, nil in a development build.
	Payload *payload.Payload
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

// RuntimeBuild is the first line of the runtime's README.txt, which names the
// build ("WINQ-EMU runtime for Try Omarchy", "Try FydeOS runtime for Windows,
// lock ..."); empty when there is none.
func (l *Locations) RuntimeBuild() string {
	data, err := os.ReadFile(filepath.Join(l.Runtime, "README.txt"))
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(data), "\n")
	return strings.TrimSpace(line)
}

// FactoryImageCandidates: TRY_FYDEOS_FACTORY_IMAGE, then the spec's own directory.
func (l *Locations) FactoryImageCandidates(spec *FactorySpec) []string {
	var c []string
	if l.FactoryImageOverride != "" {
		c = append(c, l.FactoryImageOverride)
	}
	return append(c, filepath.Join(filepath.Dir(l.Spec), spec.Image.File))
}

// PayloadRuntime is where the payload's runtime.zip is extracted: one directory
// per archive hash, so a newer exe brings its own runtime.
func (l *Locations) PayloadRuntime() string {
	if l.Payload == nil {
		return ""
	}
	e, _ := l.Payload.Lookup(payload.RuntimeEntry)
	return filepath.Join(l.AppData, "runtime", e.SHA256[:12])
}

func (l *Locations) RuntimeFromPayload() bool {
	return l.Payload != nil && l.Runtime == l.PayloadRuntime()
}

func (l *Locations) LoadSpec() (*FactorySpec, error) {
	if l.Spec != "" {
		return LoadFactorySpec(l.Spec)
	}
	data, err := l.Payload.ReadAll(payload.SpecEntry)
	if err != nil {
		return nil, err
	}
	return parseFactorySpec(data, l.Payload.Path+":"+payload.SpecEntry)
}

// SpecName names the spec for messages.
func (l *Locations) SpecName() string {
	if l.Spec != "" {
		return l.Spec
	}
	return l.Payload.Path + ":" + payload.SpecEntry
}

// ImageSource is the compressed factory image: a file or a payload entry.
type ImageSource struct {
	Name string
	Size int64
	io.ReadCloser
}

// OpenFactoryImage: TRY_FYDEOS_FACTORY_IMAGE, then the payload, then the file next to the spec.
func (l *Locations) OpenFactoryImage(spec *FactorySpec) (*ImageSource, error) {
	if l.Payload != nil && l.FactoryImageOverride == "" {
		r, e, err := l.Payload.Entry(payload.ImageEntry)
		if err != nil {
			return nil, err
		}
		return &ImageSource{Name: l.Payload.Path + ":" + payload.ImageEntry, Size: e.Length, ReadCloser: io.NopCloser(r)}, nil
	}
	path, err := l.FactoryImage(spec)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	return &ImageSource{Name: path, Size: st.Size(), ReadCloser: f}, nil
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

// DiscoverLocations resolves defaults next to the executable (development
// build) or from the exe's payload p, and under %LOCALAPPDATA%\Try FydeOS;
// preferences.json and then TRY_FYDEOS_* override them (TRY_FYDEOS_SPEC wins
// over the spec next to TRY_FYDEOS_FACTORY_IMAGE).
func DiscoverLocations(getenv func(string) string, exeDir string, p *payload.Payload) (*Locations, error) {
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
	if p != nil {
		if _, ok := p.Lookup(payload.RuntimeEntry); !ok {
			return nil, fmt.Errorf("%s: payload has no %s", p.Path, payload.RuntimeEntry)
		}
		l.Payload = p
		l.Runtime = l.PayloadRuntime()
		l.Spec = ""
	}

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
