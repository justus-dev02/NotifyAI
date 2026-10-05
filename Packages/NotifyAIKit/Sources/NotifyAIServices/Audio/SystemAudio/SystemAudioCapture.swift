//
//  SystemAudioCapture.swift
//  NotifyAIServices
//

#if os(macOS)
import AudioCapture
import AVFoundation
import CoreAudio
import NotifyAICore
import OSLog

enum SystemAudioError: LocalizedError {
    case appNotRunning(String)
    case noMicrophone
    case unexpectedStreamLayout

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let name):
            String(localized: "„\(name)“ ist nicht geöffnet. Öffne die App oder wähle „Alle Apps“ als Quelle.", bundle: .module)
        case .noMicrophone:
            String(localized: "Es wurde kein Mikrofon gefunden.", bundle: .module)
        case .unexpectedStreamLayout:
            String(localized: "Das Audiogerät für den Systemton konnte nicht eingerichtet werden.", bundle: .module)
        }
    }
}

/// Records the audio other apps play, optionally together with the microphone, through a
/// Core Audio process tap (macOS 14.2+).
///
/// Setup:
/// 1. A private process tap captures either one app (including its helper processes) or
///    every app except NotifyAI, as a stereo mix. Playback is not affected.
/// 2. A private aggregate device combines the tap with a clock device: the microphone when
///    it is recorded too, otherwise the current output device. Microphone and tap then run
///    on one clock (the tap is drift-compensated), so both stay in sync for hours.
/// 3. An I/O block copies every cycle into the lock-free rings of an
///    `AggregateCaptureInput`; `AudioCaptureContext` converts, mixes and writes the audio on
///    its own queue.
///
/// The aggregate is rebuilt when the default microphone or output device changes, and the
/// tap when the tapped app starts or ends audio processes (e.g. Zoom joins a call). If a
/// rebuild fails, nothing is recorded any more: the failure is reported through
/// `AudioCaptureContext.reportInputFailure(_:)`, the recording controller pauses, and
/// resuming retries the rebuild (`restartIfStopped()`).
///
/// macOS asks for the "Systemaudio aufnehmen" permission when the device starts for the
/// first time. There is no public API to query it; a denied permission yields silence.
actor SystemAudioCapture {
    enum Target: Sendable {
        case allApps
        case app(bundleID: String, bundlePath: String?)
    }

    private let includesMicrophone: Bool
    private let target: Target
    private let capture: AudioCaptureContext
    private let ioQueue = DispatchQueue(label: "com.justus.NotifyAI.system-audio", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "com.justus.NotifyAI.system-audio.listeners", qos: .userInitiated)
    private let logger = Logger.audio

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tappedProcesses: Set<AudioObjectID> = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var clockDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var isRunning = false
    /// Whether the current outage was reported already; cleared when the aggregate runs again.
    private var hasReportedFailure = false

    init(includesMicrophone: Bool, target: Target, capture: AudioCaptureContext) {
        self.includesMicrophone = includesMicrophone
        self.target = target
        self.capture = capture
    }

    func start() throws {
        try createTap(processes: targetProcesses())
        do {
            try startAggregate()
        } catch {
            destroyTap()
            throw error
        }
        isRunning = true
        installListeners()
        logger.info("System audio capture started (microphone: \(self.includesMicrophone, privacy: .public))")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeListeners()
        stopAggregate()
        destroyTap()
        logger.info("System audio capture stopped")
    }

    // MARK: - Tap

    /// The process objects of the target app. Empty for all apps (the tap then excludes NotifyAI instead).
    private func targetProcesses() -> Set<AudioObjectID> {
        switch target {
        case .allApps:
            return []
        case .app(let bundleID, let bundlePath):
            let processes = AudioProcessMatcher.processes(
                ofAppWithBundleID: bundleID,
                bundlePath: bundlePath,
                in: CoreAudioObject.audioProcesses()
            )
            return Set(processes.map(\.objectID))
        }
    }

    private func createTap(processes: Set<AudioObjectID>) throws {
        let description: CATapDescription
        switch target {
        case .allApps:
            // NotifyAI's own playback (e.g. listening to an older note) stays out of the recording.
            let ownProcess = CoreAudioObject.processObject(forPID: getpid())
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        case .app:
            // An empty list is valid: the app has not used audio yet. The tap is rebuilt as
            // soon as its audio process appears.
            description = CATapDescription(stereoMixdownOfProcesses: processes.sorted())
        }
        description.name = "NotifyAI"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CoreAudioError(operation: String(localized: "Tap anlegen", bundle: .module), status: status) }
        tapID = tap
        tappedProcesses = processes
    }

    private func destroyTap() {
        guard tapID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            logger.error("Destroying the process tap failed: \(status, privacy: .public)")
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedProcesses = []
    }

    // MARK: - Aggregate device

    private var clockDirection: CoreAudioObject.Direction {
        includesMicrophone ? .input : .output
    }

    private func startAggregate() throws {
        let clockDevice = try CoreAudioObject.defaultDevice(clockDirection)
        let clockUID = try CoreAudioObject.uid(ofDevice: clockDevice)
        let tapUID = try CoreAudioObject.readString(kAudioTapPropertyUID, of: tapID)
        let clockInputStreams = try CoreAudioObject.streams(of: clockDevice, direction: .input).count
        if includesMicrophone, clockInputStreams == 0 {
            throw SystemAudioError.noMicrophone
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotifyAI Aufnahme",
            kAudioAggregateDeviceUIDKey: "com.justus.NotifyAI.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Start immediately, also while nothing plays: the timeline must keep running.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr else { throw CoreAudioError(operation: String(localized: "Aggregate-Gerät anlegen", bundle: .module), status: status) }

        var procID: AudioDeviceIOProcID?
        do {
            // One buffer per input stream: the clock device's streams first, then the tap.
            let streams = try CoreAudioObject.streams(of: aggregate, direction: .input)
            guard streams.count > clockInputStreams else { throw SystemAudioError.unexpectedStreamLayout }
            let layout = AggregateInputLayout(
                microphone: includesMicrophone
                    ? .init(bufferIndex: 0, streamFormat: try CoreAudioObject.virtualFormat(ofStream: streams[0]))
                    : nil,
                system: .init(bufferIndex: clockInputStreams, streamFormat: try CoreAudioObject.virtualFormat(ofStream: streams[clockInputStreams]))
            )
            let input = try capture.configure(layout)

            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, ioQueue, Self.makeIOBlock(for: input))
            guard status == noErr, let procID else {
                throw CoreAudioError(operation: String(localized: "Audio-Callback anlegen", bundle: .module), status: status)
            }
            let usedStreams: Set<Int> = includesMicrophone ? [0, clockInputStreams] : [clockInputStreams]
            restrictInputStreams(of: aggregate, to: usedStreams, streamCount: streams.count, procID: procID)
            status = AudioDeviceStart(aggregate, procID)
            guard status == noErr else { throw CoreAudioError(operation: String(localized: "Aufnahme starten", bundle: .module), status: status) }
        } catch {
            if let procID {
                AudioDeviceDestroyIOProcID(aggregate, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
            throw error
        }

        aggregateID = aggregate
        clockDeviceID = clockDevice
        ioProcID = procID
        hasReportedFailure = false
    }

    /// Turns off input streams the recording does not need. Without this, recording only
    /// system audio with AirPods as output would also start their microphone, which
    /// switches them to the low-quality headset profile and shows the microphone indicator.
    private func restrictInputStreams(of aggregate: AudioObjectID, to used: Set<Int>, streamCount: Int, procID: AudioDeviceIOProcID) {
        guard streamCount > used.count else { return }
        // AudioHardwareIOProcStreamUsage ends in a variable-length array of flags.
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 16
        let size = flagsOffset + MemoryLayout<UInt32>.stride * streamCount
        let usage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { usage.deallocate() }
        usage.storeBytes(
            of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self),
            toByteOffset: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mIOProc) ?? 0,
            as: UnsafeMutableRawPointer.self
        )
        usage.storeBytes(
            of: UInt32(streamCount),
            toByteOffset: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams) ?? 8,
            as: UInt32.self
        )
        for index in 0..<streamCount {
            usage.storeBytes(of: used.contains(index) ? 1 : 0, toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
        var address = CoreAudioObject.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), usage)
        if status != noErr {
            logger.error("Restricting the input streams failed: \(status, privacy: .public)")
        }
    }

    private func stopAggregate() {
        guard aggregateID != kAudioObjectUnknown else { return }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        // Let a cycle that is already queued finish before the device disappears.
        ioQueue.sync {}
        let status = AudioHardwareDestroyAggregateDevice(aggregateID)
        if status != noErr {
            logger.error("Destroying the aggregate device failed: \(status, privacy: .public)")
        }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        clockDeviceID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
    }

    /// Built in a nonisolated context: the block runs on the real-time I/O thread, never on
    /// the actor. It only copies into the input's lock-free rings.
    nonisolated private static func makeIOBlock(for input: AggregateCaptureInput) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in
            input.process(inputData)
        }
    }

    // MARK: - Changes

    private func installListeners() {
        addListener(includesMicrophone ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice) { capture in
            await capture.defaultDeviceChanged()
        }
        if case .app = target {
            addListener(kAudioHardwarePropertyProcessObjectList) { capture in
                await capture.processesChanged()
            }
        }
    }

    private func addListener(
        _ selector: AudioObjectPropertySelector,
        handler: @escaping @Sendable (SystemAudioCapture) async -> Void
    ) {
        var address = CoreAudioObject.address(selector)
        let block = Self.makeListenerBlock { [weak self] in
            guard let self else { return }
            Task { await handler(self) }
        }
        let status = AudioObjectAddPropertyListenerBlock(CoreAudioObject.system, &address, listenerQueue, block)
        if status == noErr {
            listeners.append((address, block))
        } else {
            logger.error("Adding a Core Audio listener failed: \(status, privacy: .public)")
        }
    }

    nonisolated private static func makeListenerBlock(_ action: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in action() }
    }

    private func removeListeners() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(CoreAudioObject.system, &address, listenerQueue, listener.block)
        }
        listeners.removeAll()
    }

    /// The microphone (or, with system audio only, the output device) changed: move the
    /// aggregate to the new device. The recording continues without a gap in the timeline.
    private func defaultDeviceChanged() {
        guard isRunning else { return }
        let device = try? CoreAudioObject.defaultDevice(clockDirection)
        // A failed rebuild left no aggregate; a new device gives it another chance.
        guard device != clockDeviceID || aggregateID == kAudioObjectUnknown else { return }
        logger.info("Default device changed, rebuilding the aggregate device")
        stopAggregate()
        do {
            try startAggregate()
        } catch {
            reportFailure(error, while: "Rebuilding the aggregate device")
        }
    }

    /// Rebuilds the aggregate device (and the tap, if needed) unless it is running, e.g.
    /// after the Mac slept or a rebuild failed. Called when a paused recording is resumed.
    /// - Throws: When the devices cannot be started; nothing is recorded then.
    func restartIfStopped() throws {
        guard isRunning else { return }
        if aggregateID != kAudioObjectUnknown, tapID != kAudioObjectUnknown,
           let running = try? CoreAudioObject.read(kAudioDevicePropertyDeviceIsRunning, of: aggregateID, initial: UInt32(0)),
           running != 0 {
            return
        }
        logger.info("The aggregate device is not running, rebuilding it")
        stopAggregate()
        do {
            if tapID == kAudioObjectUnknown {
                try createTap(processes: targetProcesses())
            }
            try startAggregate()
        } catch {
            logger.error("Restarting the aggregate device failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// The tapped app started or ended audio processes: tap the new set.
    private func processesChanged() {
        guard isRunning else { return }
        let processes = targetProcesses()
        guard processes != tappedProcesses || tapID == kAudioObjectUnknown || aggregateID == kAudioObjectUnknown else { return }
        logger.info("Audio processes of the tapped app changed (\(processes.count, privacy: .public)), rebuilding the tap")
        stopAggregate()
        destroyTap()
        do {
            try createTap(processes: processes)
            try startAggregate()
        } catch {
            reportFailure(error, while: "Rebuilding the process tap")
        }
    }

    /// A rebuild failed and nothing is recorded any more. The recording controller pauses
    /// and tells the user; resuming retries. A later device or process change retries too.
    /// Reported once per outage: listeners keep retrying, but the user is told only once.
    private func reportFailure(_ error: any Error, while operation: String) {
        logger.error("\(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        guard !hasReportedFailure else { return }
        hasReportedFailure = true
        capture.reportInputFailure(error.localizedDescription)
    }
}
#endif
