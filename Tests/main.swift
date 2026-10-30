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
print("PASS: \(assertions) assertions for process isolation, routing, playback evidence, selection and switch stability")
