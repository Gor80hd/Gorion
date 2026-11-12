import AppKit
import GorionDesign
import GorionKit
import SwiftUI

/// Окно — два отдельных стеклянных островка с прозрачным зазором, как во
/// Flutter-версии (shell.dart): слева серверы, справа планета. За зазоры
/// и шапку окно перетаскивается.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        GeometryReader { proxy in
            let sidebarWidth = min(
                GLayout.sidebarMaxWidth,
                max(GLayout.sidebarMinWidth, proxy.size.width * GLayout.sidebarFraction))
            ZStack {
                // Зазоры между островками и поля окна.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                HStack(spacing: GSpacing.islandGap) {
                    SidebarIsland()
                        .frame(width: sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .islandSurface(tint: GMaterial.sidebarTint)
                    MainIsland()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .islandSurface(tint: GMaterial.mainTint)
                }
                .padding(GSpacing.islandGap)
            }
            .ignoresSafeArea()
        }
        .background(TransparentWindow())
        .sheet(isPresented: $ui.showingAddSubscription) {
            AddSubscriptionSheet()
        }
        .onChange(of: model.snapshot.noticeId) {
            guard let notice = model.snapshot.notice, let text = Copy.announcement(notice) else { return }
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

/// Делает окно прозрачным и без системной тени: тень строилась бы по всему
/// окну и ложилась в зазор между островками тёмной каймой (как в
/// MainFlutterWindow.swift). У стекла островков своя тень.
///
/// Кнопки окна («светофор») переносятся внутрь шапки бокового островка —
/// на место, оставленное под них в SidebarIsland. Иначе они стоят в углу
/// окна и налезают на скругление островка.
private struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowHook() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowHook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        override func layout() {
            super.layout()
            configure()
        }

        private var observers: [NSObjectProtocol] = []

        private func configure() {
            guard let window else { return }
            if window.isOpaque { window.isOpaque = false }
            if window.backgroundColor != .clear { window.backgroundColor = .clear }
            if window.hasShadow {
                window.hasShadow = false
                window.invalidateShadow()
            }
            if observers.isEmpty { observe(window) }
            placeTrafficLights(in: window)
        }

        /// Система возвращает кнопки на место после смены размера и выхода
        /// из полноэкранного режима — ставим их заново.
        private func observe(_ window: NSWindow) {
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        self.placeTrafficLights(in: window)
                    }
                }
            }
        }

        private func placeTrafficLights(in window: NSWindow) {
            // В полноэкранном режиме кнопки живут в выезжающей панели.
            guard !window.styleMask.contains(.fullScreen),
                let close = window.standardWindowButton(.closeButton),
                let miniaturize = window.standardWindowButton(.miniaturizeButton),
                let zoom = window.standardWindowButton(.zoomButton),
                let container = close.superview?.superview
            else { return }
            let buttonHeight = close.frame.height
            // Центр кнопок — середина шапки островка; левый край — отступ шапки.
            let centerFromTop = GSpacing.islandGap + GLayout.sidebarHeaderHeight / 2
            let containerHeight = centerFromTop + buttonHeight / 2
            var frame = container.frame
            if frame.height != containerHeight || frame.minY != window.frame.height - containerHeight {
                frame.size.height = containerHeight
                frame.origin.y = window.frame.height - containerHeight
                container.frame = frame
            }
            let step = miniaturize.frame.minX - close.frame.minX
            let left = GSpacing.islandGap + GSpacing.md
            for (index, button) in [close, miniaturize, zoom].enumerated() {
                let origin = CGPoint(x: left + CGFloat(index) * step, y: 0)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}
