//
//  CoreAudioObject.swift
//  NotifyAI
//

#if os(macOS)
import CoreAudio
import Darwin
import Foundation

/// A failed Core Audio call.
struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        String(localized: "Systemton konnte nicht aufgenommen werden (\(operation), Fehler \(status)).")
    }
}

/// Typed access to Core Audio object properties.
enum CoreAudioObject {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    enum Direction {
        case input
        case output
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size value property (numbers, IDs, `AudioStreamBasicDescription`).
    static func read<Value: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        of object: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: Value
    ) throws -> Value {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<Value>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw CoreAudioError(operation: fourCharacterCode(selector), status: status) }
        return value
    }

    static func readObjectIDs(
        _ selector: AudioObjectPropertySelector,
        of object: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(operation: fourCharacterCode(selector), status: status) }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects)
        guard status == noErr else { throw CoreAudioError(operation: fourCharacterCode(selector), status: status) }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func readString(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { throw CoreAudioError(operation: fourCharacterCode(selector), status: status) }
        return value.takeRetainedValue() as String
    }

    // MARK: Devices

    static func defaultDevice(_ direction: Direction) throws -> AudioObjectID {
        let selector = direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        let device = try read(selector, of: system, initial: AudioObjectID(kAudioObjectUnknown))
        guard device != kAudioObjectUnknown else {
            throw CoreAudioError(operation: direction == .input ? String(localized: "Mikrofon") : String(localized: "Ausgabegerät"), status: kAudioHardwareBadDeviceError)
        }
        return device
    }

    static func uid(ofDevice device: AudioObjectID) throws -> String {
        try readString(kAudioDevicePropertyDeviceUID, of: device)
    }

    static func streams(of device: AudioObjectID, direction: Direction) throws -> [AudioObjectID] {
        let scope = direction == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return try readObjectIDs(kAudioDevicePropertyStreams, of: device, scope: scope)
    }

    static func virtualFormat(ofStream stream: AudioObjectID) throws -> AudioStreamBasicDescription {
        try read(kAudioStreamPropertyVirtualFormat, of: stream, initial: AudioStreamBasicDescription())
    }

    /// Whether the current output is a loudspeaker (built-in speakers, display, AirPlay).
    /// Recording the microphone next to a loudspeaker also captures the other participants
    /// a second time, slightly delayed.
    static func defaultOutputIsLoudspeaker() -> Bool {
        guard let device = try? defaultDevice(.output),
              let transport = try? read(kAudioDevicePropertyTransportType, of: device, initial: UInt32(0))
        else { return false }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // Built-in output is either the speakers ('ispk') or the headphone jack ('hdpn').
            let source = try? read(kAudioDevicePropertyDataSource, of: device, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0))
            return source != fourCharacterValue("hdpn")
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return true
        default:
            return false
        }
    }

    // MARK: Processes

    /// The Core Audio process object of `pid`, if the process has used audio.
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func audioProcesses() -> [AudioProcessInfo] {
        let objects = (try? readObjectIDs(kAudioHardwarePropertyProcessObjectList, of: system)) ?? []
        return objects.compactMap { object in
            guard let pid = try? read(kAudioProcessPropertyPID, of: object, initial: pid_t(0)), pid > 0 else { return nil }
            let bundleID = (try? readString(kAudioProcessPropertyBundleID, of: object)).flatMap { $0.isEmpty ? nil : $0 }
            let isPlaying = (try? read(kAudioProcessPropertyIsRunningOutput, of: object, initial: UInt32(0))) ?? 0
            return AudioProcessInfo(
                objectID: object,
                pid: pid,
                bundleID: bundleID,
                executablePath: executablePath(of: pid),
                isPlayingAudio: isPlaying != 0
            )
        }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Four-character codes

    static func fourCharacterValue(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func fourCharacterCode(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        let text = String(decoding: bytes, as: UTF8.self)
        return bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) ? text : String(value)
    }
}
#endif
