package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"

	"tryfydeos.io/windows/internal/app"
	"tryfydeos.io/windows/internal/core"
	"tryfydeos.io/windows/internal/payload"
)

// Keep in step with versioninfo.rc.
const appVersion = "0.3.0"

const (
	className   = "TryFydeOSStartMenu"
	mutexName   = `Local\TryFydeOS`
	wmRunPosted = wmApp + 1
	wmActivate  = wmApp + 2
)

const (
	idCPUMinus = 100 + iota
	idCPUPlus
	idMemoryMinus
	idMemoryPlus
	idFullScreen
	idMicrophone
	idReset
	idLaunch
)

const (
	// System menu ids must stay below 0xF000 with the low four bits clear.
	sysAbout = 0x0010
	sysLogs  = 0x0020
	sysQuit  = 0x0030
)

func init() { runtime.LockOSThread() }

type startMenu struct {
	hwnd     uintptr
	instance uintptr
	dpi      int
	font     uintptr
	title    uintptr
	icon     uintptr
	shown    bool

	ctl struct {
		icon, title, subtitle, version                      uintptr
		groupResources, groupDisplay, groupReset            uintptr
		cpuLabel, cpuMinus, cpuValue, cpuPlus               uintptr
		memoryLabel, memoryMinus, memoryValue, memoryPlus   uintptr
		fullScreen, fullScreenDetail, mic, micDetail        uintptr
		resetLabel, resetDetail, reset, status, launch, bar uintptr
		resetUpdate                                         uintptr
	}
	grey map[uintptr]bool

	loc        *core.Locations
	host       core.HostInfo
	log        *app.AppLog
	driver     *app.CoreDriver
	controller *app.Controller
	prefs      app.Preferences

	postMu sync.Mutex
	posted []func()
}

var menu *startMenu

func (m *startMenu) s(v int) int32 { return int32(v * m.dpi / 96) }

func (m *startMenu) post(f func()) {
	m.postMu.Lock()
	m.posted = append(m.posted, f)
	m.postMu.Unlock()
	procPostMessageW.Call(m.hwnd, wmRunPosted, 0, 0)
}

func (m *startMenu) runPosted() {
	m.postMu.Lock()
	fs := m.posted
	m.posted = nil
	m.postMu.Unlock()
	for _, f := range fs {
		f()
	}
}

func (m *startMenu) child(class, text string, style, id uintptr) uintptr {
	h, _, _ := procCreateWindowExW.Call(0, ptr(class), ptr(text), wsChild|wsVisible|style,
		0, 0, 0, 0, m.hwnd, id, m.instance, 0)
	return h
}

func (m *startMenu) label(text string, grey bool, style uintptr) uintptr {
	h := m.child("STATIC", text, ssNoPrefix|style, 0)
	if grey {
		m.grey[h] = true
	}
	return h
}

func editionSuffix() string {
	if core.Edition == "com" {
		return " (com)"
	}
	return ""
}

// Button and group box captions treat & as a mnemonic prefix.
func buttonText(s string) string { return strings.ReplaceAll(s, "&", "&&") }

func (m *startMenu) build() {
	c := &m.ctl
	c.icon = m.child("STATIC", "", ssIcon, 0)
	c.title = m.label(app.L(app.WindowTitle), false, 0)
	c.subtitle = m.label(app.L(app.Subtitle), true, 0)
	c.version = m.label(app.L(app.Version, appVersion), true, 0)

	c.groupResources = m.child("BUTTON", buttonText(app.L(app.SectionResources)), bsGroupBox, 0)
	c.cpuLabel = m.label(app.L(app.CPUs), false, 0)
	c.cpuMinus = m.child("BUTTON", "−", wsTabStop, idCPUMinus)
	c.cpuValue = m.label("", false, ssCenter)
	c.cpuPlus = m.child("BUTTON", "+", wsTabStop, idCPUPlus)
	c.memoryLabel = m.label(app.L(app.Memory), false, 0)
	c.memoryMinus = m.child("BUTTON", "−", wsTabStop, idMemoryMinus)
	c.memoryValue = m.label("", false, ssCenter)
	c.memoryPlus = m.child("BUTTON", "+", wsTabStop, idMemoryPlus)

	c.groupDisplay = m.child("BUTTON", buttonText(app.L(app.SectionDisplay)), bsGroupBox, 0)
	c.fullScreen = m.child("BUTTON", buttonText(app.L(app.FullScreen)), bsAutoCheckbox|wsTabStop, idFullScreen)
	c.fullScreenDetail = m.label(app.L(app.FullScreenDetail), true, 0)
	c.mic = m.child("BUTTON", buttonText(app.L(app.Microphone)), bsAutoCheckbox|wsTabStop, idMicrophone)
	c.micDetail = m.label(app.L(app.MicrophoneDetail), true, 0)

	c.groupReset = m.child("BUTTON", buttonText(app.L(app.SectionReset)), bsGroupBox, 0)
	c.resetLabel = m.label(app.L(app.FactoryReset), false, 0)
	c.resetDetail = m.label(app.L(app.FactoryResetDetail), true, 0)
	c.resetUpdate = m.label("", false, 0)
	c.reset = m.child("BUTTON", buttonText(app.L(app.ResetButton)), wsTabStop, idReset)

	c.status = m.label("", true, 0)
	c.launch = m.child("BUTTON", buttonText(app.L(app.Launch)), bsDefPushButton|wsTabStop, idLaunch)
	h, _, _ := procCreateWindowExW.Call(0, ptr("msctls_progress32"), 0, wsChild, 0, 0, 0, 0, m.hwnd, 0, m.instance, 0)
	c.bar = h
	send(c.bar, pbmSetRange32, 0, 1000)

	check := func(h uintptr, on bool) {
		v := uintptr(0)
		if on {
			v = 1
		}
		send(h, bmSetCheck, v, 0)
	}
	check(c.fullScreen, m.prefs.FullScreen)
	check(c.mic, m.prefs.Microphone)
}

func (m *startMenu) allControls() []uintptr {
	c := &m.ctl
	return []uintptr{c.title, c.subtitle, c.version, c.groupResources, c.groupDisplay, c.groupReset,
		c.cpuLabel, c.cpuMinus, c.cpuValue, c.cpuPlus, c.memoryLabel, c.memoryMinus, c.memoryValue, c.memoryPlus,
		c.fullScreen, c.fullScreenDetail, c.mic, c.micDetail, c.resetLabel, c.resetDetail, c.resetUpdate, c.reset, c.status, c.launch}
}

// applyDPI creates the fonts and header icon for the window's current DPI.
func (m *startMenu) applyDPI() {
	if r, _, _ := procGetDpiForWindow.Call(m.hwnd); procGetDpiForWindow.Find() == nil && r != 0 {
		m.dpi = int(r)
	} else {
		m.dpi = 96
	}
	var ncm nonClientMetrics
	ncm.size = uint32(unsafe.Sizeof(ncm))
	if procSystemParametersInfoForDpi.Find() == nil {
		procSystemParametersInfoForDpi.Call(spiGetNonClient, uintptr(ncm.size), uintptr(unsafe.Pointer(&ncm)), 0, uintptr(m.dpi))
	} else {
		procSystemParametersInfoW.Call(spiGetNonClient, uintptr(ncm.size), uintptr(unsafe.Pointer(&ncm)), 0)
	}
	lf := ncm.messageFont
	if lf.height == 0 {
		lf.height = -m.s(12)
		copy(lf.faceName[:], windows.StringToUTF16("Segoe UI"))
	}
	for _, f := range []uintptr{m.font, m.title} {
		if f != 0 {
			procDeleteObject.Call(f)
		}
	}
	m.font, _, _ = procCreateFontIndirectW.Call(uintptr(unsafe.Pointer(&lf)))
	lf.height = lf.height * 9 / 5
	lf.weight = fwBold
	m.title, _, _ = procCreateFontIndirectW.Call(uintptr(unsafe.Pointer(&lf)))
	for _, h := range m.allControls() {
		send(h, wmSetFont, m.font, 1)
	}
	send(m.ctl.title, wmSetFont, m.title, 1)
	if m.icon != 0 {
		procDeleteObject.Call(m.icon)
	}
	size := uintptr(m.s(48))
	m.icon, _, _ = procLoadImageW.Call(m.instance, 1, imageIcon, size, size, 0)
	send(m.ctl.icon, stmSetImage, imageIcon, m.icon)
}

// layout places every control for the current DPI and state and returns the client height.
func (m *startMenu) layout() int32 {
	c := &m.ctl
	s := m.s
	x, w := s(20), s(480)
	_, line := measureText(m.font, "Ag", 0)
	y := s(16)

	iconSize := s(48)
	move(c.icon, x, y, iconSize, iconSize)
	_, titleH := measureText(m.title, app.L(app.WindowTitle), 0)
	textH := titleH + 2*(s(2)+line)
	tx := x + iconSize + s(14)
	ty := y + max(0, (iconSize-textH)/2)
	move(c.title, tx, ty, x+w-tx, titleH)
	ty += titleH + s(2)
	move(c.subtitle, tx, ty, x+w-tx, line)
	move(c.version, tx, ty+line+s(2), x+w-tx, line)
	y += max(iconSize, textH) + s(14)

	inner, innerW := x+s(14), w-2*s(14)
	group := func(h uintptr, top int32) {
		move(h, x, top, w, y-top)
		y += s(10)
	}

	top := y
	y += line + s(8)
	rowH := max(s(26), line+s(8))
	for _, row := range [][4]uintptr{{c.cpuLabel, c.cpuMinus, c.cpuValue, c.cpuPlus}, {c.memoryLabel, c.memoryMinus, c.memoryValue, c.memoryPlus}} {
		bw, vw := rowH, s(84)
		right := inner + innerW
		move(row[0], inner, y+(rowH-line)/2, innerW-2*bw-vw, line)
		move(row[1], right-2*bw-vw, y, bw, rowH)
		move(row[2], right-bw-vw, y+(rowH-line)/2, vw, line)
		move(row[3], right-bw, y, bw, rowH)
		y += rowH + s(6)
	}
	y += s(6)
	group(c.groupResources, top)

	top = y
	y += line + s(8)
	indent := s(18)
	for _, row := range [][2]uintptr{{c.fullScreen, c.fullScreenDetail}, {c.mic, c.micDetail}} {
		move(row[0], inner, y, innerW, line+s(4))
		y += line + s(4)
		_, dh := measureText(m.font, windowText(row[1]), innerW-indent)
		move(row[1], inner+indent, y, innerW-indent, dh)
		y += dh + s(8)
	}
	y += s(4)
	group(c.groupDisplay, top)

	top = y
	y += line + s(8)
	bw, _ := measureText(m.font, app.L(app.ResetButton), 0)
	bw = max(bw+s(28), s(112))
	bh := max(s(28), line+s(10))
	textW := innerW - bw - s(12)
	_, dh := measureText(m.font, app.L(app.FactoryResetDetail), textW)
	textH = line + s(2) + dh
	var uh int32
	if text := windowText(c.resetUpdate); text != "" {
		_, uh = measureText(m.font, text, textW)
		textH += s(2) + uh
	}
	rowH = max(bh, textH)
	move(c.resetLabel, inner, y+(rowH-textH)/2, textW, line)
	move(c.resetDetail, inner, y+(rowH-textH)/2+line+s(2), textW, dh)
	move(c.resetUpdate, inner, y+(rowH-textH)/2+line+s(2)+dh+s(2), textW, uh)
	move(c.reset, inner+innerW-bw, y+(rowH-bh)/2, bw, bh)
	y += rowH + s(12)
	group(c.groupReset, top)

	y += s(2)
	_, sh := measureText(m.font, windowText(c.status), w)
	move(c.status, x, y, w, max(sh, line))
	y += max(sh, line) + s(10)
	lh := max(s(36), line+s(18))
	move(c.launch, x, y, w, lh)
	y += lh
	if st := m.controller.State(); st.Phase == app.Preparing && st.Total > 0 {
		y += s(8)
		move(c.bar, x, y, w, s(6))
		y += s(6)
	}
	return y + s(20)
}

func windowText(h uintptr) string {
	buf := make([]uint16, 1024)
	n := send(h, 0x000D, uintptr(len(buf)), uintptr(unsafe.Pointer(&buf[0]))) // WM_GETTEXT
	return windows.UTF16ToString(buf[:n])
}

const windowStyle = wsOverlapped | wsCaption | wsSysMenu | wsMinimizeBox

func (m *startMenu) windowSize(clientH int32) (int32, int32) {
	r := rect{0, 0, m.s(520), clientH}
	if procAdjustWindowRectExForDpi.Find() == nil {
		procAdjustWindowRectExForDpi.Call(uintptr(unsafe.Pointer(&r)), windowStyle, 0, 0, uintptr(m.dpi))
	} else {
		procAdjustWindowRectEx.Call(uintptr(unsafe.Pointer(&r)), windowStyle, 0, 0)
	}
	return r.right - r.left, r.bottom - r.top
}

// refresh mirrors the controller's state into the controls and fits the window to them.
func (m *startMenu) refresh() {
	c := &m.ctl
	st := m.controller.State()
	idle := !st.Active()
	setText(c.status, st.StatusText())
	setText(c.launch, buttonText(st.LaunchTitle()))
	setText(c.cpuValue, app.L(app.CPUValue, m.prefs.CPUs))
	setText(c.memoryValue, app.L(app.MemoryValue, m.prefs.MemoryMiB/1024))
	if r := m.controller.UpdateRelease(); r != nil {
		setText(c.resetUpdate, app.L(app.UpdateAvailable, r.Version, r.ReleaseDate))
		procShowWindow.Call(c.resetUpdate, swShow)
	} else {
		setText(c.resetUpdate, "")
		procShowWindow.Call(c.resetUpdate, swHide)
	}
	cpus, memory := app.CPUChoices(m.host), app.MemoryChoices(m.host)
	enable(c.cpuMinus, idle && m.prefs.CPUs > cpus[0])
	enable(c.cpuPlus, idle && m.prefs.CPUs < cpus[len(cpus)-1])
	enable(c.memoryMinus, idle && m.prefs.MemoryMiB > memory[0])
	enable(c.memoryPlus, idle && m.prefs.MemoryMiB < memory[len(memory)-1])
	for _, h := range []uintptr{c.groupResources, c.cpuLabel, c.cpuValue, c.memoryLabel, c.memoryValue,
		c.groupDisplay, c.fullScreen, c.fullScreenDetail, c.mic, c.micDetail, c.groupReset, c.resetLabel, c.resetDetail, c.resetUpdate} {
		enable(h, idle)
	}
	enable(c.reset, m.controller.CanFactoryReset())
	enable(c.launch, m.controller.CanLaunch())
	if st.Phase == app.Preparing && st.Total > 0 {
		send(c.bar, pbmSetPos, uintptr(st.Bytes*1000/st.Total), 0)
		procShowWindow.Call(c.bar, swShow)
	} else {
		procShowWindow.Call(c.bar, swHide)
	}
	cw, ch := m.windowSize(m.layout())
	procSetWindowPos.Call(m.hwnd, 0, 0, 0, uintptr(cw), uintptr(ch), swpNoMove|swpNoZOrder|swpNoActivate)
}

func (m *startMenu) show() {
	m.refresh()
	if !m.shown {
		m.shown = true
		var r rect
		procGetWindowRect.Call(m.hwnd, uintptr(unsafe.Pointer(&r)))
		var pt point
		procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
		mon, _, _ := procMonitorFromPoint.Call(uintptr(pt.x)|uintptr(pt.y)<<32, monitorNearest)
		mi := monitorInfo{size: uint32(unsafe.Sizeof(monitorInfo{}))}
		procGetMonitorInfoW.Call(mon, uintptr(unsafe.Pointer(&mi)))
		w, h := r.right-r.left, r.bottom-r.top
		x := mi.work.left + (mi.work.right-mi.work.left-w)/2
		y := mi.work.top + max(0, (mi.work.bottom-mi.work.top-h)/2)
		procSetWindowPos.Call(m.hwnd, 0, uintptr(x), uintptr(y), 0, 0, swpNoSize|swpNoZOrder)
	}
	if iconic, _, _ := procIsIconic.Call(m.hwnd); iconic != 0 {
		procShowWindow.Call(m.hwnd, swRestore)
	} else {
		procShowWindow.Call(m.hwnd, swShow)
	}
	procSetForegroundWindow.Call(m.hwnd)
}

func (m *startMenu) stateChanged(st app.State) {
	m.log.Write("state " + st.String())
	m.refresh()
	switch st.Phase {
	case app.Running:
		if !m.controller.QuitPending() {
			procShowWindow.Call(m.hwnd, swHide)
		}
	case app.NotRunning, app.Failed:
		if !m.controller.QuitPending() {
			m.show()
		}
	case app.Starting:
		procAllowSetForegroundWindow.Call(uintptr(m.controller.VMPid()))
	}
}

func (m *startMenu) savePreferences() {
	if err := m.prefs.Save(m.loc.PreferencesFile()); err != nil {
		m.log.Write("saving preferences: " + err.Error())
	}
}

func (m *startMenu) step(id int) {
	cpus, memory := app.CPUChoices(m.host), app.MemoryChoices(m.host)
	switch id {
	case idCPUMinus:
		m.prefs.CPUs = max(m.prefs.CPUs-1, cpus[0])
	case idCPUPlus:
		m.prefs.CPUs = min(m.prefs.CPUs+1, cpus[len(cpus)-1])
	case idMemoryMinus:
		m.prefs.MemoryMiB = max(m.prefs.MemoryMiB-app.MemoryStepMiB, memory[0])
	case idMemoryPlus:
		m.prefs.MemoryMiB = min(m.prefs.MemoryMiB+app.MemoryStepMiB, memory[len(memory)-1])
	}
	m.savePreferences()
	m.refresh()
}

func (m *startMenu) command(id int) {
	switch id {
	case idCPUMinus, idCPUPlus, idMemoryMinus, idMemoryPlus:
		m.step(id)
	case idFullScreen, idMicrophone:
		m.prefs.FullScreen = send(m.ctl.fullScreen, bmGetCheck, 0, 0) == 1
		m.prefs.Microphone = send(m.ctl.mic, bmGetCheck, 0, 0) == 1
		m.savePreferences()
	case idReset:
		m.factoryReset()
	case idLaunch:
		if !m.controller.CanLaunch() {
			return
		}
		m.savePreferences()
		m.controller.Launch(m.prefs.LaunchOptions(m.loc.Forwards))
	}
}

var (
	resetHook         uintptr
	resetHookCallback = syscall.NewCallback(func(code, wParam, lParam uintptr) uintptr {
		if code == hcbtActivate {
			box := wParam
			for id, text := range map[uintptr]string{idOK: app.L(app.ResetConfirm), idCancel: app.L(app.Cancel)} {
				if b, _, _ := procGetDlgItem.Call(box, id); b != 0 {
					setText(b, text)
				}
			}
			procUnhookWindowsHookEx.Call(resetHook)
			resetHook = 0
		}
		r, _, _ := procCallNextHookEx.Call(0, code, wParam, lParam)
		return r
	})
)

// factoryReset asks with a MessageBox whose OK button a CBT hook relabels to the confirm text.
func (m *startMenu) factoryReset() {
	if !m.controller.CanFactoryReset() {
		return
	}
	message := app.L(app.ResetMessage)
	if r := m.controller.UpdateRelease(); r != nil {
		message = app.L(app.ResetMessageUpdate, r.Version, r.ReleaseDate)
	}
	resetHook, _, _ = procSetWindowsHookExW.Call(whCBT, resetHookCallback, 0, uintptr(windows.GetCurrentThreadId()))
	answer := messageBox(m.hwnd, app.L(app.ResetTitle)+"\n\n"+message, app.L(app.WindowTitle),
		mbOKCancel|mbIconWarning|mbDefButton2)
	if resetHook != 0 {
		procUnhookWindowsHookEx.Call(resetHook)
		resetHook = 0
	}
	if answer != idOK {
		return
	}
	if err := m.controller.FactoryReset(); err != nil {
		m.log.Write("factory reset failed: " + err.Error())
		messageBox(m.hwnd, err.Error(), app.L(app.ResetFailedTitle), mbIconWarning)
	}
}

func (m *startMenu) openLogs() {
	dir := m.loc.LogsDir()
	os.MkdirAll(dir, 0o700)
	if err := windows.ShellExecute(windows.Handle(m.hwnd), utf16("open"), utf16(dir), nil, nil, swShowNormal); err != nil {
		m.log.Write("opening " + dir + ": " + err.Error())
	}
}

func (m *startMenu) quit() {
	if m.controller.RequestQuit() {
		procDestroyWindow.Call(m.hwnd)
		return
	}
	m.log.Write("quit requested while the VM runs; running the shutdown ladder")
}

// activate brings this instance forward when a second one starts: the start
// menu if it is up, otherwise the VM window.
func (m *startMenu) activate() {
	if visible, _, _ := procIsWindowVisible.Call(m.hwnd); visible != 0 || m.controller.State().Phase != app.Running {
		m.show()
		return
	}
	if w := topWindowOf(m.driver.Pid()); w != 0 {
		if iconic, _, _ := procIsIconic.Call(w); iconic != 0 {
			procShowWindow.Call(w, swRestore)
		}
		procSetForegroundWindow.Call(w)
	}
}

var (
	enumPid, enumFound uint32
	enumFoundWindow    uintptr
	enumCallback       = syscall.NewCallback(func(hwnd, _ uintptr) uintptr {
		var pid uint32
		procGetWindowThreadProcessId.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
		if visible, _, _ := procIsWindowVisible.Call(hwnd); visible != 0 && pid == enumPid {
			enumFoundWindow = hwnd
			return 0
		}
		return 1
	})
)

func topWindowOf(pid int) uintptr {
	if pid == 0 {
		return 0
	}
	enumPid, enumFoundWindow = uint32(pid), 0
	procEnumWindows.Call(enumCallback, 0)
	return enumFoundWindow
}

func (m *startMenu) wndProc(hwnd, message, wParam, lParam uintptr) uintptr {
	switch message {
	case wmRunPosted:
		m.runPosted()
		return 0
	case wmActivate:
		m.activate()
		return 0
	case wmCommand:
		if wParam>>16 == 0 { // BN_CLICKED
			m.command(int(wParam & 0xFFFF))
		}
		return 0
	case wmSysCommand:
		switch wParam & 0xFFF0 {
		case sysAbout:
			messageBox(hwnd, app.L(app.WindowTitle)+"\n"+app.L(app.Version, appVersion)+editionSuffix()+"\n\n"+app.L(app.AboutCredits), app.L(app.MenuAbout), mbIconInfo)
			return 0
		case sysLogs:
			m.openLogs()
			return 0
		case sysQuit:
			m.quit()
			return 0
		}
	case dmGetDefID:
		return idLaunch | 0x534B<<16 // DC_HASDEFID
	case wmCtlColorStatic:
		if m.grey[lParam] {
			color, _, _ := procGetSysColor.Call(colorGrayText)
			procSetTextColor.Call(wParam, color)
		}
		procSetBkMode.Call(wParam, bkTransparent)
		brush, _, _ := procGetSysColorBrush.Call(colorBtnFace)
		return brush
	case wmDpiChanged:
		suggested := *(*rect)(*(*unsafe.Pointer)(unsafe.Pointer(&lParam)))
		m.applyDPI()
		m.refresh()
		procSetWindowPos.Call(hwnd, 0, uintptr(suggested.left), uintptr(suggested.top), 0, 0, swpNoSize|swpNoZOrder|swpNoActivate)
		return 0
	case wmPowerBroadcast:
		switch wParam {
		case pbtAPMSuspend:
			m.log.Write("host will sleep")
			m.controller.WillSleep()
		case pbtAPMResume, pbtAPMResumeAuto:
			m.log.Write(fmt.Sprintf("host did wake (PBT 0x%x)", wParam))
			m.controller.DidWake()
		}
		return 1
	case wmClose:
		m.quit()
		return 0
	case wmDestroy:
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(hwnd, message, wParam, lParam)
	return r
}

func setDPIAwareness() {
	if procSetProcessDpiAwarenessContext.Find() == nil {
		if r, _, _ := procSetProcessDpiAwarenessContext.Call(dpiContextPerMon2); r != 0 {
			return
		}
	}
	procSetProcessDPIAware.Call()
}

func activateFirstInstance() {
	w, _, _ := procFindWindowW.Call(ptr(className), 0)
	if w == 0 {
		return
	}
	var pid uint32
	procGetWindowThreadProcessId.Call(w, uintptr(unsafe.Pointer(&pid)))
	procAllowSetForegroundWindow.Call(uintptr(pid))
	procPostMessageW.Call(w, wmActivate, 0, 0)
}

func fatal(text string) {
	messageBox(0, text, app.L(app.ErrorLaunchTitle), mbIconWarning)
	os.Exit(1)
}

func main() {
	setDPIAwareness()
	if _, err := windows.CreateMutex(nil, false, utf16(mutexName)); errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		activateFirstInstance()
		return
	}
	icc := [2]uint32{8, iccProgressClass | iccStandard}
	procInitCommonControlsEx.Call(uintptr(unsafe.Pointer(&icc)))

	exe, err := os.Executable()
	if err != nil {
		fatal(err.Error())
	}
	p, err := payload.Open(exe)
	if errors.Is(err, payload.ErrNoPayload) {
		p = nil
	} else if err != nil {
		fatal(err.Error())
	}
	loc, err := core.DiscoverLocations(os.Getenv, filepath.Dir(exe), p)
	if err != nil {
		fatal(err.Error())
	}
	loc.AppVersion = appVersion
	m := &startMenu{loc: loc, host: core.CurrentHost(), log: app.OpenAppLog(loc.LogsDir()), grey: map[uintptr]bool{}}
	menu = m
	m.log.Write(fmt.Sprintf("app started, version %s, workspace %s, runtime %s, spec %s", appVersion, loc.Workspace, loc.Runtime, loc.SpecName()))
	if m.prefs, err = app.LoadPreferences(loc.PreferencesFile(), m.host); err != nil {
		m.log.Write("preferences: " + err.Error() + "; using defaults")
	}
	m.driver = &app.CoreDriver{Locations: loc, Host: m.host, Log: m.log, Post: m.post}
	_, last, _ := m.driver.Workspace().LastRun()
	m.controller = app.NewController(m.driver, app.LastRunMessage(last))
	m.controller.OnStateChange = m.stateChanged
	m.controller.OnError = func(title, message string) {
		m.log.Write("error: " + message)
		m.post(func() {
			m.show()
			messageBox(m.hwnd, message, title, mbIconWarning)
		})
	}
	m.controller.OnReadyToQuit = func() {
		m.log.Write("VM stopped, exiting")
		procDestroyWindow.Call(m.hwnd)
	}
	m.controller.OnReleaseChange = m.refresh

	m.instance, _, _ = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetModuleHandleW").Call(0)
	cursor, _, _ := procLoadCursorW.Call(0, idcArrow)
	bigX, _, _ := procGetSystemMetrics.Call(smCxIcon)
	smallX, _, _ := procGetSystemMetrics.Call(smCxSmIcon)
	big, _, _ := procLoadImageW.Call(m.instance, 1, imageIcon, bigX, bigX, 0)
	small, _, _ := procLoadImageW.Call(m.instance, 1, imageIcon, smallX, smallX, 0)
	wc := wndClassEx{wndProc: syscall.NewCallback(m.wndProc), instance: m.instance, icon: big, iconSm: small,
		cursor: cursor, brush: colorBtnFace + 1, className: utf16(className)}
	wc.size = uint32(unsafe.Sizeof(wc))
	if atom, _, err := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc))); atom == 0 {
		fatal("RegisterClassEx: " + err.Error())
	}
	var pt point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	m.hwnd, _, err = procCreateWindowExW.Call(0, ptr(className), ptr(app.L(app.WindowTitle)), windowStyle,
		uintptr(pt.x), uintptr(pt.y), 100, 100, 0, 0, m.instance, 0)
	if m.hwnd == 0 {
		fatal("CreateWindowEx: " + err.Error())
	}
	sys, _, _ := procGetSystemMenu.Call(m.hwnd, 0)
	procAppendMenuW.Call(sys, mfSeparator, 0, 0)
	procAppendMenuW.Call(sys, 0, sysAbout, ptr(app.L(app.MenuAbout)))
	procAppendMenuW.Call(sys, 0, sysLogs, ptr(app.L(app.MenuOpenLogs)))
	procAppendMenuW.Call(sys, 0, sysQuit, ptr(app.L(app.MenuQuit)))
	// Modern Standby sends suspend/resume broadcasts only to windows that register.
	procRegisterSuspendResumeNotification.Call(m.hwnd, 0)

	m.build()
	m.applyDPI()
	m.show()
	m.controller.CheckRelease()

	var mm msg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&mm)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		if ok, _, _ := procIsDialogMessageW.Call(m.hwnd, uintptr(unsafe.Pointer(&mm))); ok != 0 {
			continue
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&mm)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&mm)))
	}
	m.log.Write("app exiting")
}
