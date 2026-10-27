package app

import "fmt"

// Key names a user-visible string; the keys and English texts are those of the
// Mac app's Strings.swift, with %@ written as %s, except the Windows-specific
// Subtitle and AboutCredits.
type Key string

const (
	WindowTitle           Key = "windowTitle"
	Subtitle              Key = "subtitle"
	Version               Key = "version"
	SectionResources      Key = "sectionResources"
	SectionDisplay        Key = "sectionDisplay"
	SectionReset          Key = "sectionReset"
	CPUs                  Key = "cpus"
	CPUValue              Key = "cpuValue"
	Memory                Key = "memory"
	MemoryValue           Key = "memoryValue"
	FullScreen            Key = "fullScreen"
	FullScreenDetail      Key = "fullScreenDetail"
	Microphone            Key = "microphone"
	MicrophoneDetail      Key = "microphoneDetail"
	FactoryReset          Key = "factoryReset"
	FactoryResetDetail    Key = "factoryResetDetail"
	ResetButton           Key = "resetButton"
	Launch                Key = "launch"
	LaunchPreparing       Key = "launchPreparing"
	LaunchStarting        Key = "launchStarting"
	LaunchRunning         Key = "launchRunning"
	LaunchShuttingDown    Key = "launchShuttingDown"
	StatusNotRunning      Key = "statusNotRunning"
	StatusNotRunningAfter Key = "statusNotRunningAfter"
	StatusPreparing       Key = "statusPreparing"
	StatusUnpacking       Key = "statusUnpacking"
	StatusStarting        Key = "statusStarting"
	StatusRunningSince    Key = "statusRunningSince"
	StatusShuttingDown    Key = "statusShuttingDown"
	LastRunShutDown       Key = "lastRunShutDown"
	LastRunStopped        Key = "lastRunStopped"
	ErrorUnexpectedExit   Key = "errorUnexpectedExit"
	ErrorNotReady         Key = "errorNotReady"
	ErrorBusy             Key = "errorBusy"
	ErrorAlertTitle       Key = "errorAlertTitle"
	ErrorLaunchTitle      Key = "errorLaunchTitle"
	ResetTitle            Key = "resetTitle"
	ResetMessage          Key = "resetMessage"
	ResetConfirm          Key = "resetConfirm"
	ResetDone             Key = "resetDone"
	ResetFailedTitle      Key = "resetFailedTitle"
	Cancel                Key = "cancel"
	OK                    Key = "ok"
	MenuAbout             Key = "menuAbout"
	MenuOpenLogs          Key = "menuOpenLogs"
	MenuHide              Key = "menuHide"
	MenuQuit              Key = "menuQuit"
	MenuWindow            Key = "menuWindow"
	MenuClose             Key = "menuClose"
	AboutCredits          Key = "aboutCredits"
)

var English = map[Key]string{
	WindowTitle:           "Try FydeOS",
	Subtitle:              "FYDEOS · WINDOWS",
	Version:               "Version %s",
	SectionResources:      "RESOURCES",
	SectionDisplay:        "DISPLAY & INPUT",
	SectionReset:          "RESET",
	CPUs:                  "Processor cores",
	CPUValue:              "%d cores",
	Memory:                "Memory",
	MemoryValue:           "%d GB",
	FullScreen:            "Full screen",
	FullScreenDetail:      "FydeOS opens full screen; press Ctrl+Alt+F to leave it.",
	Microphone:            "Microphone",
	MicrophoneDetail:      "Optional. Apps in FydeOS can record from your microphone.",
	FactoryReset:          "Factory reset",
	FactoryResetDetail:    "Erase this VM and return it to factory settings.",
	ResetButton:           "Reset FydeOS…",
	Launch:                "Launch FydeOS",
	LaunchPreparing:       "Preparing FydeOS…",
	LaunchStarting:        "Launching FydeOS…",
	LaunchRunning:         "Running",
	LaunchShuttingDown:    "Shutting down…",
	StatusNotRunning:      "Not running",
	StatusNotRunningAfter: "Not running. %s",
	StatusPreparing:       "Preparing…",
	StatusUnpacking:       "Unpacking FydeOS… %d%%",
	StatusStarting:        "Starting…",
	StatusRunningSince:    "Running since %s",
	StatusShuttingDown:    "Shutting down…",
	LastRunShutDown:       "Last run shut down by Try FydeOS (%s).",
	LastRunStopped:        "Last run: FydeOS stopped (%s).",
	ErrorUnexpectedExit:   "FydeOS stopped unexpectedly (%s). See the logs via Open Logs Folder in the window menu.",
	ErrorNotReady:         "FydeOS did not start: %s (%s). See the logs via Open Logs Folder in the window menu.",
	ErrorBusy:             "Try FydeOS is busy. Wait for the current operation to finish.",
	ErrorAlertTitle:       "Try FydeOS",
	ErrorLaunchTitle:      "Try FydeOS couldn’t start",
	ResetTitle:            "Reset FydeOS to factory settings?",
	ResetMessage:          "This permanently erases everything in this FydeOS virtual machine, including apps, files, accounts and settings. This cannot be undone.",
	ResetConfirm:          "Reset",
	ResetDone:             "FydeOS has been reset.",
	ResetFailedTitle:      "FydeOS couldn’t be reset",
	Cancel:                "Cancel",
	OK:                    "OK",
	MenuAbout:             "About Try FydeOS",
	MenuOpenLogs:          "Open Logs Folder",
	MenuHide:              "Hide Try FydeOS",
	MenuQuit:              "Quit Try FydeOS",
	MenuWindow:            "Window",
	MenuClose:             "Close",
	AboutCredits:          "Runs FydeOS under QEMU with the Windows Hypervisor Platform.",
}

func L(key Key, args ...any) string {
	format, ok := English[key]
	if !ok {
		return string(key)
	}
	if len(args) == 0 {
		return format
	}
	return fmt.Sprintf(format, args...)
}
