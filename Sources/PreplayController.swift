import Foundation
import CoreAudio
import AudioToolbox

private struct UserPlaybackChange: Error, CustomStringConvertible {
    let description: String
}

private final class BufferedDelay: AudioProcessor {
    private(set) var buffer: OpaquePointer?
    func prepare(sampleRate: Double) {
        if let buffer { ARMBufferDestroy(buffer) }
        buffer = ARMBufferCreate(sampleRate, PreplayPolicy.delay)
    }
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        guard let buffer, channelCount == 2 else {
            memset(samples, 0, frameCount * channelCount * MemoryLayout<Float>.size); return
        }
        ARMBufferProcess(buffer, samples, UInt32(frameCount))
    }
    deinit { if let buffer { ARMBufferDestroy(buffer) } }
}

private final class BufferedSession {
    let delay = BufferedDelay()
    let engine: SystemAudioTapEngine
    let uid: String
    init(uid: String) { self.uid = uid; engine = SystemAudioTapEngine(processor: delay) }
    func start() throws {
        try engine.start(outputUID: uid)
        guard delay.buffer != nil else { engine.stop(); throw AudioFailure(description: "无法分配播放缓冲区") }
    }
    func stop() { engine.stop() }
    var stats: ARMBufferStats { ARMBufferReadStats(delay.buffer) }
    deinit { engine.stop() }
}

private final class PlaybackWitness {
    private let lock = NSLock()
    private var events: [PlaybackEvent] = []
    func add(_ incoming: [PlaybackEvent]) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-15)
        events = (events + incoming).filter { ($0.date ?? .distantPast) > cutoff }.suffix(1024).map { $0 }
    }
    func restarted(pid: Int32, rate: Double, after: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let events = events.filter { $0.pid == pid }
        return events.contains { event in
            guard let date = event.date, date >= after, case let .start(id, _) = event.kind else { return false }
            return events.contains { format in
                if case let .format(key, value) = format.kind { return key == id && abs(value - rate) < 0.1 }
                return false
            }
        }
    }
}

// Main-queue control, serial worker for Core Audio and MediaRemote round trips.
// The only shared audio state is the C buffer's atomics. No device calls on UI/IO threads.
final class PreplayController {
    let transport = MediaTransport()
    var onUpdate: (() -> Void)?
    var onRecord: ((String) -> Void)?
    private(set) var status = "播放前匹配尚未启动"
    private(set) var busy = false
    private(set) var runningUID: String?
    private(set) var fault: String?
    private let worker = DispatchQueue(label: "local.audioratematch.preplay", qos: .userInitiated)
    private let witness = PlaybackWitness()
    private var work = WorkCancellation()
    private var desiredUID: String?
    private var preparing = false
    private var view: BufferedSession? // Main queue's strong reference for atomic statistics.
    private var active: BufferedSession? // Worker queue only.
    private var seenCues: Set<String> = []
    private var silentSince: Date?

    func start() { transport.start() }
    func note(_ events: [PlaybackEvent]) { witness.add(events) }
    var statsText: String {
        guard let view else { return fault ?? "未建立缓冲" }
        let s = view.stats
        return "\(Int(PreplayPolicy.delay * 1000)) ms；输入 \(s.inputFrames) 帧；非零 \(s.nonzeroInputFrames)；迟到 \(s.lateGates)；溢出 \(s.overruns)"
    }
    func ensure(device: OutputDevice?, enabled: Bool, hasAudio: Bool) {
        guard enabled, let device else {
            if desiredUID != nil || preparing || busy { stop() }
            return
        }
        guard fault == nil else { return }
        if desiredUID == device.uid {
            if let view, !busy, abs(view.engine.sampleRate - device.rate) > 0.1 {
                let message = "输出采样率已被其他程序改变，已恢复直通；请重新检测"
                stop(); fault = message; status = message; onRecord?(message); return
            }
            // Fail open if capture stays silent while a source is known to be
            // running. This also prevents missing TCC permission from muting audio.
            if let view, !busy, hasAudio, view.stats.nonzeroInputFrames == 0 {
                if silentSince == nil { silentSince = Date() }
                if Date().timeIntervalSince(silentSince!) > 4 {
                    let message = "缓冲未收到音频，请检查系统音频录制权限；已恢复直通"
                    stop(); fault = message; status = message; onRecord?(message)
                }
            } else { silentSince = nil }
            return
        }
        stop()
        fault = nil; desiredUID = device.uid; preparing = true
        status = "正在准备播放缓冲…"; onUpdate?()
        let token = work
        worker.async { [weak self] in
            guard let self, !token.cancelled else { return }
            do {
                let session = BufferedSession(uid: device.uid)
                try session.start()
                if token.cancelled { session.stop(); return }
                self.active = session
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.work === token, !token.cancelled else { return }
                    self.view = session; self.runningUID = device.uid; self.preparing = false
                    self.status = "播放缓冲就绪 · 等待需要切换的新歌"
                    self.onRecord?("播放缓冲已建立：\(device.name)，\(rateText(session.engine.sampleRate)) kHz，延迟 \(Int(PreplayPolicy.delay * 1000)) ms")
                    self.onUpdate?()
                }
            } catch {
                self.active?.stop(); self.active = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.work === token else { return }
                    self.preparing = false; self.fault = "无法建立播放缓冲：\(error.localizedDescription)"
                    self.status = self.fault!; self.onRecord?(self.status); self.onUpdate?()
                }
            }
        }
    }
    func stop(wait: Bool = false) {
        work.cancel(); work = WorkCancellation()
        desiredUID = nil; runningUID = nil; preparing = false; busy = false
        view = nil; seenCues.removeAll(); silentSince = nil
        let teardown = { [self] in active?.stop(); active = nil }
        if wait { worker.sync(execute: teardown) } else { worker.async(execute: teardown) }
    }
    func retry(startTransport: Bool) {
        stop(); fault = nil; transport.stop()
        if startTransport { transport.start() }
    }
    func freshSelection() { fault = nil }
    func shutdown() { transport.stop(); stop(wait: true) }

    // A delayed/stale cue is never converted into a mid-song hardware switch.
    func schedule(cue: PreplayCue, device: OutputDevice, clients: [AudioClient], completion: @escaping (Bool, String) -> Void) -> Bool {
        guard !busy, !preparing, fault == nil, runningUID == device.uid, let view,
              let buffer = view.delay.buffer, !seenCues.contains(cue.identity) else { return false }
        guard let player = transport.current, player.playing, !player.itemID.isEmpty, player.pid == cue.pid else {
            status = "等待播放器提供可控制的播放状态 · 当前采样率保持"; return false
        }
        guard PreplayPolicy.exclusiveSource(pid: player.pid, clients: clients, outputID: device.id) else {
            status = "其他应用也在向此设备输出，暂缓播放前切换"; return false
        }
        guard transport.allowsHeadRestart(player, cue: cue.startedAt) else {
            status = "等待可确认的新歌 · 本次保持设备采样率"; return false
        }
        guard Date().timeIntervalSince(cue.startedAt) <= PreplayPolicy.maximumEventAge,
              ARMBufferArm(buffer, Date().timeIntervalSince(cue.startedAt)) else {
            status = "起播通知已迟到 · 本次保持设备采样率"; return false
        }
        seenCues.insert(cue.identity)
        if seenCues.count > 128 { seenCues = [cue.identity] }
        busy = true; status = "正在保留歌头并暂停播放器…"; onUpdate?()
        let token = work, initialLate = view.stats.lateGates
        worker.async { [weak self] in
            guard let self else { return }
            var pausedByUs = false, rateChanged = false
            do {
                try self.check(player, token: token, item: true, mustBePlaying: true)
                guard self.active === view else { throw AudioFailure(description: "音频路径已改变") }
                try self.transport.command(["send", "1"], expected: player, cancellation: token, requiredPlaying: true)
                guard self.wait(1, token: token, until: { self.transport.current?.playing == false }) else {
                    throw AudioFailure(description: "播放器未确认暂停，已取消硬件切换")
                }
                pausedByUs = true
                try self.check(player, token: token, item: true, mustBePaused: true)
                guard self.wait(PreplayPolicy.delay + 0.4, token: token, until: { view.stats.held }),
                      view.stats.lateGates == initialLate, view.stats.overruns == 0 else {
                    throw AudioFailure(description: "歌头未及时留在缓冲区，已取消硬件切换")
                }
                try self.check(player, token: token, item: true, mustBePaused: true)
                self.publish("正在切换采样率并等待设备稳定…", token: token)
                // The selected player is paused before the old tap is stopped. The
                // tap's mutedWhenTapped behavior restores passthrough on teardown.
                view.stop(); self.active = nil
                try self.check(player, token: token, item: true, mustBePaused: true)
                guard let current = Hardware.device(device.id), current.uid == device.uid else {
                    throw AudioFailure(description: "输出设备已断开")
                }
                try Hardware.setRate(cue.rate, on: current); rateChanged = true
                // Wait for the device format before constructing a tap at its new
                // native rate; running that tap then supplies a measurable clock.
                guard self.wait(3, token: token, until: {
                    guard let actual = Hardware.device(device.id), actual.uid == device.uid else { return false }
                    return Hardware.verified(actual, rate: cue.rate)
                }) else { throw AudioFailure(description: "设备格式回读超时，播放器保持暂停") }
                try self.check(player, token: token, item: true, mustBePaused: true)
                let next = BufferedSession(uid: device.uid)
                try next.start(); self.active = next
                guard abs(next.engine.sampleRate - cue.rate) < 0.1 else {
                    throw AudioFailure(description: "缓冲与设备采样率不一致，播放器保持暂停")
                }
                var readiness = ClockReadiness()
                guard try self.wait(8, token: token, until: {
                    guard let actual = Hardware.device(device.id), actual.uid == device.uid else { return false }
                    guard let stamp = next.engine.currentTime() else { return false }
                    return readiness.observe(host: Double(AudioConvertHostTimeToNanos(stamp.mHostTime)) / 1e9,
                                             sample: stamp.mSampleTime, targetRate: cue.rate,
                                             formatMatches: Hardware.verified(actual, rate: cue.rate))
                }, validate: { try self.check(player, token: token, item: true, mustBePaused: true) }) else {
                    throw AudioFailure(description: "设备时钟未稳定，播放器保持暂停")
                }
                try self.check(player, token: token, item: true, mustBePaused: true)
                guard let nextBuffer = next.delay.buffer else { throw AudioFailure(description: "播放缓冲丢失") }
                let reset = ARMBufferReset(nextBuffer)
                guard self.wait(0.5, token: token, until: { next.stats.resets >= reset }) else {
                    throw AudioFailure(description: "设备音频回调未运行，播放器保持暂停")
                }
                self.publish("设备已稳定，正在从歌头恢复…", token: token)
                let seekAt = Date()
                // QQ may resume as a consequence of seek, so seek ONLY after the
                // DAC is ready and the new-rate buffer is already capturing.
                try self.transport.command(["seek", "0"], expected: player, cancellation: token)
                try self.check(player, token: token, item: false)
                if self.transport.current?.playing == false {
                    try self.transport.command(["send", "0"], expected: player, cancellation: token)
                }
                guard self.wait(2, token: token, until: {
                    self.witness.restarted(pid: player.pid, rate: cue.rate, after: seekAt)
                }) else { throw AudioFailure(description: "未确认播放器重建歌头，请手动开始播放") }
                try self.check(player, token: token, item: false)
                self.finish(token: token, success: true, message: "播放前匹配完成 · \(rateText(cue.rate)) kHz", completion: completion)
            } catch {
                // Never issue a late play/seek to another song or after cancellation.
                // A failed switch after a device write leaves our player paused.
                if !token.cancelled, rateChanged, !(error is UserPlaybackChange), let current = self.transport.current,
                   current.sameTrack(as: player), current.playing {
                    try? self.transport.command(["send", "1"], expected: player, cancellation: token)
                }
                if !token.cancelled, pausedByUs, !rateChanged, let current = self.transport.current,
                   current.sameItem(as: player), !current.playing {
                    // Restore the original path, not a held delay containing stale PCM.
                    self.active?.stop(); self.active = nil
                    try? self.transport.command(["send", "0"], expected: player, cancellation: token)
                }
                // A failed/unsupported operation always restores direct output.
                // Releasing a held ring would replay stale samples and add delay.
                self.active?.stop(); self.active = nil
                self.finish(token: token, success: false, message: String(describing: error), completion: completion)
            }
        }
        return true
    }
    private func check(_ expected: PlayerSnapshot, token: WorkCancellation, item: Bool,
                       mustBePaused: Bool = false, mustBePlaying: Bool = false) throws {
        guard !token.cancelled, let actual = transport.current, actual.sameTrack(as: expected) else {
            throw UserPlaybackChange(description: "用户已切换播放内容或停止操作，取消自动恢复")
        }
        if mustBePaused, actual.playing { throw UserPlaybackChange(description: "用户已恢复播放，取消回到歌头") }
        if mustBePlaying, !actual.playing { throw UserPlaybackChange(description: "用户已暂停播放，取消自动操作") }
        guard !item || actual.sameItem(as: expected) else {
            throw UserPlaybackChange(description: "用户已改变播放位置，取消自动恢复")
        }
    }
    private func wait(_ seconds: TimeInterval, token: WorkCancellation, until predicate: () -> Bool,
                      validate: (() throws -> Void)? = nil) rethrows -> Bool {
        let limit = Date().addingTimeInterval(seconds)
        repeat {
            guard !token.cancelled else { return false }
            try validate?()
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < limit
        return false
    }
    private func publish(_ text: String, token: WorkCancellation) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.work === token, !token.cancelled else { return }
            self.status = text; self.onUpdate?()
            self.onRecord?(text)
        }
    }
    private func finish(token: WorkCancellation, success: Bool, message: String, completion: @escaping (Bool, String) -> Void) {
        let session = active
        DispatchQueue.main.async { [weak self] in
            guard let self, self.work === token, !token.cancelled else { return }
            self.busy = false; self.view = session; self.runningUID = session?.uid
            self.status = message
            if !success { self.fault = message }
            self.onRecord?(message); completion(success, message); self.onUpdate?()
        }
    }
}
