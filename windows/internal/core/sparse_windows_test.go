package core

import (
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func diskAllocated(t *testing.T, path string) int64 {
	if sparse, err := IsSparse(path); err != nil || !sparse {
		t.Fatalf("%s not marked sparse: %v", path, err)
	}
	p, _ := windows.UTF16PtrFromString(path)
	proc := windows.NewLazySystemDLL("kernel32.dll").NewProc("GetCompressedFileSizeW")
	var high uint32
	low, _, err := proc.Call(uintptr(unsafe.Pointer(p)), uintptr(unsafe.Pointer(&high)))
	if uint32(low) == 0xffffffff && err != windows.ERROR_SUCCESS {
		t.Fatal(err)
	}
	return int64(high)<<32 | int64(uint32(low))
}
