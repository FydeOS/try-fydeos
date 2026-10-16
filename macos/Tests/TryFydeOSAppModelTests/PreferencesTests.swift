import Foundation
import Testing
import TryFydeOSCore
@testable import TryFydeOSAppModel

let m4 = HostInfo(logicalCores: 10, memoryMiB: 24576)
let small = HostInfo(logicalCores: 4, memoryMiB: 8192)
let big = HostInfo(logicalCores: 16, memoryMiB: 65536)

func scratchDefaults() -> UserDefaults {
    let name = "tfo-test-\(UUID().uuidString)"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

@Test func choicesFollowHost() {
    #expect(Preferences.cpuChoices(m4) == Array(4...10))
    #expect(Preferences.memoryChoices(m4).first == 4096)
    #expect(Preferences.memoryChoices(m4).last == 20480)
    #expect(Preferences.memoryChoices(m4).count == 17)
    #expect(Preferences.cpuChoices(small) == [4])
    #expect(Preferences.memoryChoices(small) == [4096])
}

@Test func defaultsDependOnHost() {
    #expect(Preferences.defaults(for: m4) == Preferences(cpus: 8, memoryMiB: 8192))
    #expect(Preferences.defaults(for: big) == Preferences(cpus: 8, memoryMiB: 8192))
    #expect(Preferences.defaults(for: small) == Preferences(cpus: 4, memoryMiB: 4096))
    #expect(Preferences.defaults(for: HostInfo(logicalCores: 8, memoryMiB: 16384)).memoryMiB == 8192)
    #expect(Preferences.defaults(for: HostInfo(logicalCores: 8, memoryMiB: 16383)).memoryMiB == 4096)
}

@Test func clampingSnapsToChoices() {
    #expect(Preferences(cpus: 64, memoryMiB: 999_999).clamped(to: m4) == Preferences(cpus: 10, memoryMiB: 20480))
    #expect(Preferences(cpus: 1, memoryMiB: 10).clamped(to: m4) == Preferences(cpus: 4, memoryMiB: 4096))
    #expect(Preferences(cpus: 6, memoryMiB: 6000).clamped(to: m4) == Preferences(cpus: 6, memoryMiB: 5120))
}

@Test func persistsAndReloadsClamped() {
    let store = scratchDefaults()
    #expect(Preferences.load(from: store, host: m4) == Preferences.defaults(for: m4))
    Preferences(cpus: 10, memoryMiB: 20480, fullScreen: true, microphone: true, firstRunNoteDismissed: true).save(to: store)
    #expect(Preferences.load(from: store, host: m4) == Preferences(cpus: 10, memoryMiB: 20480, fullScreen: true, microphone: true, firstRunNoteDismissed: true))
    // The same stored values on a smaller host come back within its limits.
    #expect(Preferences.load(from: store, host: small) == Preferences(cpus: 4, memoryMiB: 4096, fullScreen: true, microphone: true, firstRunNoteDismissed: true))
}

@Test func workspaceOverrideOrder() {
    let store = scratchDefaults()
    #expect(Preferences.workspaceURL(store: store, environment: [:]) == Workspace.defaultURL)
    store.set("/tmp/ws-defaults", forKey: Preferences.Key.workspace)
    #expect(Preferences.workspaceURL(store: store, environment: [:]).path == "/tmp/ws-defaults")
    #expect(Preferences.workspaceURL(store: store, environment: ["TRY_FYDEOS_WORKSPACE": "/tmp/ws-env"]).path == "/tmp/ws-env")
}

@Test func launchOptionsCarryPreferences() {
    let o = Preferences(cpus: 6, memoryMiB: 12288, fullScreen: true, microphone: true).launchOptions
    #expect(o == LaunchOptions(cpus: 6, memoryMiB: 12288, fullScreen: true, microphone: true))
}

@Test func stringTableIsComplete() {
    for key in StringKey.allCases {
        let text = Strings.english[key]
        #expect(text != nil && !text!.isEmpty, "missing English string for \(key)")
    }
    #expect(Strings.english.count == StringKey.allCases.count)
    #expect(L(.statusRunningSince, "10:00") == "Running since 10:00")
    #expect(L(.memoryValue, 8) == "8 GB")
    #expect(L(.errorNotReady, "a", "b").contains("a (b)"))
}
