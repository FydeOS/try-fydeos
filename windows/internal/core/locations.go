package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

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
	// AppVersion names the app to the release API.
	AppVersion string
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

// FactoryContainer is the .ova or .zip a new VM is converted from, and its
// record: TRY_FYDEOS_FACTORY_IMAGE as is; otherwise the release API's image
// when it differs from the pinned one, else the pinned one, downloaded into
// ImageDir unless a file of the right size is there.
func (l *Locations) FactoryContainer(ctx context.Context, spec *FactorySpec, say func(string),
	progress func(done, total int64)) (string, FactoryRecord, error) {
	if l.FactoryImageOverride != "" {
		if st, err := os.Stat(l.FactoryImageOverride); err != nil || !st.Mode().IsRegular() {
			return "", FactoryRecord{}, fmt.Errorf("FydeOS image %s not found (TRY_FYDEOS_FACTORY_IMAGE)", l.FactoryImageOverride)
		}
		say("using the local image " + l.FactoryImageOverride)
		return l.FactoryImageOverride, FactoryRecord{FileName: filepath.Base(l.FactoryImageOverride)}, nil
	}
	name, err := urlFileName(spec.Image.URL)
	if err != nil {
		return "", FactoryRecord{}, err
	}
	record := FactoryRecord{URL: spec.Image.URL, FileName: name, SHA256: spec.Image.SHA256, Version: spec.Image.Version}
	size := spec.Image.Bytes
	if rel, err := FetchRelease(ctx, spec.Release.API, spec.Release.Board, l.AppVersion); err != nil {
		say("release API: " + err.Error() + "; using the pinned image")
	} else if rel.SHA256 == record.SHA256 {
		say("release API lists the pinned image " + rel.FileName)
	} else if n, err := RemoteSize(ctx, rel.URL); err != nil {
		say(fmt.Sprintf("release API lists %s %s (%s), but its size is unknown: %v; using the pinned image", rel.FileName, rel.Version, rel.ReleaseDate, err))
	} else {
		say(fmt.Sprintf("release API lists %s %s (%s), newer than the pinned image", rel.FileName, rel.Version, rel.ReleaseDate))
		record = FactoryRecord{URL: rel.URL, FileName: rel.FileName, SHA256: rel.SHA256, Version: rel.Version + ", " + rel.ReleaseDate}
		size = n
	}
	dest := filepath.Join(ImageDir(l.AppData), record.FileName)
	if st, err := os.Stat(dest); err == nil && st.Size() == size {
		say("using the downloaded image " + dest)
		pruneImages(ImageDir(l.AppData), record.FileName, say)
		return dest, record, nil
	}
	if err := os.MkdirAll(ImageDir(l.AppData), 0o700); err != nil {
		return "", FactoryRecord{}, err
	}
	var have int64
	if st, err := os.Stat(dest + ".part"); err == nil {
		have = st.Size()
	}
	if _, free, err := VolumeInfo(ImageDir(l.AppData)); err != nil {
		return "", FactoryRecord{}, err
	} else if need := size - have + workReserve; free < need {
		return "", FactoryRecord{}, fmt.Errorf("not enough free space: %.1f GB needed, %.1f GB available", float64(need)/1e9, float64(free)/1e9)
	}
	say(fmt.Sprintf("downloading %s into %s (%d bytes)", record.URL, dest, size))
	start := time.Now()
	if err := Download(ctx, record.URL, size, record.SHA256, dest, progress); err != nil {
		return "", FactoryRecord{}, err
	}
	say(fmt.Sprintf("downloaded in %.1f s", time.Since(start).Seconds()))
	pruneImages(ImageDir(l.AppData), record.FileName, say)
	return dest, record, nil
}

// pruneImages removes every file in dir but keep: superseded downloads and
// stale parts.
func pruneImages(dir, keep string, say func(string)) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		say("cannot list " + dir + ": " + err.Error())
		return
	}
	for _, e := range entries {
		if e.Name() == keep || e.IsDir() {
			continue
		}
		if err := os.Remove(filepath.Join(dir, e.Name())); err != nil {
			say("cannot remove superseded image " + e.Name() + ": " + err.Error())
		} else {
			say("removed superseded image " + e.Name())
		}
	}
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
