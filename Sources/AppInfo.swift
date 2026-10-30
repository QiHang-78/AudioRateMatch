import Foundation

enum AppInfo {
    static let name = "AudioRateMatch"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "local.audioratematch"
    }
    static var displayName: String { "\(name) \(version)" }
}
