package core

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"regexp"
	"strings"
)

// SpecFileName is the factory spec of the image this edition boots.
func SpecFileName() string { return "amd64-vmware-" + Edition + ".json" }

// FactoryImage is the pinned download a new VM is converted from when the
// release API offers nothing else.
type FactoryImage struct {
	URL     string `json:"url"`
	Bytes   int64  `json:"bytes"`
	SHA256  string `json:"sha256"`
	Version string `json:"version"`
}

// ReleaseSource is where the latest published image of the board is listed.
type ReleaseSource struct {
	API   string `json:"api"`
	Board string `json:"board"`
}

type FactorySpec struct {
	Schema            int             `json:"schema"`
	Image             FactoryImage    `json:"image"`
	Release           ReleaseSource   `json:"release"`
	DiskBytes         int64           `json:"diskBytes"`
	Board             string          `json:"board"`
	KernelCommandLine json.RawMessage `json:"kernelCommandLine"`
}

// FactoryRecord is the image a workspace was converted from; RawBytes is the
// length of the FydeOS image inside its disk.
type FactoryRecord struct {
	URL      string `json:"url"`
	FileName string `json:"fileName"`
	SHA256   string `json:"sha256"`
	Version  string `json:"version"`
	RawBytes int64  `json:"rawBytes"`
}

var hex64 = regexp.MustCompile(`^[0-9a-f]{64}$`)

func LoadFactorySpec(path string) (*FactorySpec, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseFactorySpec(data, path)
}

func isHTTPS(s string) bool {
	u, err := url.Parse(s)
	return err == nil && u.Scheme == "https" && u.Host != ""
}

// urlFileName is the last path element of an image URL, the name it is stored under.
func urlFileName(s string) (string, error) {
	u, err := url.Parse(s)
	if err != nil {
		return "", err
	}
	name := path.Base(u.Path)
	if name == "." || name == "/" || strings.ContainsAny(name, `\:`) {
		return "", fmt.Errorf("%s names no file", s)
	}
	return name, nil
}

func parseFactorySpec(data []byte, path string) (*FactorySpec, error) {
	var spec FactorySpec
	if err := json.Unmarshal(data, &spec); err != nil {
		return nil, fmt.Errorf("factory spec %s: %w", path, err)
	}
	if spec.Schema != 2 {
		return nil, fmt.Errorf("unsupported factory spec schema %d", spec.Schema)
	}
	im := spec.Image
	if _, err := urlFileName(im.URL); err != nil || !isHTTPS(im.URL) || im.Bytes <= 0 || !hex64.MatchString(im.SHA256) ||
		!isHTTPS(spec.Release.API) || spec.Release.Board == "" || spec.DiskBytes <= 0 {
		return nil, fmt.Errorf("malformed factory spec: %s", path)
	}
	return &spec, nil
}

func SHA256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
