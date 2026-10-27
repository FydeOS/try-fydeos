package core

import (
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	jobOnce sync.Once
	jobErr  error
)

// joinKillOnCloseJob puts this process in a job that kills its members when
// the last handle closes. The handle is never closed and is not inheritable,
// so it closes exactly when this process dies; QEMU, started afterwards, is
// born inside the job and cannot outlive the launcher.
func joinKillOnCloseJob() error {
	jobOnce.Do(func() {
		job, err := windows.CreateJobObject(nil, nil)
		if err != nil {
			jobErr = err
			return
		}
		var info windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
		info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
		if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
			uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
			windows.CloseHandle(job)
			jobErr = err
			return
		}
		if err := windows.AssignProcessToJobObject(job, windows.CurrentProcess()); err != nil {
			windows.CloseHandle(job)
			jobErr = err
		}
	})
	return jobErr
}
