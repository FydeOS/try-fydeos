package core

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Release is the latest image the release API lists for a board.
type Release struct {
	Version     string
	ReleaseDate string
	FileName    string
	SHA256      string
	URL         string
}

const releaseTimeout = 5 * time.Second

func userAgent(appVersion string) string { return "Try FydeOS/" + appVersion }

// FetchRelease asks the release API for board's entry and its official download.
func FetchRelease(ctx context.Context, api, board, appVersion string) (*Release, error) {
	ctx, cancel := context.WithTimeout(ctx, releaseTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, api, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent(appVersion))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s", api, resp.Status)
	}
	var body struct {
		List []struct {
			Board        string `json:"board"`
			Version      string `json:"version"`
			ReleaseDate  string `json:"releaseDate"`
			FileName     string `json:"fileName"`
			Checksum     string `json:"checksum"`
			IsEOL        bool   `json:"isEOL"`
			DownloadUrls []struct {
				Type string `json:"type"`
				URL  string `json:"url"`
			} `json:"downloadUrls"`
		} `json:"list"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&body); err != nil {
		return nil, fmt.Errorf("%s: %w", api, err)
	}
	for _, e := range body.List {
		if e.Board != board {
			continue
		}
		if e.IsEOL {
			return nil, fmt.Errorf("%s: %s is end of life", api, board)
		}
		if !hex64.MatchString(e.Checksum) {
			return nil, fmt.Errorf("%s: %s has a malformed checksum %q", api, board, e.Checksum)
		}
		for _, u := range e.DownloadUrls {
			if u.Type != "official" {
				continue
			}
			if name, err := urlFileName(u.URL); err != nil || !isHTTPS(u.URL) || name != e.FileName {
				return nil, fmt.Errorf("%s: %s has a malformed download %q for %q", api, board, u.URL, e.FileName)
			}
			return &Release{Version: e.Version, ReleaseDate: e.ReleaseDate, FileName: e.FileName, SHA256: e.Checksum, URL: u.URL}, nil
		}
		return nil, fmt.Errorf("%s: %s has no official download", api, board)
	}
	return nil, fmt.Errorf("%s lists no %s image", api, board)
}
