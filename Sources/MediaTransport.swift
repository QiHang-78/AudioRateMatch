import Foundation
import Darwin

struct PlayerSnapshot: Equatable {
    let pid: Int32
    let bundleID: String
    let trackKey: String
    let itemID: String
    let playing: Bool
    let receivedAt: Date

    init?(_ object: [String: Any], now: Date = Date()) {
        guard let bundle = object["bundleIdentifier"] as? String, !bundle.isEmpty,
              let pid = (object["processIdentifier"] as? NSNumber)?.int32Value, pid > 0,
              let title = object["title"] as? String, !title.isEmpty,
              let playing = object["playing"] as? Bool else { return nil }
        self.pid = pid; bundleID = bundle; self.playing = playing; receivedAt = now
        // QQ regenerates contentItemIdentifier on seek. Keep both an identity for
        // the song and an item token for detecting a listener's seek during a hold.
        trackKey = [title, object["artist"] as? String ?? "", object["album"] as? String ?? "",
                    String(describing: object["durationMicros"] ?? object["duration"] ?? "")].joined(separator: "\u{1f}")
        itemID = object["contentItemIdentifier"] as? String ?? ""
    }
    func sameTrack(as other: PlayerSnapshot) -> Bool {
        pid == other.pid && bundleID == other.bundleID && trackKey == other.trackKey
    }
    func sameItem(as other: PlayerSnapshot) -> Bool {
        sameTrack(as: other) && (itemID.isEmpty || other.itemID.isEmpty || itemID == other.itemID)
    }
    static func stream(_ envelope: [String: Any], now: Date = Date()) -> PlayerSnapshot? {
        guard envelope["type"] as? String == "data", envelope["diff"] as? Bool == false,
              let payload = envelope["payload"] as? [String: Any] else { return nil }
        return PlayerSnapshot(payload, now: now)
    }
}

// A queue start also occurs when resuming midway through a song. Only a newly
// observed song transition permits seeking to its head. Initial state is unknown.
struct PlayerTransitionTracker {
    private var last: PlayerSnapshot?
    private var changedAt: Date?
    mutating func observe(_ player: PlayerSnapshot?, at now: Date) {
        guard let player else { return }
        if let last, player.bundleID != last.bundleID || player.trackKey != last.trackKey { changedAt = now }
        last = player
    }
    func allowsHeadRestart(_ player: PlayerSnapshot, cue: Date, now: Date) -> Bool {
        guard let last, last.sameTrack(as: player), let changedAt else { return false }
        return abs(changedAt.timeIntervalSince(cue)) < 0.6 &&
            (0.08...PreplayPolicy.maximumEventAge).contains(now.timeIntervalSince(changedAt))
    }
}

final class WorkCancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

// The helper uses Apple's entitled Perl host for MediaRemote on newer macOS.
// It is bundled with the app; Homebrew and an external media-control are not used.
final class MediaTransport {
    var onChange: (() -> Void)?
    private let lock = NSLock()
    private var snapshot: PlayerSnapshot?
    private var transitions = PlayerTransitionTracker()
    private var monitor: Process?
    private var bytes = Data()
    private var generation = UUID()
    private var script: URL? { Bundle.main.resourceURL?.appendingPathComponent("MediaHelper/mediaremote-adapter.pl") }
    private var framework: URL? { Bundle.main.resourceURL?.appendingPathComponent("MediaHelper/MediaRemoteAdapter.framework") }

    var current: PlayerSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
    func allowsHeadRestart(_ player: PlayerSnapshot, cue: Date, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return transitions.allowsHeadRestart(player, cue: cue, now: now)
    }
    var available: Bool { script.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func start() {
        guard monitor == nil, let script, let framework, available else { return }
        let token = generation, p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path, "stream", "--no-diff", "--no-artwork", "--micros"]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.bytes.append(data)
                while let end = self.bytes.firstIndex(of: 10) {
                    let line = Data(self.bytes.prefix(upTo: end)); self.bytes.removeSubrange(...end)
                    let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    self.lock.lock()
                    let previous = self.snapshot
                    self.snapshot = object.flatMap { PlayerSnapshot.stream($0) }
                    self.transitions.observe(self.snapshot, at: Date())
                    let next = self.snapshot
                    self.lock.unlock()
                    self.onChange?()
                    if let previous, let next, !next.sameTrack(as: previous) {
                        // QQ's title can arrive ~450 ms after AudioQueue starts.
                        // Recheck just after metadata settles: the 400 ms general
                        // timer may otherwise miss the remaining 800 ms gate window.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                            guard let self, self.generation == token,
                                  self.current?.sameItem(as: next) == true else { return }
                            self.onChange?()
                        }
                    }
                }
                if self.bytes.count > 1_000_000 { self.bytes.removeAll() }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.monitor = nil
                self.lock.lock(); self.snapshot = nil; self.lock.unlock()
                self.onChange?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard self?.generation == token else { return }; self?.start()
                }
            }
        }
        do { try p.run(); monitor = p } catch { monitor = nil }
    }
    func stop() {
        generation = UUID()
        if let p = monitor {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        monitor = nil; bytes.removeAll()
        lock.lock(); snapshot = nil; transitions = PlayerTransitionTracker(); lock.unlock()
    }
    // Worker queue only. Check both track identity and the PID again in the native
    // helper immediately before sending a global MediaRemote command.
    func command(_ arguments: [String], expected: PlayerSnapshot, cancellation: WorkCancellation,
                 requiredPlaying: Bool? = nil) throws {
        guard !cancellation.cancelled, let actual = current, actual.sameTrack(as: expected),
              requiredPlaying == nil || actual.playing == requiredPlaying,
              let script, let framework else { throw AudioFailure(description: "播放来源已改变，取消播放控制") }
        let p = Process(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path] + arguments
        p.environment = ProcessInfo.processInfo.environment.merging(["ARM_EXPECTED_PLAYER_PID": String(expected.pid)]) { _, new in new }
        p.standardOutput = FileHandle.nullDevice; p.standardError = errors
        try p.run()
        let limit = Date().addingTimeInterval(3)
        while p.isRunning, Date() < limit, !cancellation.cancelled { Thread.sleep(forTimeInterval: 0.01) }
        if p.isRunning {
            p.terminate()
            let grace = Date().addingTimeInterval(0.2)
            while p.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
            throw AudioFailure(description: cancellation.cancelled ? "播放控制已取消" : "播放器控制超时，保持当前播放状态")
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AudioFailure(description: "播放器未接受控制（\(p.terminationStatus)）\(text.prefix(100))")
        }
    }
}
