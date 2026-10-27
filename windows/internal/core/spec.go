package core

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

// SpecFileName is the factory spec of the image this port boots.
const SpecFileName = "amd64-vmware-io.json"

type FactoryImage struct {
	File      string `json:"file"`
	Bytes     int64  `json:"bytes"`
	SHA256    string `json:"sha256"`
	RawBytes  int64  `json:"rawBytes"`
	RawSHA256 string `json:"rawSha256"`
	Version   string `json:"version"`
}

type FactorySpec struct {
	Schema            int             `json:"schema"`
	Image             FactoryImage    `json:"image"`
	DiskBytes         int64           `json:"diskBytes"`
	Board             string          `json:"board"`
	KernelCommandLine json.RawMessage `json:"kernelCommandLine"`
}

// FactoryRecord is the factory image a workspace was unpacked from.
type FactoryRecord struct {
	File     string `json:"file"`
	SHA256   string `json:"sha256"`
	RawBytes int64  `json:"rawBytes"`
	Version  string `json:"version"`
}

var hex64 = regexp.MustCompile(`^[0-9a-f]{64}$`)

func LoadFactorySpec(path string) (*FactorySpec, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseFactorySpec(data, path)
}

func parseFactorySpec(data []byte, path string) (*FactorySpec, error) {
	var spec FactorySpec
	if err := json.Unmarshal(data, &spec); err != nil {
		return nil, fmt.Errorf("factory spec %s: %w", path, err)
	}
	if spec.Schema != 1 {
		return nil, fmt.Errorf("unsupported factory spec schema %d", spec.Schema)
	}
	im := spec.Image
	if !hex64.MatchString(im.SHA256) || !hex64.MatchString(im.RawSHA256) || im.File == "" ||
		strings.ContainsAny(im.File, `/\`) || im.Bytes <= 0 || im.RawBytes <= 0 || spec.DiskBytes < im.RawBytes {
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
