import Foundation

final class LogMonitor {
    static let predicate = "subsystem == \"com.apple.coreaudio\" AND (eventMessage CONTAINS \"New output; format\" OR eventMessage CONTAINS \"client starting:\" OR eventMessage CONTAINS \"client stopping:\")"
    var onEvents: (([PlaybackEvent], Bool) -> Void)?
    var onError: ((String, Bool) -> Void)?
    // All mutable state belongs to the main queue. Blocking pipe reads run in the background.
    private var stream: Process?
    private var archive: Process?
    private var generation = UUID()
    private var pending = Data()
    private var buffered: [PlaybackEvent] = []
    private var loading = true

    func start() {
        stop()
        let token = generation
        let process = Process(), pipe = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--level", "info", "--predicate", Self.predicate]
        process.standardOutput = pipe; process.standardError = errors
        stream = process
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { [weak self] in self?.consume(data, token: token) }
        }
        process.terminationHandler = { [weak self] process in
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.stop()
                self.onError?("播放日志监听已停止（\(process.terminationStatus)）\(message.prefix(180))；请重新检测", true)
            }
        }
        do { try process.run() }
        catch { stop(); onError?("无法启动日志读取：\(error.localizedDescription)", true); return }
        loadArchive(token: token)
    }
    private func consume(_ data: Data, token: UUID) {
        guard generation == token else { return }
        pending.append(data)
        var events: [PlaybackEvent] = []
        while let end = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: end)
            pending.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let event = PlaybackEvent.parse(object) else { continue }
            events.append(event)
        }
        if loading { buffered.append(contentsOf: events) }
        else if !events.isEmpty { deliver(events, initial: false, token: token) }
        if pending.count > 1_000_000 { pending.removeAll() }
    }
    private func loadArchive(token: UUID) {
        let process = Process(), pipe = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "2h", "--info", "--style", "ndjson", "--predicate", Self.predicate]
        process.standardOutput = pipe; process.standardError = errors
        archive = process
        do { try process.run() } catch {
            finishArchive([], token: token, error: error.localizedDescription); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard self?.generation == token else { return }
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let events = data.split(separator: 10).compactMap { line -> PlaybackEvent? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
                return PlaybackEvent.parse(object)
            }
            let failure = process.terminationStatus == 0 ? nil : String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            DispatchQueue.main.async { [weak self] in self?.finishArchive(events, token: token, error: failure) }
        }
    }
    private func finishArchive(_ events: [PlaybackEvent], token: UUID, error: String?) {
        guard generation == token else { return }
        archive = nil
        let all = (events + buffered).enumerated().sorted {
            $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
        buffered.removeAll(); loading = false
        deliver(all, initial: true, token: token)
        if let error, !error.isEmpty {
            onError?("历史日志不可读：\(error.prefix(180))；等待下一次切歌", false)
        }
    }
    private func deliver(_ events: [PlaybackEvent], initial: Bool, token: UUID) {
        guard generation == token else { return }
        onEvents?(events, initial)
    }
    func stop() {
        generation = UUID()
        if let process = stream { (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil; if process.isRunning { process.terminate() } }
        if let process = archive, process.isRunning { process.terminate() }
        stream = nil; archive = nil
        pending.removeAll(); buffered.removeAll(); loading = true
    }
    deinit { stop() }
}
