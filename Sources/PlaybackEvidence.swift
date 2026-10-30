import Foundation

struct AudioClient {
    let objectID: UInt32
    let pid: Int32
    let bundleID: String
    let path: String
    let name: String
    let startedAt: Date?
    let running: Bool
    let deviceIDs: [UInt32]
    var selectionKey: String {
        // System WebKit helpers share a bundle ID across unrelated host applications.
        if bundleID.hasPrefix("com.apple.WebKit.") { return "bundle:" + bundleID + "|" + name }
        if !bundleID.isEmpty { return "bundle:" + bundleID }
        return path.isEmpty ? "process:\(pid)" : "path:" + path
    }
    var identity: String { "\(pid)|\(objectID)|\(startedAt?.timeIntervalSince1970 ?? 0)|\(path)" }
}

struct OutputEndpoint {
    let id: UInt32
    let uid: String
    let isDefault: Bool
}

enum QueueRoute: Equatable {
    case defaultOutput, device(String), unknown
    init(_ text: String) {
        if text == "Default-Output" { self = .defaultOutput }
        else if text.hasPrefix("Device-") { self = .device(String(text.dropFirst(7))) }
        else { self = .unknown }
    }
    func matches(_ output: OutputEndpoint, soleDevice: Bool) -> Bool {
        switch self {
        case .defaultOutput: return output.isDefault
        case let .device(uid): return uid == output.uid
        case .unknown: return soleDevice
        }
    }
}

struct PlaybackEvent {
    enum Kind { case format(String, Double), start(String, QueueRoute), stop(String) }
    let pid: Int32
    let path: String
    let timestamp: String
    let date: Date?
    let kind: Kind
    private static let dateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()
    private static let formatPattern = try! NSRegularExpression(pattern: #"aq@(0x[0-9a-fA-F]+): New output; format\s+\d+ ch,\s*([0-9.]+) Hz"#)
    private static let activityPattern = try! NSRegularExpression(pattern: #"AQME (.+?): client (starting|stopping): <AudioQueueObject@(0x[0-9a-fA-F]+);"#)

    static func parse(_ object: [String: Any]) -> PlaybackEvent? {
        guard let message = object["eventMessage"] as? String,
              let pid = object["processID"] as? NSNumber,
              let timestamp = object["timestamp"] as? String, !timestamp.isEmpty else { return nil }
        let path = object["processImagePath"] as? String ?? ""
        let kind: Kind
        if let groups = match(formatPattern, message), let rate = Double(groups[1]), rate.isFinite, (8000...768000).contains(rate) {
            kind = .format(groups[0].lowercased(), rate)
        } else if let groups = match(activityPattern, message) {
            let id = groups[2].lowercased()
            kind = groups[1] == "starting" ? .start(id, QueueRoute(groups[0])) : .stop(id)
        } else { return nil }
        return PlaybackEvent(pid: pid.int32Value, path: path, timestamp: timestamp,
                             date: dateParser.date(from: timestamp), kind: kind)
    }
    private static func match(_ expression: NSRegularExpression, _ text: String) -> [String]? {
        guard let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<result.numberOfRanges).compactMap { Range(result.range(at: $0), in: text).map { String(text[$0]) } }
    }
}

struct PlaybackEvidence {
    struct QueueFormat { let rate: Double; let timestamp: String }
    private(set) var identity = ""
    private(set) var formats: [String: QueueFormat] = [:]
    private(set) var active: [String: QueueRoute] = [:]
    private var lastTimestamp = ""

    mutating func reset(identity: String) { self = PlaybackEvidence(); self.identity = identity }
    mutating func accept(_ event: PlaybackEvent, client: AudioClient) {
        guard event.pid == client.pid else { return }
        if !event.path.isEmpty && !client.path.isEmpty && event.path != client.path { return }
        if let born = client.startedAt, let date = event.date, date < born { return }
        if identity != client.identity { reset(identity: client.identity) }
        guard event.timestamp >= lastTimestamp else { return }
        lastTimestamp = event.timestamp
        switch event.kind {
        case let .format(id, rate):
            formats[id] = QueueFormat(rate: rate, timestamp: event.timestamp)
            if formats.count > 256 {
                let old = formats.filter { active[$0.key] == nil }.sorted { $0.value.timestamp < $1.value.timestamp }.prefix(64)
                for value in old { formats.removeValue(forKey: value.key) }
            }
        case let .start(id, route): active[id] = route
        case let .stop(id): active.removeValue(forKey: id)
        }
    }
    func rate(for output: OutputEndpoint, client: AudioClient) -> Double? {
        guard identity == client.identity, client.running, client.deviceIDs.contains(output.id) else { return nil }
        let queues = active.filter { $0.value.matches(output, soleDevice: client.deviceIDs.count == 1) }
        guard !queues.isEmpty else { return nil }
        let rates = queues.keys.compactMap { formats[$0]?.rate }
        guard rates.count == queues.count, let first = rates.first, rates.allSatisfy({ abs($0 - first) < 0.1 }) else { return nil }
        return first
    }
}

struct SourceObservation {
    let client: AudioClient
    let rate: Double?
}

struct SourceResolution {
    let observations: [SourceObservation]
    let rate: Double?
    let reason: String
    var names: String { observations.map { $0.client.name }.joined(separator: "、") }
}

enum SourcePolicy {
    static func resolve(clients: [AudioClient], evidence: [Int32: PlaybackEvidence], output: OutputEndpoint, preferred: String?) -> SourceResolution {
        let selected = clients.filter { client in
            client.running && (client.deviceIDs.contains(output.id) || client.deviceIDs.isEmpty) &&
            (preferred == nil || client.selectionKey == preferred)
        }.sorted { $0.pid < $1.pid }
        let observations = selected.map { SourceObservation(client: $0, rate: evidence[$0.pid]?.rate(for: output, client: $0)) }
        guard !observations.isEmpty else {
            return SourceResolution(observations: [], rate: nil, reason: preferred == nil ? "没有应用正在向此设备输出音频" : "等待所选应用向此设备输出音频")
        }
        guard observations.allSatisfy({ $0.rate != nil }) else {
            return SourceResolution(observations: observations, rate: nil, reason: "部分播放流格式未确认，保持当前采样率")
        }
        let rate = observations[0].rate!
        guard observations.allSatisfy({ abs($0.rate! - rate) < 0.1 }) else {
            return SourceResolution(observations: observations, rate: nil, reason: "多个播放流采样率不同；可指定跟随应用")
        }
        return SourceResolution(observations: observations, rate: rate, reason: "已确认播放流")
    }
}

// Hysteresis and a per-device write budget also apply across changing apps and rates.
struct SwitchGate {
    private var candidate: String?
    private var since = Date.distantPast
    private var writes: [String: [Date]] = [:]
    mutating func observe(_ key: String?, now: Date) -> Bool {
        guard let key else { candidate = nil; return false }
        if candidate != key { candidate = key; since = now; return false }
        return now.timeIntervalSince(since) >= 0.65
    }
    mutating func allowWrite(device: String, now: Date) -> Bool {
        let recent = (writes[device] ?? []).filter { now.timeIntervalSince($0) < 15 }
        writes[device] = recent
        return recent.count < 5
    }
    mutating func didWrite(device: String, now: Date) { writes[device, default: []].append(now) }
    mutating func reset() { self = SwitchGate() }
}
