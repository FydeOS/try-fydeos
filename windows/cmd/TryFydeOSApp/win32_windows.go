package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	gdi32    = windows.NewLazySystemDLL("gdi32.dll")
	comctl32 = windows.NewLazySystemDLL("comctl32.dll")

	procAdjustWindowRectEx                = user32.NewProc("AdjustWindowRectEx")
	procAdjustWindowRectExForDpi          = user32.NewProc("AdjustWindowRectExForDpi")
	procAllowSetForegroundWindow          = user32.NewProc("AllowSetForegroundWindow")
	procAppendMenuW                       = user32.NewProc("AppendMenuW")
	procCallNextHookEx                    = user32.NewProc("CallNextHookEx")
	procCreateWindowExW                   = user32.NewProc("CreateWindowExW")
	procDefWindowProcW                    = user32.NewProc("DefWindowProcW")
	procDestroyWindow                     = user32.NewProc("DestroyWindow")
	procDispatchMessageW                  = user32.NewProc("DispatchMessageW")
	procDrawTextW                         = user32.NewProc("DrawTextW")
	procEnableWindow                      = user32.NewProc("EnableWindow")
	procEnumWindows                       = user32.NewProc("EnumWindows")
	procFindWindowW                       = user32.NewProc("FindWindowW")
	procGetCursorPos                      = user32.NewProc("GetCursorPos")
	procGetDC                             = user32.NewProc("GetDC")
	procGetDlgItem                        = user32.NewProc("GetDlgItem")
	procGetDpiForWindow                   = user32.NewProc("GetDpiForWindow")
	procGetMessageW                       = user32.NewProc("GetMessageW")
	procGetMonitorInfoW                   = user32.NewProc("GetMonitorInfoW")
	procGetSysColor                       = user32.NewProc("GetSysColor")
	procGetSysColorBrush                  = user32.NewProc("GetSysColorBrush")
	procGetSystemMenu                     = user32.NewProc("GetSystemMenu")
	procGetSystemMetrics                  = user32.NewProc("GetSystemMetrics")
	procGetWindowRect                     = user32.NewProc("GetWindowRect")
	procGetWindowThreadProcessId          = user32.NewProc("GetWindowThreadProcessId")
	procIsDialogMessageW                  = user32.NewProc("IsDialogMessageW")
	procIsIconic                          = user32.NewProc("IsIconic")
	procIsWindowVisible                   = user32.NewProc("IsWindowVisible")
	procLoadCursorW                       = user32.NewProc("LoadCursorW")
	procLoadImageW                        = user32.NewProc("LoadImageW")
	procMessageBoxW                       = user32.NewProc("MessageBoxW")
	procMonitorFromPoint                  = user32.NewProc("MonitorFromPoint")
	procMoveWindow                        = user32.NewProc("MoveWindow")
	procPostMessageW                      = user32.NewProc("PostMessageW")
	procPostQuitMessage                   = user32.NewProc("PostQuitMessage")
	procRegisterClassExW                  = user32.NewProc("RegisterClassExW")
	procRegisterSuspendResumeNotification = user32.NewProc("RegisterSuspendResumeNotification")
	procReleaseDC                         = user32.NewProc("ReleaseDC")
	procSendMessageW                      = user32.NewProc("SendMessageW")
	procSetForegroundWindow               = user32.NewProc("SetForegroundWindow")
	procSetProcessDPIAware                = user32.NewProc("SetProcessDPIAware")
	procSetProcessDpiAwarenessContext     = user32.NewProc("SetProcessDpiAwarenessContext")
	procSetWindowPos                      = user32.NewProc("SetWindowPos")
	procSetWindowTextW                    = user32.NewProc("SetWindowTextW")
	procSetWindowsHookExW                 = user32.NewProc("SetWindowsHookExW")
	procShowWindow                        = user32.NewProc("ShowWindow")
	procSystemParametersInfoForDpi        = user32.NewProc("SystemParametersInfoForDpi")
	procSystemParametersInfoW             = user32.NewProc("SystemParametersInfoW")
	procTranslateMessage                  = user32.NewProc("TranslateMessage")
	procUnhookWindowsHookEx               = user32.NewProc("UnhookWindowsHookEx")

	procCreateFontIndirectW = gdi32.NewProc("CreateFontIndirectW")
	procDeleteObject        = gdi32.NewProc("DeleteObject")
	procSelectObject        = gdi32.NewProc("SelectObject")
	procSetBkMode           = gdi32.NewProc("SetBkMode")
	procSetTextColor        = gdi32.NewProc("SetTextColor")

	procInitCommonControlsEx = comctl32.NewProc("InitCommonControlsEx")
)

const (
	wmDestroy         = 0x0002
	wmClose           = 0x0010
	wmSetFont         = 0x0030
	wmCommand         = 0x0111
	wmSysCommand      = 0x0112
	wmCtlColorStatic  = 0x0138
	wmPowerBroadcast  = 0x0218
	wmDpiChanged      = 0x02E0
	wmApp             = 0x8000
	dmGetDefID        = 0x0400
	bmGetCheck        = 0x00F0
	bmSetCheck        = 0x00F1
	stmSetImage       = 0x0172
	pbmSetPos         = 0x0402
	pbmSetRange32     = 0x0406
	wsOverlapped      = 0x00000000
	wsCaption         = 0x00C00000
	wsSysMenu         = 0x00080000
	wsMinimizeBox     = 0x00020000
	wsChild           = 0x40000000
	wsVisible         = 0x10000000
	wsTabStop         = 0x00010000
	bsDefPushButton   = 0x1
	bsAutoCheckbox    = 0x3
	bsGroupBox        = 0x7
	ssCenter          = 0x1
	ssIcon            = 0x3
	ssNoPrefix        = 0x80
	mbOKCancel        = 0x1
	mbIconWarning     = 0x30
	mbIconInfo        = 0x40
	mbDefButton2      = 0x100
	idOK              = 1
	idCancel          = 2
	swHide            = 0
	swShowNormal      = 1
	swShow            = 5
	swRestore         = 9
	swpNoSize         = 0x1
	swpNoMove         = 0x2
	swpNoZOrder       = 0x4
	swpNoActivate     = 0x10
	imageIcon         = 1
	smCxIcon          = 11
	smCxSmIcon        = 49
	mfSeparator       = 0x800
	colorBtnFace      = 15
	colorGrayText     = 17
	bkTransparent     = 1
	dtWordBreak       = 0x10
	dtCalcRect        = 0x400
	dtNoPrefix        = 0x800
	spiGetNonClient   = 0x29
	monitorNearest    = 2
	pbtAPMSuspend     = 0x4
	pbtAPMResume      = 0x7
	pbtAPMResumeAuto  = 0x12
	whCBT             = 5
	hcbtActivate      = 5
	iccProgressClass  = 0x20
	iccStandard       = 0x4000
	fwBold            = 700
	idcArrow          = 32512
	asfwAny           = ^uintptr(0)
	dpiContextPerMon2 = ^uintptr(3) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
)

type point struct{ x, y int32 }

type rect struct{ left, top, right, bottom int32 }

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      point
}

type wndClassEx struct {
	size, style         uint32
	wndProc             uintptr
	clsExtra, wndExtra  int32
	instance            uintptr
	icon, cursor, brush uintptr
	menuName, className *uint16
	iconSm              uintptr
}

type logFont struct {
	height, width, escapement, orientation, weight                                           int32
	italic, underline, strikeOut, charSet, outPrecision, clipPrecision, quality, pitchFamily byte
	faceName                                                                                 [32]uint16
}

type nonClientMetrics struct {
	size                                                                uint32
	borderWidth, scrollWidth, scrollHeight, captionWidth, captionHeight int32
	captionFont                                                         logFont
	smCaptionWidth, smCaptionHeight                                     int32
	smCaptionFont                                                       logFont
	menuWidth, menuHeight                                               int32
	menuFont, statusFont, messageFont                                   logFont
	paddedBorderWidth                                                   int32
}

type monitorInfo struct {
	size          uint32
	monitor, work rect
	flags         uint32
}

func utf16(s string) *uint16 {
	p, _ := windows.UTF16PtrFromString(s)
	return p
}

func ptr(s string) uintptr { return uintptr(unsafe.Pointer(utf16(s))) }

func send(hwnd, m, w, l uintptr) uintptr {
	r, _, _ := procSendMessageW.Call(hwnd, m, w, l)
	return r
}

func setText(hwnd uintptr, s string) { procSetWindowTextW.Call(hwnd, ptr(s)) }

func enable(hwnd uintptr, on bool) {
	v := uintptr(0)
	if on {
		v = 1
	}
	procEnableWindow.Call(hwnd, v)
}

func move(hwnd uintptr, x, y, w, h int32) {
	procMoveWindow.Call(hwnd, uintptr(x), uintptr(y), uintptr(w), uintptr(h), 1)
}

func messageBox(owner uintptr, text, caption string, flags uintptr) int {
	r, _, _ := procMessageBoxW.Call(owner, ptr(text), ptr(caption), flags)
	return int(r)
}

// measureText returns the size of text in font; with width > 0 lines wrap at words as a STATIC wraps them.
func measureText(font uintptr, text string, width int32) (int32, int32) {
	dc, _, _ := procGetDC.Call(0)
	if dc == 0 {
		return 0, 0
	}
	defer procReleaseDC.Call(0, dc)
	old, _, _ := procSelectObject.Call(dc, font)
	defer procSelectObject.Call(dc, old)
	r := rect{right: width}
	flags := uintptr(dtCalcRect | dtNoPrefix)
	if width > 0 {
		flags |= dtWordBreak
	}
	procDrawTextW.Call(dc, ptr(text), ^uintptr(0), uintptr(unsafe.Pointer(&r)), flags)
	return r.right - r.left, r.bottom - r.top
}
