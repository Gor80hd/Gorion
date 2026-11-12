#if DEBUG
    import AppKit
    import GorionDesign
    import GorionKit

    /// Снимок окна для проверок без доступа к экрану (например, когда экран
    /// заблокирован): GORION_SNAPSHOT=/путь/к/файлу.png. Только в отладочной
    /// сборке. Системное стекло так не снимается: островки рисуются сплошными
    /// (IslandRendering.forceSolid), а при подключении стекло полосы
    /// подключения заливает снимок белым — для этого состояния нужен
    /// настоящий скриншот.
    @MainActor
    enum DebugSnapshot {
        static var path: String? { ProcessInfo.processInfo.environment["GORION_SNAPSHOT"] }

        static func scheduleIfRequested(model: AppModel) {
            guard let path else { return }
            // GORION_SNAPSHOT_CONNECT=1 — подключиться сразу, но только в
            // ручном режиме или в режиме «Весь компьютер» без помощника (тогда
            // покажется карточка установки): системный прокси и TUN не
            // трогаются.
            if ProcessInfo.processInfo.environment["GORION_SNAPSHOT_CONNECT"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    let safe = model.snapshot.mode == .manual
                        || (model.snapshot.mode == .wholeComputer && model.snapshot.helper == .notInstalled)
                    if safe, !model.isConnected { model.toggleConnection() }
                }
            }
            Task { @MainActor in
                // Первый снимок — после загрузки карты и раскрытия планеты,
                // дальше файл обновляется, чтобы видеть результат действий.
                try? await Task.sleep(for: .seconds(6))
                while true {
                    capture(to: path)
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }

        private static func capture(to path: String) {
            guard let view = NSApp.windows.first(where: { $0.title == "Gorion" })?.contentView?.superview,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
#endif
