//
//  AudioEnvironmentMonitor.swift
//  NotifyAI
//

#if os(macOS)
import AppKit
import CoreAudio
import Observation
import OSLog

/// Keeps the app list and the loudspeaker hint of the source pickers up to date, driven by
/// events instead of polling.
///
/// - Apps: `NSWorkspace` launch and quit notifications, the Core Audio process list and each
///   audio process's "is playing" property (so an app that starts playing moves to the top).
/// - Output: the default output device and its data source (headphones plugged into the
///   built-in jack switch the data source, not the device).
///
/// Views subscribe while they are visible; without subscribers no listener is installed,
/// so the monitor costs nothing while no picker is on screen.
@MainActor
@Observable
final class AudioEnvironmentMonitor {
    private(set) var apps: [AudioApp] = []
    private(set) var isLoudspeaker = false

    private typealias Listener = (object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)

    @ObservationIgnored private var appSubscribers = 0
    @ObservationIgnored private var outputSubscribers = 0
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var appListeners: [Listener] = []
    @ObservationIgnored private var processListeners: [AudioObjectID: Listener] = [:]
    @ObservationIgnored private var outputListeners: [Listener] = []
    @ObservationIgnored private var dataSourceListener: Listener?
    @ObservationIgnored private var pendingAppRefresh: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger.audio

    // MARK: - Subscriptions

    func beginObservingApps() {
        appSubscribers += 1
        guard appSubscribers == 1 else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleAppRefresh() }
            }
        }
        if let listener = addListener(kAudioHardwarePropertyProcessObjectList, of: CoreAudioObject.system, action: { [weak self] in
            self?.scheduleAppRefresh()
        }) {
            appListeners = [listener]
        }
        refreshApps()
    }

    func endObservingApps() {
        guard appSubscribers > 0 else { return }
        appSubscribers -= 1
        guard appSubscribers == 0 else { return }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        appListeners.forEach(removeListener)
        appListeners = []
        processListeners.values.forEach(removeListener)
        processListeners = [:]
        pendingAppRefresh?.cancel()
        pendingAppRefresh = nil
    }

    func beginObservingOutput() {
        outputSubscribers += 1
        guard outputSubscribers == 1 else { return }
        if let listener = addListener(kAudioHardwarePropertyDefaultOutputDevice, of: CoreAudioObject.system, action: { [weak self] in
            self?.outputDeviceChanged()
        }) {
            outputListeners = [listener]
        }
        outputDeviceChanged()
    }

    func endObservingOutput() {
        guard outputSubscribers > 0 else { return }
        outputSubscribers -= 1
        guard outputSubscribers == 0 else { return }
        outputListeners.forEach(removeListener)
        outputListeners = []
        dataSourceListener.map(removeListener)
        dataSourceListener = nil
    }

    // MARK: - Apps

    /// Several events usually arrive together (an app launches several helper processes);
    /// they are coalesced into one refresh.
    private func scheduleAppRefresh() {
        guard pendingAppRefresh == nil else { return }
        pendingAppRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.pendingAppRefresh = nil
            self.refreshApps()
        }
    }

    private func refreshApps() {
        guard appSubscribers > 0 else { return }
        let updated = AudioAppCatalog.runningApps()
        if updated != apps {
            apps = updated
        }
        observePlayingState()
    }

    /// Listens to "is playing" of every current audio process and drops listeners of
    /// processes that are gone.
    private func observePlayingState() {
        let processes = Set((try? CoreAudioObject.readObjectIDs(kAudioHardwarePropertyProcessObjectList, of: CoreAudioObject.system)) ?? [])
        for (process, listener) in processListeners where !processes.contains(process) {
            removeListener(listener)
            processListeners[process] = nil
        }
        for process in processes where processListeners[process] == nil {
            processListeners[process] = addListener(kAudioProcessPropertyIsRunningOutput, of: process, action: { [weak self] in
                self?.scheduleAppRefresh()
            })
        }
    }

    // MARK: - Output

    private func outputDeviceChanged() {
        dataSourceListener.map(removeListener)
        dataSourceListener = nil
        if let device = try? CoreAudioObject.defaultDevice(.output) {
            dataSourceListener = addListener(kAudioDevicePropertyDataSource, of: device, scope: kAudioObjectPropertyScopeOutput, action: { [weak self] in
                self?.updateLoudspeaker()
            })
        }
        updateLoudspeaker()
    }

    private func updateLoudspeaker() {
        let value = CoreAudioObject.defaultOutputIsLoudspeaker()
        if value != isLoudspeaker {
            isLoudspeaker = value
        }
    }

    // MARK: - Core Audio listeners

    private func addListener(
        _ selector: AudioObjectPropertySelector,
        of object: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        action: @escaping @MainActor () -> Void
    ) -> Listener? {
        var address = CoreAudioObject.address(selector, scope: scope)
        let block = Self.makeListenerBlock(action)
        let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
        guard status == noErr else {
            // Properties some objects do not have (e.g. a data source) are expected to fail.
            logger.debug("Adding a Core Audio listener failed: \(status, privacy: .public)")
            return nil
        }
        return (object, address, block)
    }

    private func removeListener(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
    }

    /// Built in a nonisolated context; the listener runs on the main queue.
    private nonisolated static func makeListenerBlock(_ action: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in
            MainActor.assumeIsolated { action() }
        }
    }
}
#endif
