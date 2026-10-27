//go:build linux

package core

import (
	"errors"
	"os"
	"runtime"
	"syscall"
)

type StorageLock struct {
	Path string
	f    *os.File
}

func AcquireLock(path string) (*StorageLock, error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, &LockBusyError{path}
		}
		return nil, &os.PathError{Op: "flock", Path: path, Err: err}
	}
	return &StorageLock{Path: path, f: f}, nil
}

func LockHeld(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	return errors.Is(syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB), syscall.EWOULDBLOCK)
}

func (l *StorageLock) Release() {
	if l.f != nil {
		l.f.Close()
		l.f = nil
	}
}

func setSparse(*os.File) error { return nil }

func VolumeInfo(path string) (string, int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return "", 0, err
	}
	return "", int64(st.Bavail) * int64(st.Bsize), nil
}

func CurrentHost() HostInfo {
	h := HostInfo{LogicalCPUs: runtime.NumCPU(), NativeMachine: runtime.GOARCH}
	var si syscall.Sysinfo_t
	if syscall.Sysinfo(&si) == nil {
		h.MemoryMiB = int(uint64(si.Totalram) * uint64(si.Unit) >> 20)
	}
	return h
}
