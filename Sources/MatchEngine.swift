import Foundation
import AppKit
import Darwin

final class MatchEngine {
    let monitor = LogMonitor()
    var onUpdate: (() -> Void)?
    var enabled = true
    var dryRun = false
    var preferredUID: String?
    var preferredSource: String?
    private(set) var sourceRate: Double?
    private(set) var output: OutputDevice?
    private(set) var clients: [AudioClient] = []
    private(set) var resolution = SourceResolution(observations: [], rate: nil, reason: "正在读取播放记录…")
    private(set) var state = "正在读取播放记录…"
    private(set) var matched = false
    private(set) var history: [String] = []
    private var evidence: [Int32: PlaybackEvidence] = [:]
    private var waiting: [PlaybackEvent] = []
    private var timer: Timer?
    private var ready = false
    private var pendingWrite: UUID?
    private var lastSourceKey = ""
    private var gate = SwitchGate()
    private var monitorFault: String?
    private var writeFault: String?
    private var logHandle: FileHandle?

    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AudioRateMatch/AudioRateMatch.log")

    init() {
        let url = Self.logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !CommandLine.arguments.contains("--watch"), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 {
            let previous = url.deletingLastPathComponent().appendingPathComponent("AudioRateMatch.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if descriptor >= 0 { logHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) }
        monitor.onEvents = { [weak self] events, initial in
            guard let self else { return }
            self.waiting.append(contentsOf: events)
            if initial { self.ready = true }
            self.tick()
        }
        monitor.onError = { [weak self] message, fatal in
            guard let self else { return }
            if fatal {
                self.ready = false; self.pendingWrite = nil; self.monitorFault = message
                self.evidence.removeAll(); self.waiting.removeAll(); self.sourceRate = nil
            }
            self.record(message); self.tick()
        }
    }
    func start() {
        record("启动 \(AppInfo.displayName)；\(dryRun ? "只读检测" : "自动修改系统输出")；应用=\(preferredSource ?? "自动跟随所有应用")")
        monitor.start()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        timer?.invalidate(); timer = nil; pendingWrite = nil
        monitor.stop(); try? logHandle?.close()
    }
    func retry() {
        monitorFault = nil; writeFault = nil; gate.reset(); pendingWrite = nil; ready = false
        lastSourceKey = ""; evidence.removeAll(); waiting.removeAll()
        monitor.start(); tick()
    }
    func changedSelection() {
        pendingWrite = nil; lastSourceKey = ""; writeFault = nil
        _ = gate.observe(nil, now: Date()); tick()
    }
    func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        history.append(line); if history.count > 16 { history.removeFirst() }
        try? logHandle?.write(contentsOf: Data((line + "\n").utf8))
        if dryRun { print(line); fflush(stdout) }
    }
    private func updateEvidence(now: Date) {
        let byPID = Dictionary(clients.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        evidence = evidence.filter { pid, item in byPID[pid]?.identity == item.identity }
        var deferred: [PlaybackEvent] = []
        for event in waiting {
            if let client = byPID[event.pid] {
                var item = evidence[event.pid] ?? PlaybackEvidence()
                item.accept(event, client: client); evidence[event.pid] = item
            } else if let date = event.date, now.timeIntervalSince(date) < 10 {
                // A newly started process can log its format before it appears in the HAL list.
                deferred.append(event)
            }
        }
        waiting = Array(deferred.suffix(2048))
    }
    func tick() {
        defer { onUpdate?() }
        matched = false
        let now = Date(), defaultOutput = Hardware.defaultOutput()
        clients = Hardware.clients()
        updateEvidence(now: now)
        output = preferredUID.flatMap { uid in Hardware.devices().first { $0.uid == uid } } ?? (preferredUID == nil ? defaultOutput : nil)
        guard let output else { sourceRate = nil; state = "等待输出设备连接"; _ = gate.observe(nil, now: now); return }
        let endpoint = OutputEndpoint(id: output.id, uid: output.uid, isDefault: output.id == defaultOutput?.id)
        resolution = SourcePolicy.resolve(clients: clients, evidence: evidence, output: endpoint, preferred: preferredSource)
        sourceRate = resolution.rate
        guard enabled else { state = "已暂停自动切换"; _ = gate.observe(nil, now: now); return }
        guard ready, monitorFault == nil else {
            state = monitorFault ?? "正在读取播放记录…"; _ = gate.observe(nil, now: now); return
        }
        guard let rate = resolution.rate else { state = resolution.reason; _ = gate.observe(nil, now: now); return }
        let sourceKey = "\(output.uid)|\(rate)|" + resolution.observations.map { $0.client.identity }.joined(separator: ",")
        if sourceKey != lastSourceKey {
            lastSourceKey = sourceKey; writeFault = nil
            record("确认播放：\(resolution.names)；\(rateText(rate)) kHz；设备=\(output.name)")
        }
        let stable = gate.observe(sourceKey, now: now)
        if Hardware.verified(output, rate: rate) {
            matched = true; state = "已匹配 · 系统与硬件流回读一致"; return
        }
        if let writeFault { state = writeFault; return }
        guard output.supports(rate) else { state = "设备不支持 \(rateText(rate)) kHz，保持当前设置"; return }
        guard !dryRun else { state = "只读：系统需要 \(rateText(output.rate)) → \(rateText(rate)) kHz"; return }
        guard stable else { state = "等待播放流稳定…"; return }
        guard pendingWrite == nil else { state = "正在切换并回读硬件…"; return }
        guard gate.allowWrite(device: output.uid, now: now) else {
            state = "切换过于频繁，暂缓至稳定后重试"; return
        }
        let operation = UUID(); pendingWrite = operation
        do {
            try Hardware.setRate(rate, on: output)
            gate.didWrite(device: output.uid, now: now)
            state = "正在切换并回读硬件…"
            record("写入系统设备 \(output.name)：\(rateText(output.rate)) → \(rateText(rate)) kHz；来源=\(resolution.names)")
            verify(id: output.id, uid: output.uid, rate: rate, sourceKey: sourceKey, operation: operation, attempt: 0)
        } catch {
            pendingWrite = nil; writeFault = String(describing: error); state = writeFault!; record(state)
        }
    }
    private func verify(id: UInt32, uid: String, rate: Double, sourceKey: String, operation: UUID, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.15 : 0.45)) { [weak self] in
            guard let self, self.pendingWrite == operation else { return }
            guard self.enabled, let device = Hardware.device(id), device.uid == uid else { self.pendingWrite = nil; return }
            if Hardware.verified(device, rate: rate) {
                self.pendingWrite = nil
                self.record("验证成功：系统 \(rateText(device.rate)) kHz；硬件流 \(device.physicalRates.map(rateText).joined(separator: ", ")) kHz")
                self.tick()
            } else if attempt < 4 {
                self.verify(id: id, uid: uid, rate: rate, sourceKey: sourceKey, operation: operation, attempt: attempt + 1)
            } else {
                self.pendingWrite = nil
                if self.lastSourceKey == sourceKey { self.writeFault = "写入后回读不一致，请检查设备占用或其他切换工具" }
                self.record("写入后回读不一致：\(device.name)"); self.tick()
            }
        }
    }
    func observedRate(for client: AudioClient) -> Double? {
        guard let output else { return nil }
        return evidence[client.pid]?.rate(for: OutputEndpoint(id: output.id, uid: output.uid, isDefault: output.id == Hardware.defaultOutput()?.id), client: client)
    }
    var report: String {
        let lines = resolution.observations.map { "\($0.client.name) [\($0.client.pid)]：\($0.rate.map { rateText($0) + " kHz" } ?? "格式未确认")" }
        return """
        \(AppInfo.displayName)
        跟随模式：\(preferredSource ?? "自动跟随所有应用（同采样率时切换）")
        播放流：\(sourceRate.map { rateText($0) + " kHz" } ?? "未确认或冲突")
        系统输出：\(output?.name ?? "无")
        系统采样率：\(output.map { rateText($0.rate) + " kHz" } ?? "未知")
        硬件流采样率：\(output?.physicalRates.map { rateText($0) + " kHz" }.joined(separator: ", ") ?? "未知")
        状态：\(state)
        \(lines.joined(separator: "\n"))

        \(history.joined(separator: "\n"))
        """
    }
}
