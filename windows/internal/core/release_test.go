package core

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func releaseServer(t *testing.T, body string) (*httptest.Server, *string) {
	var agent string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		agent = r.UserAgent()
		w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv, &agent
}

func releaseFixture(t *testing.T) string {
	b, err := os.ReadFile("testdata/downloads.json")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestFetchRelease(t *testing.T) {
	srv, agent := releaseServer(t, releaseFixture(t))
	r, err := FetchRelease(context.Background(), srv.URL, "amd64-vmware", "1.2.3")
	if err != nil {
		t.Fatal(err)
	}
	want := Release{Version: "23.1", ReleaseDate: "2026-10-30", FileName: "FydeOS-VMWare-v23.1-Preview1-x86_64-io.ova",
		SHA256: "57062f6e21f1d0933d7bb0e2f0a8ceb1fc78d16c73b252ba0f679ff627a2f4ba",
		URL:    "https://download.fydeos.io/v23.1/FydeOS-VMWare-v23.1-Preview1-x86_64-io.ova"}
	if *r != want || *agent != "Try FydeOS/1.2.3" {
		t.Fatalf("release %+v, User-Agent %q", r, *agent)
	}
}

func TestFetchReleaseErrors(t *testing.T) {
	fixture := releaseFixture(t)
	for name, tc := range map[string]struct{ body, board, want string }{
		"board missing":      {fixture, "nope", "lists no nope image"},
		"end of life":        {fixture, "surface-pro3", "end of life"},
		"malformed JSON":     {`{"list": [`, "amd64-vmware", "unexpected EOF"},
		"malformed checksum": {strings.Replace(fixture, "57062f6e", "57062f6g", 1), "amd64-vmware", "malformed checksum"},
		"no official url":    {strings.Replace(fixture, `"type": "official"`, `"type": "mirror"`, 1), "amd64-vmware", "no official download"},
	} {
		srv, _ := releaseServer(t, tc.body)
		if _, err := FetchRelease(context.Background(), srv.URL, tc.board, "1"); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v", name, err)
		}
	}

	closed := httptest.NewServer(http.NotFoundHandler())
	closed.Close()
	if _, err := FetchRelease(context.Background(), closed.URL, "amd64-vmware", "1"); err == nil {
		t.Error("connection refused: no error")
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := FetchRelease(ctx, srv.URL, "amd64-vmware", "1"); err == nil || time.Since(start) > releaseTimeout {
		t.Errorf("timeout: err = %v after %v", err, time.Since(start))
	}
	missing := httptest.NewServer(http.NotFoundHandler())
	defer missing.Close()
	if _, err := FetchRelease(context.Background(), missing.URL, "amd64-vmware", "1"); err == nil || !strings.Contains(err.Error(), "404") {
		t.Errorf("not found: err = %v", err)
	}
}
