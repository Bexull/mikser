import AppKit
import AudioToolbox
import CoreAudio

// MARK: - Errors

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String { "\(operation): OSStatus \(status)" }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
}

// MARK: - Property access

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != AudioObjectID.unknown }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default value: T
    ) -> T? {
        var address = Self.address(selector, scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? result : nil
    }

    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = Self.address(selector, scope)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    func readObjects(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = Self.address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    func has(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = Self.address(selector, scope)
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = Self.address(selector, scope)
        guard AudioObjectHasProperty(self, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(self, &address, &settable) == noErr && settable.boolValue
    }

    @discardableResult
    func write<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        value: T
    ) -> OSStatus {
        var address = Self.address(selector, scope)
        var data = value
        return withUnsafePointer(to: &data) { pointer in
            AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer)
        }
    }
}

// MARK: - Devices

extension AudioObjectID {
    static func defaultOutputDevice() -> AudioDeviceID? {
        guard let device = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID.unknown),
              device.isValid else { return nil }
        return device
    }

    var deviceUID: String? { readString(kAudioDevicePropertyDeviceUID) }
    var deviceName: String? { readString(kAudioObjectPropertyName) }
    var transportType: UInt32 { read(kAudioDevicePropertyTransportType, default: UInt32(0)) ?? 0 }

    var isBluetoothDevice: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isDeviceAlive: Bool { (read(kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)) ?? 0) != 0 }

    /// The hardware devices behind an output: itself, or the members of an aggregate /
    /// Multi-Output device (aggregates can't be nested inside our own aggregate).
    var hardwareOutputUIDs: [String] {
        if transportType == kAudioDeviceTransportTypeAggregate {
            let members = readObjects(kAudioAggregateDevicePropertyActiveSubDeviceList)
                .filter { $0.streamCount(scope: kAudioObjectPropertyScopeOutput) > 0 }
                .compactMap(\.deviceUID)
            if !members.isEmpty { return members }
        }
        return deviceUID.map { [$0] } ?? []
    }

    var nominalSampleRate: Double? { read(kAudioDevicePropertyNominalSampleRate, default: Float64(0)) }

    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        readObjects(kAudioDevicePropertyStreams, scope: scope).count
    }

    /// Zero-based indices of the channels the device prefers for stereo playback.
    var preferredStereoChannels: (left: Int, right: Int) {
        guard let pair = read(
            kAudioDevicePropertyPreferredChannelsForStereo,
            scope: kAudioObjectPropertyScopeOutput,
            default: (UInt32(1), UInt32(2))
        ), pair.0 >= 1, pair.1 >= 1 else { return (0, 1) }
        return (Int(pair.0) - 1, Int(pair.1) - 1)
    }

    /// SF Symbol that matches the kind of output device.
    var outputSymbol: String {
        let name = (deviceName ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeBuiltIn: return name.contains("headphone") ? "headphones" : "laptopcomputer"
        default: return "hifispeaker"
        }
    }
}

// MARK: - Processes

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let isRunningOutput: Bool
    /// Devices the process is playing to right now (empty while it is silent).
    let outputDevices: [AudioDeviceID]

    static func all() -> [AudioProcess] {
        AudioObjectID.system.readObjects(kAudioHardwarePropertyProcessObjectList).compactMap { object in
            guard let pid = object.read(kAudioProcessPropertyPID, default: pid_t(0)), pid > 0 else { return nil }
            let running = (object.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) ?? 0) != 0
            let devices = running ? object.readObjects(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput) : []
            return AudioProcess(objectID: object, pid: pid, isRunningOutput: running, outputDevices: devices)
        }
    }
}

enum ProcessOwner {
    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    private static let responsibility: ResponsibilityFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    /// The app a process plays sound for. Apps often play through background helpers:
    /// Teams calls come from "Microsoft Teams ModuleHost", Safari from WebKit XPC services,
    /// Chrome and Discord from helper apps. macOS records which app is responsible for
    /// each of them; failing that, the nearest app up the parent chain is used.
    static func app(for pid: pid_t, appsByPID: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        let own = appsByPID[pid]
        if let own, own.activationPolicy == .regular, isAppBundle(own) { return own }

        if let responsible = responsibility?(pid), responsible > 0, responsible != pid,
           let app = appsByPID[responsible], isUserFacing(app) {
            return app
        }

        var current = pid
        for _ in 0..<16 {
            guard let parent = parentPID(of: current), parent > 1, parent != current else { break }
            if let app = appsByPID[parent], isUserFacing(app) { return app }
            current = parent
        }

        // A menu bar app playing sound on its own behalf.
        if let own, isUserFacing(own) { return own }
        return nil
    }

    private static func isAppBundle(_ app: NSRunningApplication) -> Bool {
        app.bundleURL?.pathExtension == "app"
    }

    private static func isUserFacing(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy != .prohibited && isAppBundle(app)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

// MARK: - Listeners

/// Keeps a Core Audio property listener alive; removes it on deinit.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        handler: @escaping () -> Void
    ) {
        self.object = object
        self.address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}
