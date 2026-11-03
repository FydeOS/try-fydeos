import Foundation

/// The build-time edition: `TryFydeOSEdition` in the app's Info.plist, else
/// TRY_FYDEOS_EDITION (CLI and tests), else io. Unknown values count as io.
public enum Edition: String, Sendable {
    case io, com

    public static var current: Edition {
        resolve(infoValue: Bundle.main.object(forInfoDictionaryKey: "TryFydeOSEdition") as? String,
                environment: ProcessInfo.processInfo.environment)
    }

    static func resolve(infoValue: String?, environment: [String: String]) -> Edition {
        let value = infoValue ?? environment["TRY_FYDEOS_EDITION"]
        return value.flatMap(Edition.init(rawValue:)) ?? .io
    }
}
