package core

import (
	"errors"
	"os"
	"path/filepath"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	kernel32                 = windows.NewLazySystemDLL("kernel32.dll")
	procGlobalMemoryStatusEx = kernel32.NewProc("GlobalMemoryStatusEx")
	// The DLL ships with the Windows Hypervisor Platform feature; loading it is unprivileged.
	winhv                = windows.NewLazySystemDLL("WinHvPlatform.dll")
	procWHvGetCapability = winhv.NewProc("WHvGetCapability")
)

type StorageLock struct {
	Path string
	h    windows.Handle
}

func openLockFile(path string) (windows.Handle, error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	return windows.CreateFile(p, windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil,
		windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, 0)
}

// tryLock takes an exclusive byte-range lock on the first byte. Windows owns
// such locks per handle, so a second handle in the same process conflicts too.
func tryLock(h windows.Handle) error {
	var ol windows.Overlapped
	return windows.LockFileEx(h, windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ol)
}

func AcquireLock(path string) (*StorageLock, error) {
	h, err := openLockFile(path)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	if err := tryLock(h); err != nil {
		windows.CloseHandle(h)
		if errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
			return nil, &LockBusyError{path}
		}
		return nil, &os.PathError{Op: "LockFileEx", Path: path, Err: err}
	}
	return &StorageLock{Path: path, h: h}, nil
}

func LockHeld(path string) bool {
	if _, err := os.Stat(path); err != nil {
		return false
	}
	h, err := openLockFile(path)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	err = tryLock(h)
	if err == nil {
		var ol windows.Overlapped
		windows.UnlockFileEx(h, 0, 1, 0, &ol)
		return false
	}
	return errors.Is(err, windows.ERROR_LOCK_VIOLATION)
}

func (l *StorageLock) Release() {
	if l.h != 0 {
		windows.CloseHandle(l.h)
		l.h = 0
	}
}

func setSparse(f *os.File) error {
	var returned uint32
	return windows.DeviceIoControl(windows.Handle(f.Fd()), windows.FSCTL_SET_SPARSE, nil, 0, nil, 0, &returned, nil)
}

func IsSparse(path string) (bool, error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return false, err
	}
	attrs, err := windows.GetFileAttributes(p)
	if err != nil {
		return false, err
	}
	return attrs&windows.FILE_ATTRIBUTE_SPARSE_FILE != 0, nil
}

func existingAncestor(path string) string {
	for {
		if _, err := os.Stat(path); err == nil {
			return path
		}
		parent := filepath.Dir(path)
		if parent == path {
			return path
		}
		path = parent
	}
}

// VolumeInfo returns the filesystem name (NTFS, ReFS, FAT32, exFAT, ...) and
// the bytes free to this user on the volume holding path or its nearest existing ancestor.
func VolumeInfo(path string) (string, int64, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", 0, err
	}
	p, err := windows.UTF16PtrFromString(existingAncestor(abs))
	if err != nil {
		return "", 0, err
	}
	root := make([]uint16, windows.MAX_PATH+1)
	if err := windows.GetVolumePathName(p, &root[0], uint32(len(root))); err != nil {
		return "", 0, err
	}
	fsName := make([]uint16, windows.MAX_PATH+1)
	if err := windows.GetVolumeInformation(&root[0], nil, 0, nil, nil, nil, &fsName[0], uint32(len(fsName))); err != nil {
		return "", 0, err
	}
	var free, total, totalFree uint64
	if err := windows.GetDiskFreeSpaceEx(&root[0], &free, &total, &totalFree); err != nil {
		return "", 0, err
	}
	return windows.UTF16ToString(fsName), int64(free), nil
}

func CurrentHost() HostInfo {
	h := HostInfo{LogicalCPUs: int(windows.GetActiveProcessorCount(windows.ALL_PROCESSOR_GROUPS))}
	var ms struct {
		length, memoryLoad                                                    uint32
		totalPhys, availPhys, totalPage, availPage, totalVirt, availVirt, ext uint64
	}
	ms.length = uint32(unsafe.Sizeof(ms))
	if r, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&ms))); r != 0 {
		h.MemoryMiB = int(ms.totalPhys >> 20)
	}
	// IsWow64Process2 reports the CPU Windows runs on, also when this amd64
	// binary is emulated on an ARM64 PC.
	var process, native uint16
	switch err := windows.IsWow64Process2(windows.CurrentProcess(), &process, &native); {
	case err != nil:
		h.NativeMachine = "unknown"
	case native == 0x8664:
		h.NativeMachine = "amd64"
	case native == 0xaa64:
		h.NativeMachine = "arm64"
	default:
		h.NativeMachine = "unknown"
	}
	if winhv.Load() == nil && procWHvGetCapability.Find() == nil {
		h.WHPXInstalled = true
		var present, written uint32
		// capability code 0 = WHvCapabilityCodeHypervisorPresent
		hr, _, _ := procWHvGetCapability.Call(0, uintptr(unsafe.Pointer(&present)), 4, uintptr(unsafe.Pointer(&written)))
		h.WHPXPresent = hr == 0 && present != 0
	}
	return h
}
