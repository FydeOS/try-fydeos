import Foundation

/// Every user-visible string of the app. Add a language by adding a table with all keys.
public enum StringKey: String, CaseIterable, Sendable {
    case windowTitle
    case cpus
    case memory
    case memoryValue
    case fullScreen
    case microphone
    case launch
    case shutDown
    case logs
    case factoryReset
    case quit
    case statusNotRunning
    case statusNotRunningAfter
    case statusPreparing
    case statusUnpacking
    case statusStarting
    case statusRunningSince
    case statusShuttingDown
    case lastRunShutDown
    case lastRunStopped
    case errorUnexpectedExit
    case errorNotReady
    case errorBusy
    case errorAlertTitle
    case resetTitle
    case resetMessage
    case resetConfirm
    case resetDone
    case cancel
    case ok
    case menuAbout
    case menuHide
    case menuQuit
    case menuWindow
    case menuClose
    case aboutCredits
}

public enum Strings {
    public static let resetPhrase = "Try FydeOS"

    public static let english: [StringKey: String] = [
        .windowTitle: "Try FydeOS",
        .cpus: "CPUs",
        .memory: "Memory",
        .memoryValue: "%d GB",
        .fullScreen: "Full screen",
        .microphone: "Microphone",
        .launch: "Launch",
        .shutDown: "Shut Down",
        .logs: "Logs",
        .factoryReset: "Factory Reset…",
        .quit: "Quit",
        .statusNotRunning: "Not running",
        .statusNotRunningAfter: "Not running. %@",
        .statusPreparing: "Preparing…",
        .statusUnpacking: "Unpacking FydeOS… %d%%",
        .statusStarting: "Starting…",
        .statusRunningSince: "Running since %@",
        .statusShuttingDown: "Shutting down…",
        .lastRunShutDown: "Last run shut down by Try FydeOS (%@).",
        .lastRunStopped: "Last run: FydeOS stopped (%@).",
        .errorUnexpectedExit: "FydeOS stopped unexpectedly (%@). See Logs.",
        .errorNotReady: "FydeOS did not start: %@ (%@). See Logs.",
        .errorBusy: "Try FydeOS is busy. Wait for the current operation to finish.",
        .errorAlertTitle: "Try FydeOS",
        .resetTitle: "Factory reset",
        .resetMessage: "This erases FydeOS and everything stored in it. The next launch starts from the factory image. Type “%@” to confirm.",
        .resetConfirm: "Erase",
        .resetDone: "Factory reset done.",
        .cancel: "Cancel",
        .ok: "OK",
        .menuAbout: "About Try FydeOS",
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
