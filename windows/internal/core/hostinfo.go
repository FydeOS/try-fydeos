package core

import "fmt"

type HostInfo struct {
	LogicalCPUs   int
	MemoryMiB     int
	NativeMachine string
	WHPXInstalled bool
	WHPXPresent   bool
}

// RequiredFilesystems hold the sparse VM disk.
var RequiredFilesystems = []string{"NTFS", "ReFS"}

type LockBusyError struct{ Path string }

func (e *LockBusyError) Error() string {
	return fmt.Sprintf("storage is in use by another Try FydeOS process (lock held on %s)", e.Path)
}
