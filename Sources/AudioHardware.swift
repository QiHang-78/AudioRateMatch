import Foundation
import CoreAudio
import AppKit
import Darwin

struct AudioFailure: Error, CustomStringConvertible {
    let description: String
}

struct OutputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let rate: Double
    let ranges: [AudioValueRange]
    let physicalRates: [Double]
    func supports(_ rate: Double) -> Bool {
        ranges.contains { rate >= $0.mMinimum - 0.1 && rate <= $0.mMaximum + 0.1 }
    }
    var dictionary: [String: Any] {
        ["id": id, "uid": uid, "name": name, "nominalHz": rate,
         "physicalHz": physicalRates, "supportedHz": ranges.map { [$0.mMinimum, $0.mMaximum] }]
    }
}

enum Hardware {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var property = address(selector), result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw AudioFailure(description: "读取音频属性失败（\(status)）") }
        return result
    }
    static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as: T.Type) -> [T] {
        var property = address(selector, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: T.self), count: Int(size) / MemoryLayout<T>.stride))
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
    static func device(_ id: AudioObjectID) -> OutputDevice? {
        let streams: [AudioStreamID] = array(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, as: AudioStreamID.self)
        guard !streams.isEmpty, let rate: Double = try? scalar(id, kAudioDevicePropertyNominalSampleRate, initial: 0.0) else { return nil }
        let physical = streams.map { stream -> Double in
            (try? scalar(stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription()).mSampleRate) ?? 0
        }
        return OutputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID),
                            name: string(id, kAudioObjectPropertyName).trimmingCharacters(in: .whitespaces),
                            rate: rate, ranges: array(id, kAudioDevicePropertyAvailableNominalSampleRates, as: AudioValueRange.self), physicalRates: physical)
    }
    static func devices() -> [OutputDevice] {
        array(system, kAudioHardwarePropertyDevices, as: AudioObjectID.self).compactMap(device)
    }
    static func defaultOutput() -> OutputDevice? {
        guard let id: AudioObjectID = try? scalar(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)) else { return nil }
        return device(id)
    }
    static func setRate(_ rate: Double, on device: OutputDevice) throws {
        guard self.device(device.id)?.uid == device.uid else { throw AudioFailure(description: "输出设备已断开或改变") }
        let owner: Int32 = (try? scalar(device.id, kAudioDevicePropertyHogMode, initial: Int32(-1))) ?? -1
        guard owner <= 0 || owner == ProcessInfo.processInfo.processIdentifier else {
            throw AudioFailure(description: "设备被其他应用独占，保持当前设置")
        }
        guard rate.isFinite, rate > 0, device.supports(rate) else {
            throw AudioFailure(description: "\(device.name) 不支持 \(rateText(rate)) kHz；已保持原设置")
        }
        var property = address(kAudioDevicePropertyNominalSampleRate)
        var writable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device.id, &property, &writable) == noErr, writable.boolValue else {
            throw AudioFailure(description: "\(device.name) 的系统采样率不可修改")
        }
        var value = rate
        let status = AudioObjectSetPropertyData(device.id, &property, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
        guard status == noErr else { throw AudioFailure(description: "写入系统采样率失败（\(status)）") }
    }
    static func verified(_ device: OutputDevice, rate: Double) -> Bool {
        abs(device.rate - rate) < 0.1 && !device.physicalRates.isEmpty && device.physicalRates.allSatisfy { abs($0 - rate) < 0.1 }
    }
    static func clients() -> [AudioClient] {
        array(system, kAudioHardwarePropertyProcessObjectList, as: AudioObjectID.self).compactMap { object in
            let pid: Int32 = (try? scalar(object, kAudioProcessPropertyPID, initial: Int32(0))) ?? 0
            guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            let running: UInt32 = (try? scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            let app = NSRunningApplication(processIdentifier: pid)
            let bundle = string(object, kAudioProcessPropertyBundleID)
            var pathBytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = pathBytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            let path = count > 0 ? String(cString: pathBytes) : (app?.executableURL?.path ?? "")
            var info = proc_bsdinfo()
            let infoSize = MemoryLayout<proc_bsdinfo>.stride
            let size = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(infoSize)) }
            let born = size == infoSize ? Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000) : app?.launchDate
            let fallbackName = path.isEmpty ? "进程 \(pid)" : URL(fileURLWithPath: path).lastPathComponent
            return AudioClient(objectID: object, pid: pid, bundleID: bundle, path: path,
                               name: app?.localizedName ?? fallbackName, startedAt: born,
                               running: running != 0,
                               deviceIDs: array(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput, as: AudioObjectID.self))
        }
    }
}

func rateText(_ rate: Double) -> String {
    let khz = rate / 1000
    return khz == khz.rounded() ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
}
