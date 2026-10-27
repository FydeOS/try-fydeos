package core

import (
	"os"
	"syscall"
	"testing"
)

func diskAllocated(t *testing.T, path string) int64 {
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return st.Sys().(*syscall.Stat_t).Blocks * 512
}
