import Foundation

struct PreplayCue {
    let pid: Int32
    let queueID: String
    let rate: Double
    let startedAt: Date
    var identity: String { "\(pid)|\(queueID)|\(startedAt.timeIntervalSince1970)" }
}

enum PreplayPolicy {
    static let delay: TimeInterval = 1.0
    static let maximumEventAge: TimeInterval = 0.8

    static func exclusiveSource(pid: Int32, clients: [AudioClient], outputID: UInt32) -> Bool {
        let active = clients.filter { $0.running && ($0.deviceIDs.isEmpty || $0.deviceIDs.contains(outputID)) }
        return !active.isEmpty && active.allSatisfy { $0.pid == pid }
    }

    static func cue(events: [PlaybackEvent], clients: [AudioClient], evidence: [Int32: PlaybackEvidence],
                    output: OutputEndpoint, rate: Double, now: Date) -> PreplayCue? {
        for event in events.reversed() {
            guard let date = event.date, (-0.05...maximumEventAge).contains(now.timeIntervalSince(date)),
                  let client = clients.first(where: { $0.pid == event.pid }), client.running, client.deviceIDs.contains(output.id),
                  case let .start(id, route) = event.kind,
                  route.matches(output, soleDevice: client.deviceIDs.count == 1),
                  let item = evidence[event.pid], item.identity == client.identity, item.active[id] == route,
                  item.rate(for: output, client: client).map({ abs($0 - rate) < 0.1 }) == true,
                  let format = item.formats[id], abs(format.rate - rate) < 0.1,
                  event.path.isEmpty || client.path.isEmpty || event.path == client.path else { continue }
            return PreplayCue(pid: event.pid, queueID: id, rate: rate, startedAt: date)
        }
        return nil
    }
}

// A format-property readback is insufficient: a real running clock must remain
// monotonic and close to the requested rate for several consecutive observations.
struct ClockReadiness {
    private var previous: (host: Double, sample: Double)?
    private var steadySince: Double?
    mutating func observe(host: Double, sample: Double, targetRate: Double, formatMatches: Bool) -> Bool {
        defer { previous = (host, sample) }
        guard formatMatches, host.isFinite, sample.isFinite, targetRate > 0,
              let previous, host > previous.host else { steadySince = nil; return false }
        let elapsed = host - previous.host, frames = sample - previous.sample
        guard elapsed > 0, frames > 0, abs(frames / elapsed / targetRate - 1) < 0.01 else {
            steadySince = nil; return false
        }
        if steadySince == nil { steadySince = previous.host }
        return host - steadySince! >= 0.5
    }
}
