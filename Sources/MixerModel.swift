import AppKit
import AudioToolbox
import CoreAudio
import Observation
import ServiceManagement

struct AppItem: Identifiable, Equatable {
    let id: String
    var name: String
    var icon: NSImage
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    var volume: Double
    var isMuted: Bool
    /// The device the app was last heard playing to (apps may pick their own, like Teams does).
    var playbackDevice: AudioDeviceID?

    /// Anything but "full volume, not muted" needs a tap.
    var isAdjusted: Bool { isMuted || volume < MixerModel.unity }

    /// Slider position -> amplitude. The square gives a natural-feeling taper.
    var gain: Float { isMuted ? 0 : Float(volume * volume) }

    static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.processObjects == rhs.processObjects
            && lhs.isPlaying == rhs.isPlaying && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
            && lhs.playbackDevice == rhs.playbackDevice
    }
}

struct OutputInfo: Equatable {
    var name: String
    var symbol: String
    var hasVolume: Bool
    var canMute: Bool

    static let none = OutputInfo(name: "Нет вывода звука", symbol: "speaker.slash", hasVolume: false, canMute: false)
}

/// Everything the panel shows, plus the engine that keeps one tap per adjusted app.
/// Used from the main thread only.
@Observable
final class MixerModel {
    static let unity = 0.995

    enum Access { case granted, denied, notDetermined }

    private(set) var apps: [AppItem] = []
    private(set) var access: Access = .notDetermined
    private(set) var output = OutputInfo.none
    private(set) var masterVolume: Double = 0
    private(set) var masterMuted = false
    private(set) var launchAtLogin = false

    var hasAdjustments: Bool { apps.contains { $0.isAdjusted } }

    @ObservationIgnored var log: ((String) -> Void)?
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private var events: [String] = []

    @ObservationIgnored private var taps: [String: AppTap] = [:]
    @ObservationIgnored private var pendingRemovals: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var lastFailure: [String: Date] = [:]
    @ObservationIgnored private var heard: Set<String> = []
    @ObservationIgnored private var outputDevice = AudioDeviceID.unknown
    @ObservationIgnored private var outputUID = ""
    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var deviceListeners: [PropertyListener] = []
    @ObservationIgnored private var processListeners: [AudioObjectID: [PropertyListener]] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var rebuildWork: DispatchWorkItem?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let defaults = UserDefaults.standard

    // MARK: - Lifecycle

    func start() {
        updateAccess()
        if access == .notDetermined {
            AudioCaptureAccess.request { [weak self] _ in
                self?.updateAccess()
                self?.refresh()
            }
        }

        systemListeners = [
            PropertyListener(.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.scheduleRefresh() },
            PropertyListener(.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.updateOutputDevice() },
        ].compactMap { $0 }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRebuild(after: 2)
        })

        updateLaunchAtLogin()
        updateOutputDevice()
        refresh()

        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.periodicCheck() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func shutdown() {
        timer?.invalidate()
        for key in Array(taps.keys) { dropTap(key) }
    }

    /// Called when the panel opens: pick up anything listeners might have missed.
    func panelWillOpen() {
        guard !isPreview else { return }
        updateAccess()
        updateLaunchAtLogin()
        readMaster()
        refresh()
    }

    // MARK: - Permission

    private func updateAccess() {
        let status: Access
        switch AudioCaptureAccess.status {
        case .granted: status = .granted
        case .denied: status = .denied
        case .notDetermined: status = .notDetermined
        }
        guard status != access else { return }
        access = status
        note("access: \(status)")
        syncTaps()
    }

    func requestAccess() {
        if access == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            AudioCaptureAccess.request { [weak self] _ in
                self?.updateAccess()
                self?.refresh()
            }
        }
    }

    // MARK: - Apps

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        let processes = AudioProcess.all()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            appsByPID[app.processIdentifier] = app
        }

        struct Group {
            let owner: NSRunningApplication
            var objects: [AudioObjectID] = []
            var playing = false
            var devices: [AudioDeviceID] = []

            /// The device most of the app's sound goes to right now.
            var device: AudioDeviceID? {
                let counts = Dictionary(devices.map { ($0, 1) }, uniquingKeysWith: +)
                return counts.max { $0.value < $1.value }?.key
            }
        }
        var groups: [String: Group] = [:]
        for process in processes where process.pid != ownPID {
            guard let owner = ProcessOwner.app(for: process.pid, appsByPID: appsByPID),
                  owner.processIdentifier != ownPID else { continue }
            let key = owner.bundleIdentifier ?? "pid.\(owner.processIdentifier)"
            var group = groups[key] ?? Group(owner: owner)
            group.objects.append(process.objectID)
            group.playing = group.playing || process.isRunningOutput
            group.devices += process.outputDevices
            groups[key] = group
        }
        updateProcessListeners(processes.map(\.objectID))

        for (key, group) in groups where group.playing {
            heard.insert(key)
        }

        // Known apps keep their place; apps that quit disappear.
        var updated: [AppItem] = []
        for var item in apps {
            guard let group = groups.removeValue(forKey: item.id) else { continue }
            item.processObjects = group.objects.sorted()
            item.isPlaying = group.playing
            item.playbackDevice = group.device ?? item.playbackDevice
            updated.append(item)
        }

        // Newcomers: anything that has made sound, or that the user adjusted before.
        let newcomers = groups
            .filter { key, group in group.playing || heard.contains(key) || isCustomized(key) }
            .sorted { lhs, rhs in
                let left = lhs.value.owner.localizedName ?? lhs.key
                let right = rhs.value.owner.localizedName ?? rhs.key
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
        for (key, group) in newcomers {
            updated.append(AppItem(
                id: key,
                name: group.owner.localizedName ?? key,
                icon: group.owner.icon ?? NSWorkspace.shared.icon(for: .application),
                processObjects: group.objects.sorted(),
                isPlaying: group.playing,
                volume: savedVolume(key),
                isMuted: savedMuted(key),
                playbackDevice: group.device
            ))
        }

        if updated != apps {
            apps = updated
        }
        syncTaps()
    }

    func setVolume(_ volume: Double, for id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        let value = min(max(volume, 0), 1)
        guard apps[index].volume != value else { return }
        apps[index].volume = value
        save(apps[index])
        syncTap(for: apps[index])
    }

    func toggleMute(for id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[index].isMuted.toggle()
        if !apps[index].isMuted && apps[index].volume < 0.01 {
            apps[index].volume = 0.5
        }
        save(apps[index])
        syncTap(for: apps[index])
    }

    func reset(_ id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[index].volume = 1
        apps[index].isMuted = false
        save(apps[index])
        syncTap(for: apps[index])
    }

    func resetAll() {
        for item in apps { reset(item.id) }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("volume.") || key.hasPrefix("muted.") {
            defaults.removeObject(forKey: key)
        }
    }

    private func updateProcessListeners(_ objects: [AudioObjectID]) {
        let current = Set(objects)
        for object in processListeners.keys.filter({ !current.contains($0) }) {
            processListeners[object] = nil
        }
        for object in current where processListeners[object] == nil {
            // Starting/stopping sound, and switching to another output device.
            processListeners[object] = [
                PropertyListener(object, kAudioProcessPropertyIsRunningOutput) { [weak self] in self?.scheduleRefresh() },
                PropertyListener(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                    self?.scheduleRefresh()
                },
            ].compactMap { $0 }
        }
    }

    // MARK: - Persistence

    private func savedVolume(_ key: String) -> Double {
        (defaults.object(forKey: "volume." + key) as? Double) ?? 1
    }

    private func savedMuted(_ key: String) -> Bool {
        defaults.bool(forKey: "muted." + key)
    }

    private func isCustomized(_ key: String) -> Bool {
        savedVolume(key) < Self.unity || savedMuted(key)
    }

    private func save(_ item: AppItem) {
        if item.volume < Self.unity {
            defaults.set(item.volume, forKey: "volume." + item.id)
        } else {
            defaults.removeObject(forKey: "volume." + item.id)
        }
        if item.isMuted {
            defaults.set(true, forKey: "muted." + item.id)
        } else {
            defaults.removeObject(forKey: "muted." + item.id)
        }
    }

    // MARK: - Taps

    private func syncTaps() {
        let ids = Set(apps.map(\.id))
        for key in Array(taps.keys) where !ids.contains(key) {
            dropTap(key)
        }
        for item in apps {
            syncTap(for: item)
        }
    }

    /// Where an app's tapped audio is played back: the device the app itself plays to,
    /// otherwise the system output.
    private func playbackDevice(for item: AppItem) -> AudioDeviceID {
        if let device = item.playbackDevice, device.isValid, device.isDeviceAlive { return device }
        return outputDevice
    }

    private func syncTap(for item: AppItem) {
        let device = playbackDevice(for: item)
        guard access == .granted, device.isValid, !item.processObjects.isEmpty else {
            dropTap(item.id)
            return
        }

        if item.isAdjusted {
            pendingRemovals.removeValue(forKey: item.id)?.cancel()
            if let tap = taps[item.id], tap.processObjects == item.processObjects, tap.outputDevice == device {
                tap.gain = item.gain
                return
            }
            if let failed = lastFailure[item.id], Date().timeIntervalSince(failed) < 5 { return }

            dropTap(item.id)
            let startedAt = Date()
            let tap = AppTap(processObjects: item.processObjects, outputDevice: device, gain: item.gain)
            do {
                try tap.start()
                taps[item.id] = tap
                lastFailure[item.id] = nil
                let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                note("tap on: \(item.id) objects=\(item.processObjects) device=\(device.deviceName ?? "\(device)") gain=\(item.gain) in \(milliseconds) ms")
            } catch {
                tap.invalidate()
                lastFailure[item.id] = Date()
                note("tap failed: \(item.id) \(error)")
            }
        } else if let tap = taps[item.id] {
            // Back at 100%: play through at unity for a moment, then hand the app back to the system.
            tap.gain = item.gain
            guard pendingRemovals[item.id] == nil else { return }
            let id = item.id
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingRemovals[id] = nil
                if self.apps.first(where: { $0.id == id })?.isAdjusted == true { return }
                self.dropTap(id)
            }
            pendingRemovals[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func dropTap(_ key: String) {
        pendingRemovals.removeValue(forKey: key)?.cancel()
        if let tap = taps.removeValue(forKey: key) {
            tap.invalidate()
            note("tap off: \(key)")
        }
    }

    private func scheduleRebuild(after delay: TimeInterval) {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildTaps() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rebuildTaps() {
        for key in Array(taps.keys) { dropTap(key) }
        lastFailure.removeAll()
        syncTaps()
    }

    private func periodicCheck() {
        if access != .granted { updateAccess() }
        refresh()

        // A tap whose IO stopped while its app keeps playing gets rebuilt.
        for item in apps where item.isPlaying {
            guard let tap = taps[item.id], Date().timeIntervalSince(tap.createdAt) > 5 else { continue }
            let idle = tap.secondsSinceLastCallback ?? .infinity
            if idle > 3 {
                note("tap stalled: \(item.id) idle=\(idle)")
                dropTap(item.id)
                syncTap(for: item)
            }
        }
    }

    // MARK: - Output device

    private func updateOutputDevice() {
        let device = AudioObjectID.defaultOutputDevice() ?? .unknown
        let uid = device.isValid ? (device.deviceUID ?? "") : ""
        let changed = device != outputDevice || uid != outputUID
        outputDevice = device
        outputUID = uid

        if changed {
            deviceListeners = device.isValid ? [
                PropertyListener(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                    self?.readMaster()
                },
                PropertyListener(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                    self?.readMaster()
                },
                PropertyListener(device, kAudioDevicePropertyNominalSampleRate) { [weak self] in
                    self?.scheduleRebuild(after: 0.3)
                },
            ].compactMap { $0 } : []
        }

        let info = device.isValid ? OutputInfo(
            name: device.deviceName ?? "Вывод звука",
            symbol: device.outputSymbol,
            hasVolume: device.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput),
            canMute: device.isSettable(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        ) : OutputInfo.none
        if info != output { output = info }
        readMaster()

        if changed {
            note("output: \(info.name) \(uid)")
            // Silent apps most likely follow the system output; playing ones report their own.
            for index in apps.indices where !apps[index].isPlaying {
                apps[index].playbackDevice = nil
            }
            rebuildTaps()
        }
    }

    private func readMaster() {
        guard outputDevice.isValid else { return }
        if let volume = outputDevice.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, default: Float32(0)) {
            let value = Double(volume)
            if abs(value - masterVolume) > 0.0005 { masterVolume = value }
        }
        let muted = (outputDevice.read(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, default: UInt32(0)) ?? 0) != 0
        if muted != masterMuted { masterMuted = muted }
    }

    func setMasterVolume(_ value: Double) {
        guard outputDevice.isValid, output.hasVolume else { return }
        let volume = min(max(value, 0), 1)
        masterVolume = volume
        outputDevice.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, value: Float32(volume))
        if masterMuted && volume > 0 { setMasterMuted(false) }
    }

    func toggleMasterMute() {
        setMasterMuted(!masterMuted)
    }

    private func setMasterMuted(_ muted: Bool) {
        guard outputDevice.isValid, output.canMute else { return }
        outputDevice.write(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(muted ? 1 : 0))
        masterMuted = muted
    }

    // MARK: - Launch at login

    private func updateLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            note("login item: \(error)")
        }
        updateLaunchAtLogin()
    }

    // MARK: - Diagnostics

    /// Fills the panel with sample rows for layout snapshots; never touches audio.
    func loadPreview(_ items: [AppItem], master: Double, output: OutputInfo) {
        isPreview = true
        access = .granted
        apps = items
        masterVolume = master
        self.output = output
    }

    /// Remembers engine events (the last 100) for `writeStateDump()`.
    private func note(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        events.append("\(stamp) \(message)")
        if events.count > 100 { events.removeFirst(events.count - 100) }
        log?(message)
    }

    func diagnostics() -> String {
        var lines = ["access=\(access) output=\(output.name) master=\(String(format: "%.2f", masterVolume)) muted=\(masterMuted)"]
        for item in apps {
            let device = item.playbackDevice.flatMap(\.deviceName) ?? "-"
            var line = "  \(item.id) playing=\(item.isPlaying) volume=\(String(format: "%.2f", item.volume)) muted=\(item.isMuted) objects=\(item.processObjects) device=\(device)"
            if let tap = taps[item.id] {
                let idle = tap.secondsSinceLastCallback.map { String(format: "%.1fs", $0) } ?? "never"
                line += " tap[device=\(tap.outputDevice.deviceName ?? "?") callbacks=\(tap.callbackCount) lastIO=\(idle) peak=\(String(format: "%.4f", tap.takeInputPeak())) gain=\(tap.gain)]"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// `kill -USR1 <pid>` writes the engine state and recent events to ~/Library/Logs/Mixer/state.txt.
    func writeStateDump(extra: String = "") {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mixer")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = diagnostics() + "\n" + extra + "\n\nevents:\n" + events.joined(separator: "\n") + "\n"
        try? text.write(to: directory.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    }
}
