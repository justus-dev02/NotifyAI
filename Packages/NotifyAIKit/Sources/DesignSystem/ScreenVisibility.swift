//
//  ScreenVisibility.swift
//  DesignSystem
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Calls `action` whenever the view starts or stops being visible to the user.
    ///
    /// A view counts as visible while it is on screen: it appeared, the app is not in the
    /// background (iOS) and its window is not minimized, hidden, fully covered, on another
    /// Space or on a sleeping display (macOS, `NSWindow.occlusionState`). Views that update
    /// several times per second use this to stop their updates while nobody can see them.
    public func onScreenVisibilityChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(ScreenVisibilityModifier(action: action))
    }
}

private struct ScreenVisibilityModifier: ViewModifier {
    let action: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var isAppeared = false
    @State private var isWindowVisible = true

    private var isVisible: Bool {
        isAppeared && scenePhase != .background && isWindowVisible
    }

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .background {
                WindowOcclusionObserver { isWindowVisible = $0 }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            #endif
            .onAppear { isAppeared = true }
            .onDisappear { isAppeared = false }
            .onChange(of: isVisible, initial: true) { _, visible in
                action(visible)
            }
    }
}

#if os(macOS)
/// Reports whether the hosting window is visible on screen.
private struct WindowOcclusionObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onChange: onChange)
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: (Bool) -> Void
        private var observers: [any NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Not used in Interface Builder")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                onChange(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            onChange(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }
    }
}
#endif
