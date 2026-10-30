import Foundation
import AppKit

func emitJSON(_ object: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
}
let arguments = Array(CommandLine.arguments.dropFirst())
let usage = """
\(AppInfo.displayName) — macOS output sample-rate matching

Usage:
  AudioRateMatch                              Open the menu-bar app (auto switching enabled)
  AudioRateMatch --help                       Show this help without starting audio monitoring
  AudioRateMatch --version                    Show the bundled version
  AudioRateMatch --status                     Print devices and audio clients as JSON
  AudioRateMatch --watch [--seconds N]         Observe for 1–300 seconds (default: 20)
                 [--device NAME_OR_UID]       Select an output device
                 [--source SELECTION_KEY]     Follow an app from --status
                 [--apply]                    Enable real device changes while watching
  AudioRateMatch --set RATE_HZ                Set and verify a device rate immediately
                 [--device NAME_OR_UID]

--watch does not change device settings unless --apply is supplied.
--set changes the device immediately. Quit other rate controllers before using it.
The app UI and diagnostic messages are currently in Simplified Chinese.
"""
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
} else if arguments.contains("--version") {
    print(AppInfo.displayName)
} else if arguments.contains("--status") {
    emitJSON(["outputs": Hardware.devices().map(\.dictionary),
              "defaultOutput": Hardware.defaultOutput()?.dictionary ?? [:],
              "audioClients": Hardware.clients().map { ["pid": $0.pid, "name": $0.name, "bundleID": $0.bundleID, "path": $0.path, "running": $0.running, "deviceIDs": $0.deviceIDs, "selectionKey": $0.selectionKey] as [String: Any] },
              "switcherApps": NSWorkspace.shared.runningApplications.filter { app in
                  ["synchz", "ratesync", "musicrateswitcher", "losslessswitcher", "qqratematch", "audioratematch"].contains((app.localizedName ?? "").lowercased())
              }.map { ["name": $0.localizedName ?? "", "pid": $0.processIdentifier, "path": $0.bundleURL?.path ?? ""] }])
} else if let value = option("--set"), let rate = Double(value) {
    let device = option("--device").flatMap { value in Hardware.devices().first { $0.name == value || $0.uid == value } } ?? (option("--device") == nil ? Hardware.defaultOutput() : nil)
    guard let device else { fputs("未找到输出设备\n", stderr); exit(1) }
    do {
        try Hardware.setRate(rate, on: device)
        var actual: OutputDevice?
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.1)
            actual = Hardware.device(device.id)
            if let actual, Hardware.verified(actual, rate: rate) { break }
        }
        guard let actual, Hardware.verified(actual, rate: rate) else { throw AudioFailure(description: "写入后系统/硬件回读未匹配") }
        emitJSON(["verified": true, "beforeHz": device.rate, "output": actual.dictionary])
    } catch { fputs("\(error)\n", stderr); exit(1) }
} else if arguments.contains("--watch") {
    let engine = MatchEngine()
    engine.dryRun = !arguments.contains("--apply")
    engine.preferredSource = option("--source")
    if let selector = option("--device") {
        guard let device = Hardware.devices().first(where: { $0.name == selector || $0.uid == selector }) else { fputs("未找到输出设备\n", stderr); exit(1) }
        engine.preferredUID = device.uid
    }
    engine.start()
    let seconds = Double(option("--seconds") ?? "20") ?? 20
    RunLoop.main.run(until: Date().addingTimeInterval(max(1, min(300, seconds))))
    print(engine.report); engine.stop()
} else {
    guard arguments.isEmpty else {
        fputs("Unknown or incomplete command. Use --help for usage.\n", stderr); exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(); app.delegate = delegate
    app.run()
}
