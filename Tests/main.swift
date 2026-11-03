import Foundation

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func event(_ message: String, _ second: Int, pid: Int32 = 743, path: String = "") -> PlaybackEvent {
    let timestamp = String(format: "2026-10-29 12:00:%02d.000000+0800", second)
    return PlaybackEvent.parse(["eventMessage": message, "timestamp": timestamp, "processID": NSNumber(value: pid), "processImagePath": path])!
}
func format(_ rate: Int, queue: String = "0xabc") -> String {
    "AudioQueueObject.cpp:474 AudioQueueObject: aq@\(queue): New output; format  2 ch,  \(rate) Hz, lpcm (0x00000004) 24-bit little-endian signed integer (passthrough? no)"
}
func start(_ queue: String = "0xabc", route: String = "Default-Output") -> String {
    "MEDeviceStreamClient.cpp:243 AQME \(route): client starting: <AudioQueueObject@\(queue); Unknown FigPlayer; [743]; play>; running count now 1"
}
func stop(_ queue: String = "0xabc") -> String { start(queue).replacingOccurrences(of: "starting", with: "stopping") }
let began = event(format(96000), 0).date!.addingTimeInterval(-1)
func client(_ pid: Int32 = 743, object: UInt32 = 9, devices: [UInt32] = [114], running: Bool = true, born: Date? = began, path: String = "/test/player") -> AudioClient {
    AudioClient(objectID: object, pid: pid, bundleID: "app.\(pid)", path: path, name: "Player \(pid)", startedAt: born, running: running, deviceIDs: devices)
}
let usb = OutputEndpoint(id: 114, uid: "USB-DAC", isDefault: true)
let speaker = OutputEndpoint(id: 102, uid: "Speaker", isDefault: false)
let first = client()
var state = PlaybackEvidence()
state.accept(event(format(96000), 1), client: first)
check(state.rate(for: usb, client: first) == nil, "Preload must not set device rate")
state.accept(event(start(), 2), client: first)
check(state.rate(for: usb, client: first) == 96000, "A playing queue resolves to 96 kHz")
state.accept(event(format(44100, queue: "0xdef"), 3), client: first)
check(state.rate(for: usb, client: first) == 96000, "Next-song preload must not lower the rate")
state.accept(event(start("0xdef"), 4), client: first)
check(state.rate(for: usb, client: first) == nil, "Different overlapping queue rates are ambiguous")
state.accept(event(stop(), 5), client: first)
check(state.rate(for: usb, client: first) == 44100, "Transition resolves after old queue stops")
state.accept(event(start(), 1), client: first)
check(state.rate(for: usb, client: first) == 44100, "Old archive event cannot resurrect queue")
state.accept(event(stop("0xdef"), 6), client: first)
check(state.rate(for: usb, client: first) == nil, "Stopped queue cannot control device")
state.accept(event(start("0xdef"), 7), client: first)
check(state.rate(for: usb, client: first) == 44100, "Resume reuses known queue format")
check(state.rate(for: usb, client: client(running: false)) == nil, "Independent HAL pause overrides stale logs")
check(state.rate(for: usb, client: client(devices: [102])) == nil, "Another output device cannot trigger a write")
check(state.rate(for: usb, client: client(devices: [])) == nil, "Unknown route is not assumed to be default output")
check(state.rate(for: usb, client: client(object: 10)) == nil, "PID reuse with new process object invalidates evidence")
state.accept(event(stop("0xdef"), 8, pid: 999), client: first)
check(state.rate(for: usb, client: first) == 44100, "Another process cannot stop this process's queue")
state.accept(event(stop("0xdef"), 9, path: "/different/player"), client: first)
check(state.rate(for: usb, client: first) == 44100, "Wrong executable path is ignored")

let second = client(888, object: 11)
var state2 = PlaybackEvidence()
state2.accept(event(format(96000), 1, pid: 888), client: second)
state2.accept(event(start(), 2, pid: 888), client: second)
check(state2.rate(for: usb, client: second) == 96000, "An unrelated app and identical queue address are supported")
let allEvidence = [first.pid: state, second.pid: state2]
check(SourcePolicy.resolve(clients: [first], evidence: allEvidence, output: usb, preferred: nil).rate == 44100, "Single app auto follows")
check(SourcePolicy.resolve(clients: [first, second], evidence: allEvidence, output: usb, preferred: nil).rate == nil, "Unequal applications must not fight")
check(SourcePolicy.resolve(clients: [first, second], evidence: allEvidence, output: usb, preferred: second.selectionKey).rate == 96000, "Explicit app priority resolves conflict")
let otherDeviceClient = client(888, object: 11, devices: [102])
check(SourcePolicy.resolve(clients: [first, otherDeviceClient], evidence: allEvidence, output: usb, preferred: nil).rate == 44100, "Another device's app cannot cause conflict")
check(SourcePolicy.resolve(clients: [first, second], evidence: [first.pid: state], output: usb, preferred: nil).rate == nil, "Unknown simultaneous output blocks automatic switch")
check(SourcePolicy.resolve(clients: [first], evidence: allEvidence, output: usb, preferred: second.selectionKey).rate == nil, "Pinned app does not silently fall back to another")
state2.accept(event(format(44100), 3, pid: 888), client: second)
check(SourcePolicy.resolve(clients: [first, second], evidence: [first.pid: state, second.pid: state2], output: usb, preferred: nil).rate == 44100, "Multiple matching sources can follow together")

var routed = PlaybackEvidence()
let twoDevices = client(devices: [114, 102])
routed.accept(event(format(96000), 1), client: twoDevices)
routed.accept(event(start(route: "Device-USB-DAC"), 2), client: twoDevices)
routed.accept(event(format(48000, queue: "0xdef"), 3), client: twoDevices)
routed.accept(event(start("0xdef", route: "Device-Speaker"), 4), client: twoDevices)
check(routed.rate(for: usb, client: twoDevices) == 96000, "Per-queue USB routing selects correct rate")
check(routed.rate(for: speaker, client: twoDevices) == 48000, "Per-queue speaker routing selects other rate")
let replacement = client(object: 55, born: began.addingTimeInterval(10))
routed.accept(event(format(96000), 1), client: replacement)
check(routed.rate(for: usb, client: replacement) == nil, "Events before new process birth cannot be reused")
routed.accept(event(start(), 12), client: replacement)
check(routed.rate(for: usb, client: replacement) == nil, "Unknown new queue has no 44.1 fallback")
routed.accept(event(format(96000), 13), client: replacement)
check(routed.rate(for: usb, client: replacement) == 96000, "Late format evidence resolves new process")
check(event(format(96000), 1).date != nil, "System log timestamp parses including microseconds and timezone")
check(PlaybackEvent.parse(["processID": 3, "timestamp": "x", "eventMessage": "AUHAL.cpp UpdateStreamFormats: Output render format: 2 ch, 96000 Hz"]) == nil, "Hardware render format is not original source evidence")
check(PlaybackEvent.parse(["processID": 3, "timestamp": "x", "eventMessage": format(0)]) == nil, "Invalid sample rate rejected")
check(PlaybackEvent.parse(["processID": 3, "timestamp": "x", "eventMessage": "converter from 96000 Hz to 44100 Hz"]) == nil, "Unrelated converter format rejected")

// Core Audio logs observed on macOS 27.2 use the object name before its address.
func objectFormat(_ rate: Int, queue: String) -> String {
    "AudioQueueObject.cpp:475   AudioQueueObject@\(queue) AudioQueueObject: New output; format  2 ch,  \(rate) Hz, lpcm (0x00000004) 24-bit little-endian signed integer (passthrough? no)"
}
let objectEvent = PlaybackEvent.parse([
    "eventMessage": objectFormat(48000, queue: "0x123abc"),
    "timestamp": "2026-10-29 12:00:01.000000+0800", "processID": NSNumber(value: first.pid)
])
check(objectEvent != nil, "Object-prefixed Core Audio source format must be recognized")
var objectEvidence = PlaybackEvidence()
objectEvidence.accept(objectEvent!, client: first)
check(objectEvidence.rate(for: usb, client: first) == nil, "Object-prefixed preload still requires its queue to start")
objectEvidence.accept(event(start("0x123abc"), 2), client: first)
check(SourcePolicy.resolve(clients: [first], evidence: [first.pid: objectEvidence], output: usb, preferred: nil).rate == 48000,
      "Object format and matching playback event resolve to 48 kHz")
objectEvidence.accept(event(objectFormat(96000, queue: "0x456def"), 3), client: first)
check(objectEvidence.rate(for: usb, client: first) == 48000, "New-style 96 kHz preload cannot replace playing 48 kHz queue")
objectEvidence.accept(event(start("0x456def"), 4), client: first)
check(objectEvidence.rate(for: usb, client: first) == nil, "New-style overlapping rates remain ambiguous")
objectEvidence.accept(event(stop("0x123abc"), 5), client: first)
check(SourcePolicy.resolve(clients: [first], evidence: [first.pid: objectEvidence], output: usb, preferred: nil).rate == 96000,
      "New-style transition resolves to 96 kHz after the old queue stops")

var gate = SwitchGate()
let now = Date()
check(!gate.observe("DAC|96000", now: now), "New stream waits for stability")
check(!gate.observe("DAC|96000", now: now.addingTimeInterval(0.3)), "Short notification cannot immediately switch")
check(gate.observe("DAC|96000", now: now.addingTimeInterval(0.8)), "Stable stream can switch")
_ = gate.observe(nil, now: now.addingTimeInterval(1))
check(!gate.observe("DAC|96000", now: now.addingTimeInterval(1.1)), "Unknown or paused stream resets stability")
for offset in 0..<5 { gate.didWrite(device: "DAC", now: now.addingTimeInterval(Double(offset))) }
check(!gate.allowWrite(device: "DAC", now: now.addingTimeInterval(5)), "Budget survives source/rate changes")
check(gate.allowWrite(device: "other", now: now.addingTimeInterval(5)), "Unrelated device has separate budget")
check(gate.allowWrite(device: "DAC", now: now.addingTimeInterval(20)), "Rate limit expires after stable interval")
let freshStart = event(start(), 2)
let freshNow = freshStart.date!.addingTimeInterval(0.35)
var freshEvidence = PlaybackEvidence()
freshEvidence.accept(event(format(96000), 1), client: first)
freshEvidence.accept(freshStart, client: first)
func cue(_ events: [PlaybackEvent], _ evidence: PlaybackEvidence = freshEvidence,
         at time: Date = freshNow, from source: AudioClient = first) -> PreplayCue? {
    PreplayPolicy.cue(events: events, clients: [source], evidence: [source.pid: evidence],
                      output: usb, rate: 96000, now: time)
}
check(cue([freshStart])?.rate == 96000, "Fresh native-rate start can arm preplay")
check(cue([event(format(96000), 1)]) == nil, "Preload alone cannot arm preplay")
check(cue([freshStart], at: freshNow.addingTimeInterval(1)) == nil, "Late start cannot cause a mid-song write")
check(cue([freshStart], at: freshStart.date!.addingTimeInterval(-1)) == nil, "Future-dated start is rejected")
check(cue([freshStart], from: client(running: false)) == nil, "Paused HAL client cannot arm")
check(cue([freshStart], from: client(object: 999)) == nil, "Reused PID cannot reuse another process's cue")
check(cue([freshStart], from: client(devices: [102])) == nil, "Another device's start cannot arm")
var stoppedEvidence = freshEvidence
stoppedEvidence.accept(event(stop(), 3), client: first)
check(cue([freshStart], stoppedEvidence) == nil, "A subsequently stopped queue cannot arm")
var overlapEvidence = freshEvidence
overlapEvidence.accept(event(format(48000, queue: "0xdef"), 3), client: first)
overlapEvidence.accept(event(start("0xdef"), 4), client: first)
check(cue([freshStart], overlapEvidence) == nil, "Ambiguous overlap cannot arm")

var clock = ClockReadiness()
check(!clock.observe(host: 1, sample: 0, targetRate: 96000, formatMatches: true), "One clock sample is insufficient")
check(!clock.observe(host: 1.1, sample: 9600, targetRate: 96000, formatMatches: true), "DAC needs a stable interval")
check(clock.observe(host: 1.6, sample: 57600, targetRate: 96000, formatMatches: true), "Monotonic target-rate clock becomes ready")
check(!clock.observe(host: 1.7, sample: 0, targetRate: 96000, formatMatches: true), "Clock reset invalidates readiness")
check(!clock.observe(host: 1.8, sample: 9600, targetRate: 96000, formatMatches: false), "Nominal clock alone cannot override a wrong physical format")
check(!clock.observe(host: 2, sample: 14400, targetRate: 96000, formatMatches: true), "Wrong effective clock rate is rejected")
check(!clock.observe(host: 2, sample: 14400, targetRate: 96000, formatMatches: true), "Frozen clock is rejected")
check(!clock.observe(host: .nan, sample: .nan, targetRate: 96000, formatMatches: true), "Invalid clock values are rejected")

var playerData: [String: Any] = ["bundleIdentifier": "com.tencent.QQMusicMac", "processIdentifier": 743,
    "title": "A", "artist": "B", "durationMicros": 100000000, "playing": true, "contentItemIdentifier": "first"]
let player = PlayerSnapshot(playerData)!
check(PlayerSnapshot.stream(["type": "data", "diff": false, "payload": playerData])?.sameItem(as: player) == true,
      "Adapter streaming envelope yields the full current player")
check(PlayerSnapshot.stream(["type": "data", "diff": true, "payload": ["playing": false]]) == nil,
      "Partial streaming diffs cannot become a guessed player")
check(PlayerSnapshot.stream(["type": "data", "diff": false, "payload": [:]]) == nil,
      "Empty initial stream event clears current state")
var transitions = PlayerTransitionTracker()
transitions.observe(player, at: now)
check(!transitions.allowsHeadRestart(player, cue: now, now: now.addingTimeInterval(0.2)), "Initial playback may already be mid-song")
transitions.observe(player, at: now.addingTimeInterval(1))
check(!transitions.allowsHeadRestart(player, cue: now.addingTimeInterval(1), now: now.addingTimeInterval(1.2)), "Pause/resume must not seek to the beginning")
playerData["contentItemIdentifier"] = "after-seek"
let afterSeek = PlayerSnapshot(playerData)!
check(afterSeek.sameTrack(as: player), "QQ regenerated seek token still refers to the same song")
check(!afterSeek.sameItem(as: player), "A user seek during DAC wait invalidates the old item")
playerData["title"] = "Other song"
let otherSong = PlayerSnapshot(playerData)!
transitions.observe(otherSong, at: now.addingTimeInterval(2))
check(transitions.allowsHeadRestart(otherSong, cue: now.addingTimeInterval(2), now: now.addingTimeInterval(2.2)), "A confirmed fresh song transition allows replaying the head")
check(!transitions.allowsHeadRestart(otherSong, cue: now.addingTimeInterval(2), now: now.addingTimeInterval(2.01)), "Wait for metadata to settle before controlling the player")
var delayedMetadata = PlayerTransitionTracker()
delayedMetadata.observe(player, at: now.addingTimeInterval(-1))
delayedMetadata.observe(otherSong, at: now.addingTimeInterval(0.455))
check(!delayedMetadata.allowsHeadRestart(otherSong, cue: now, now: now.addingTimeInterval(0.520)),
      "QQ's first timer tick can precede metadata settling")
check(delayedMetadata.allowsHeadRestart(otherSong, cue: now, now: now.addingTimeInterval(0.555)),
      "The scheduled settled-metadata recheck can still preserve the song head")
check(!transitions.allowsHeadRestart(otherSong, cue: now.addingTimeInterval(3), now: now.addingTimeInterval(3.2)), "Later resume of that song cannot reuse its original transition")
check(!PlayerSnapshot(playerData)!.sameTrack(as: player), "A new song cannot receive an old seek/play command")
playerData["title"] = "A"; playerData["processIdentifier"] = 888
check(!PlayerSnapshot(playerData)!.sameTrack(as: player), "A different player PID cannot receive old commands")
check(PlayerSnapshot([:]) == nil, "Missing playback metadata is not guessed")
check(PreplayPolicy.exclusiveSource(pid: first.pid, clients: [first], outputID: 114), "One active controlled player can switch before playback")
check(!PreplayPolicy.exclusiveSource(pid: first.pid, clients: [first, second], outputID: 114), "Another active output must not be interrupted even in priority mode")
check(!PreplayPolicy.exclusiveSource(pid: first.pid, clients: [first, client(888, devices: [])], outputID: 114), "An unknown active route blocks preplay")
check(PreplayPolicy.exclusiveSource(pid: first.pid, clients: [first, otherDeviceClient], outputID: 114), "An unrelated device does not block preplay")
check(PreplayPolicy.exclusiveSource(pid: first.pid, clients: [first, client(888, running: false)], outputID: 114), "An idle app does not block preplay")
check(!PreplayPolicy.exclusiveSource(pid: first.pid, clients: [], outputID: 114), "No active source cannot authorize switching")
print("PASS: \(assertions) assertions for evidence, routing, preplay cues, DAC clock and playback identity")
