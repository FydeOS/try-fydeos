import Foundation

/// Every user-visible string of the app. Add a language by adding a table with all keys.
public enum StringKey: String, CaseIterable, Sendable {
    case windowTitle
    case subtitle
    case version
    case sectionResources
    case sectionDisplay
    case sectionReset
    case cpus
    case cpuValue
    case memory
    case memoryValue
    case fullScreen
    case fullScreenDetail
    case microphone
    case microphoneDetail
    case factoryReset
    case factoryResetDetail
    case updateAvailable
    case resetButton
    case launch
    case launchPreparing
    case launchStarting
    case launchRunning
    case launchShuttingDown
    case statusNotRunning
    case statusNotRunningAfter
    case statusPreparing
    case statusDownloading
    case statusConverting
    case statusStarting
    case statusRunningSince
    case statusShuttingDown
    case lastRunShutDown
    case lastRunStopped
    case errorUnexpectedExit
    case errorNotReady
    case errorBusy
    case errorAlertTitle
    case errorLaunchTitle
    case resetTitle
    case resetMessage
    case resetMessageUpdate
    case resetConfirm
    case resetDone
    case resetFailedTitle
    case cancel
    case ok
    case menuAbout
    case menuOpenLogs
    case menuHide
    case menuQuit
    case menuWindow
    case menuClose
    case aboutCredits
}

public enum Strings {

    public static let english: [StringKey: String] = [
        .windowTitle: "Try FydeOS",
        .subtitle: "FYDEOS · APPLE SILICON",
        .version: "Version %@",
        .sectionResources: "RESOURCES",
        .sectionDisplay: "DISPLAY & INPUT",
        .sectionReset: "RESET",
        .cpus: "Processor cores",
        .cpuValue: "%d cores",
        .memory: "Memory",
        .memoryValue: "%d GB",
        .fullScreen: "Full screen",
        .fullScreenDetail: "FydeOS opens full screen; the Mac menu bar and Dock stay hidden.",
        .microphone: "Microphone",
        .microphoneDetail: "Optional. Apps in FydeOS can record from your Mac microphone.",
        .factoryReset: "Factory reset",
        .factoryResetDetail: "Erase this VM and return it to factory settings.",
        .updateAvailable: "FydeOS %@ (%@) is available. Factory reset installs it.",
        .resetButton: "Reset FydeOS…",
        .launch: "Launch FydeOS",
        .launchPreparing: "Preparing FydeOS…",
        .launchStarting: "Launching FydeOS…",
        .launchRunning: "Running",
        .launchShuttingDown: "Shutting down…",
        .statusNotRunning: "Not running",
        .statusNotRunningAfter: "Not running. %@",
        .statusPreparing: "Preparing…",
        .statusDownloading: "Downloading FydeOS… %d%%",
        .statusConverting: "Converting FydeOS… %d%%",
        .statusStarting: "Starting…",
        .statusRunningSince: "Running since %@",
        .statusShuttingDown: "Shutting down…",
        .lastRunShutDown: "Last run shut down by Try FydeOS (%@).",
        .lastRunStopped: "Last run: FydeOS stopped (%@).",
        .errorUnexpectedExit: "FydeOS stopped unexpectedly (%@). See the logs in the Try FydeOS menu.",
        .errorNotReady: "FydeOS did not start: %@ (%@). See the logs in the Try FydeOS menu.",
        .errorBusy: "Try FydeOS is busy. Wait for the current operation to finish.",
        .errorAlertTitle: "Try FydeOS",
        .errorLaunchTitle: "Try FydeOS couldn’t start",
        .resetTitle: "Reset FydeOS to factory settings?",
        .resetMessage: "This permanently erases everything in this FydeOS virtual machine, including apps, files, accounts and settings. This cannot be undone.",
        .resetMessageUpdate: "Erase this VM and install FydeOS %@ (%@)?",
        .resetConfirm: "Reset",
        .resetDone: "FydeOS has been reset.",
        .resetFailedTitle: "FydeOS couldn’t be reset",
        .cancel: "Cancel",
        .ok: "OK",
        .menuAbout: "About Try FydeOS",
        .menuOpenLogs: "Open Logs Folder",
        .menuHide: "Hide Try FydeOS",
        .menuQuit: "Quit Try FydeOS",
        .menuWindow: "Window",
        .menuClose: "Close",
        .aboutCredits: "Runs FydeOS under QEMU with Apple's Hypervisor framework. Runtime recipe from Try Omarchy (MIT).",
    ]

    public static var table: [StringKey: String] { english }
}

public func L(_ key: StringKey, _ args: CVarArg...) -> String {
    let format = Strings.table[key] ?? Strings.english[key] ?? key.rawValue
    return args.isEmpty ? format : String(format: format, arguments: args)
}
