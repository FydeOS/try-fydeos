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
    case statusStarting
    case statusRunningSince
    case statusShuttingDown
    case lastRunShutDown
    case lastRunStopped
    case errorUnexpectedExit
    case errorNotReady
    case errorBusy
    case errorAlertTitle
    case firstRunNote
    case dismiss
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
    case imageRow
    case imageNotInstalled
    case imageInstalling
    case imageInstall
    case imageFoundAt
    case imageChoose
    case imageChooseMessage
    case imageCopying
    case imageVerifying
    case imageImportFailed
    case imageNotVerifiedAfterImport
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
        .statusStarting: "Starting…",
        .statusRunningSince: "Running since %@",
        .statusShuttingDown: "Shutting down…",
        .lastRunShutDown: "Last run shut down by Try FydeOS (%@).",
        .lastRunStopped: "Last run: FydeOS stopped (%@).",
        .errorUnexpectedExit: "FydeOS stopped unexpectedly (%@). See Logs.",
        .errorNotReady: "FydeOS did not start: %@ (%@). See Logs.",
        .errorBusy: "Try FydeOS is busy. Wait for the current operation to finish.",
        .errorAlertTitle: "Try FydeOS",
        .firstRunNote: "Tip: on a Retina screen, set Settings → Device → Displays → Display size to 200% inside FydeOS.",
        .dismiss: "Dismiss",
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
        .imageRow: "FydeOS image",
        .imageNotInstalled: "Not installed",
        .imageInstalling: "Installing…",
        .imageInstall: "Install…",
        .imageFoundAt: "Found the FydeOS image in %@. Click Install… to copy it (about 7 GB).",
        .imageChoose: "Click Install… and choose the FydeOS image file (%@).",
        .imageChooseMessage: "Choose the FydeOS image file (%@).",
        .imageCopying: "Copying the FydeOS image… %d%%",
        .imageVerifying: "Verifying the FydeOS image… %d%%",
        .imageImportFailed: "Could not install the FydeOS image: %@",
        .imageNotVerifiedAfterImport: "the copied image did not verify",
    ]

    public static var table: [StringKey: String] { english }
}

public func L(_ key: StringKey, _ args: CVarArg...) -> String {
    let format = Strings.table[key] ?? Strings.english[key] ?? key.rawValue
    return args.isEmpty ? format : String(format: format, arguments: args)
}
