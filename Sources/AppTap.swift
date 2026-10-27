import AudioToolbox
import CoreAudio
import Foundation

/// State shared with the real-time IO thread. Lives in manually allocated memory so the
/// IO callback touches no reference counting, locks or Objective-C.
/// Aligned 32/64-bit loads and stores are atomic on Apple silicon, which is all we rely on.
struct TapRenderState {
    var targetGain: Float
    var currentGain: Float
    var rampCoefficient: Float = 0.0007
    var leftChannel: Int32 = 0
    var rightChannel: Int32 = 1
    /// Multi-Output targets: every output stream gets the same stereo pair.
    var mirrorToAllStreams: Bool = false
    var callbackCount: UInt64 = 0
    var lastCallbackTime: UInt64 = 0
    var inputPeak: Float = 0
}

/// Routes one app's audio through a process tap so its volume can be changed:
/// tap (mutes the app's own output) -> private aggregate device -> IOProc (gain) -> output device.
final class AppTap {
    let processObjects: [AudioObjectID]
    /// Where the app's audio is played back: the device the app itself plays to.
    let outputDevice: AudioDeviceID
    let createdAt = Date()

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private let state: UnsafeMutablePointer<TapRenderState>

    private static let ioQueue = DispatchQueue(label: "mixer.tap.io", qos: .userInteractive)

    init(processObjects: [AudioObjectID], outputDevice: AudioDeviceID, gain: Float) {
        self.processObjects = processObjects
        self.outputDevice = outputDevice
        state = .allocate(capacity: 1)
        state.initialize(to: TapRenderState(targetGain: gain, currentGain: gain))
    }

    deinit {
        invalidate()
        state.deallocate()
    }

    var gain: Float {
        get { state.pointee.targetGain }
        set { state.pointee.targetGain = max(0, newValue) }
    }

    var callbackCount: UInt64 { state.pointee.callbackCount }

    /// Seconds since the IO callback last ran, or nil if it never ran.
    var secondsSinceLastCallback: Double? {
        let last = state.pointee.lastCallbackTime
        guard last != 0 else { return nil }
        return Double(mach_absolute_time() &- last) * Self.ticksToSeconds
    }

    /// Peak input level since the previous call.
    func takeInputPeak() -> Float {
        let peak = state.pointee.inputPeak
        state.pointee.inputPeak = 0
        return peak
    }

    func start() throws {
        let members = outputDevice.hardwareOutputUIDs
        guard let mainUID = members.first else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareBadDeviceError), operation: "output device has no UID")
        }
        let mirrored = members.count > 1

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "Mixer"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        // Bluetooth output and the tap share one clock; drift compensation there only adds crackle.
        let bluetooth = !mirrored && outputDevice.isBluetoothDevice
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixer",
            kAudioAggregateDeviceUIDKey: "mixer.aggregate." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: mirrored,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: members.enumerated().map { index, uid in
                [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: index > 0]
            },
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: !bluetooth,
            ]],
        ]

        var aggregate = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "AudioHardwareCreateAggregateDevice")
        aggregateID = aggregate

        var attempts = 0
        while !aggregate.isDeviceAlive && attempts < 40 {
            usleep(5_000)
            attempts += 1
        }

        let sampleRate = aggregate.nominalSampleRate ?? 48_000
        state.pointee.rampCoefficient = Float(1 - exp(-1 / (max(sampleRate, 8_000) * 0.03)))
        let stereo = mirrored ? (left: 0, right: 1) : outputDevice.preferredStereoChannels
        state.pointee.leftChannel = Int32(stereo.left)
        state.pointee.rightChannel = Int32(stereo.right)
        state.pointee.mirrorToAllStreams = mirrored

        let renderState = state
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, Self.ioQueue) { _, input, _, output, _ in
            TapRenderer.render(state: renderState, input: input, output: output)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        procID = proc

        disableHardwareInputs(aggregate: aggregate, proc: proc)

        try check(AudioDeviceStart(aggregate, proc), "AudioDeviceStart")
    }

    /// Tears everything down in the order Core Audio requires. Safe to call repeatedly.
    func invalidate() {
        if aggregateID.isValid, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    /// The aggregate exposes the output device's own inputs (a headset mic, for example) ahead of
    /// the tap stream. Marking them unused keeps them powered off: no mic prompt, no Bluetooth
    /// switch to call-quality mode.
    private func disableHardwareInputs(aggregate: AudioObjectID, proc: AudioDeviceIOProcID?) {
        guard let proc else { return }
        let inputCount = aggregate.streamCount(scope: kAudioObjectPropertyScopeInput)
        guard inputCount > 1 else { return }

        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let totalSize = headerSize + inputCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }

        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(inputCount), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for index in 0..<inputCount {
            let isTapStream: UInt32 = index == inputCount - 1 ? 1 : 0
            raw.storeBytes(of: isTapStream, toByteOffset: headerSize + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(totalSize), raw)
    }

    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
}

/// Real-time audio processing. No allocation, locks, logging or Objective-C in here.
enum TapRenderer {
    static func render(
        state: UnsafeMutablePointer<TapRenderState>,
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        state.pointee.callbackCount &+= 1
        state.pointee.lastCallbackTime = mach_absolute_time()

        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        // The tap is the aggregate's last input stream.
        var source: UnsafeMutablePointer<Float>?
        var sourceChannels = 0
        var sourceFrames = 0
        if inputs.count > 0 {
            let buffer = inputs[inputs.count - 1]
            if let data = buffer.mData, buffer.mNumberChannels > 0 {
                source = data.assumingMemoryBound(to: Float.self)
                sourceChannels = Int(buffer.mNumberChannels)
                sourceFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
            }
        }

        var totalOutputChannels = 0
        for buffer in outputs { totalOutputChannels += Int(buffer.mNumberChannels) }

        let target = state.pointee.targetGain
        let coefficient = state.pointee.rampCoefficient
        let startGain = state.pointee.currentGain
        let left = Int(state.pointee.leftChannel)
        let right = Int(state.pointee.rightChannel)
        let mirror = state.pointee.mirrorToAllStreams

        var channelBase = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            defer { channelBase += channels }
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            guard let source, channels > 0 else { continue }

            let out = data.assumingMemoryBound(to: Float.self)
            let frames = min(sourceFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            // One device: the stereo pair sits at its preferred channels across all streams.
            // Multi-Output: each stream belongs to a different device and gets its own copy.
            let leftIndex = mirror ? 0 : left - channelBase
            let rightIndex = mirror ? 1 : right - channelBase
            let hasLeft = leftIndex >= 0 && leftIndex < channels
            let hasRight = rightIndex >= 0 && rightIndex < channels
            let mono = mirror ? channels == 1 : totalOutputChannels == 1
            guard mono || hasLeft || hasRight else { continue }

            var gain = startGain
            for frame in 0..<frames {
                gain += (target - gain) * coefficient
                let l = source[frame * sourceChannels]
                let r = sourceChannels > 1 ? source[frame * sourceChannels + 1] : l
                if mono {
                    out[frame] = (l + r) * 0.5 * gain
                } else {
                    if hasLeft { out[frame * channels + leftIndex] = l * gain }
                    if hasRight { out[frame * channels + rightIndex] = r * gain }
                }
            }
        }

        // Advance the ramp by exactly one buffer, whatever the output layout was.
        var endGain = target + (startGain - target) * powf(1 - coefficient, Float(sourceFrames))
        if abs(endGain - target) < 0.0001 { endGain = target }
        state.pointee.currentGain = endGain

        if let source, sourceFrames > 0 {
            var peak = state.pointee.inputPeak
            for index in 0..<(sourceFrames * sourceChannels) {
                let sample = abs(source[index])
                if sample > peak { peak = sample }
            }
            state.pointee.inputPeak = peak
        }
    }
}
