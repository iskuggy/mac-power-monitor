import AppKit
import SwiftUI

/// scenePhase 会受菜单栏场景影响；直接观察承载主界面的窗口是否仍在前台可见。
struct DashboardWindowObserver: NSViewRepresentable {
    let store: PowerStore

    func makeNSView(context: Context) -> DashboardActivityView {
        DashboardActivityView(store: store)
    }

    func updateNSView(_ nsView: DashboardActivityView, context: Context) {}

    static func dismantleNSView(_ nsView: DashboardActivityView, coordinator: ()) {
        nsView.stopObserving()
    }
}

@MainActor
final class DashboardActivityView: NSView {
    private weak var store: PowerStore?
    private let clientID = UUID()
    private weak var trackedWindow: NSWindow?
    private var isClosing = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(store: PowerStore) {
        self.store = store
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        trackedWindow = window
        isClosing = false
        guard let window else { return }

        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reportActivity() }
            })
        }
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification
                Task { @MainActor in
                    guard let self else { return }
                    if closing { self.isClosing = true }
                    self.reportActivity()
                }
            })
        }
        reportActivity()
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        trackedWindow = nil
        reportActivity()
    }

    private func reportActivity() {
        let active = !isClosing && NSApp.isActive && !NSApp.isHidden
            && trackedWindow?.isVisible == true
            && trackedWindow?.isMiniaturized == false
            && trackedWindow?.occlusionState.contains(.visible) == true
        let id = clientID
        // 延后一轮，避免在 SwiftUI 更新 representable 时同步修改可观察状态。
        Task { @MainActor [weak store] in
            store?.setDashboardActive(active, for: id)
        }
    }
}
