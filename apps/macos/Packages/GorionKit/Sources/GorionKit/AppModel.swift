import Foundation
import Observation

@_exported import GorionCoreBindings

/// Скорость трафика, байт/с.
public struct TrafficRate: Sendable, Equatable {
    public var up: UInt64
    public var down: UInt64

    public static let zero = TrafficRate(up: 0, down: 0)
}

/// Модель интерфейса поверх ядра на Rust. Вся логика — в ядре; здесь только
/// перенос снимков на главный поток и удобные команды для представлений.
@Observable
@MainActor
public final class AppModel {
    public private(set) var snapshot: CoreSnapshot
    public private(set) var traffic: TrafficRate = .zero
    /// Скорость за последние секунды для графика панели подключения.
    public private(set) var trafficHistory: [TrafficRate] = Array(repeating: .zero, count: AppModel.historyLength)

    @ObservationIgnored private let core: GorionCore
    @ObservationIgnored public let autoSelectTag: String
    @ObservationIgnored private var started = false
    /// Помощник для режима «Весь компьютер» внутри приложения.
    @ObservationIgnored private let helperURL: URL

    /// Точек на графике трафика — как в нативной панели Flutter-версии.
    public static let historyLength = 36

    public init(dataDirectory: URL, engineURL: URL, helperURL: URL) {
        self.helperURL = helperURL
        let bridge = ObserverBridge()
        core = GorionCore(dataDir: dataDirectory.path, enginePath: engineURL.path, observer: bridge)
        snapshot = core.snapshot()
        autoSelectTag = core.autoSelectTag()
        bridge.model = self
    }

    /// Каталог данных, общий с Flutter-версией (тот же bundle id).
    public static var defaultDataDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "app.gorion.client", directoryHint: .isDirectory)
            .appending(path: "gorion", directoryHint: .isDirectory)
    }

    // MARK: Приём событий

    fileprivate func apply(_ next: CoreSnapshot) {
        // Обратные вызовы идут с разных потоков: старые снимки отбрасываем.
        guard next.revision >= snapshot.revision else { return }
        snapshot = next
    }

    fileprivate func apply(traffic rate: TrafficRate) {
        traffic = rate
        trafficHistory = Array((trafficHistory + [rate]).suffix(Self.historyLength))
    }

    // MARK: Производные значения

    public var activeProfile: CoreProfile? {
        snapshot.profiles.first { $0.id == snapshot.activeProfileId }
    }

    public var activeServer: CoreServer? {
        guard let tag = snapshot.activeTag else { return nil }
        return snapshot.servers.first { $0.tag == tag }
    }

    public var isConnected: Bool { snapshot.stage == .connected }

    /// Подключение ждёт установки помощника (первый запуск или обновление).
    public var needsHelper: Bool {
        guard let code = snapshot.error?.code else { return false }
        return code == .tunHelperRequired || code == .helperOutdated
    }

    public var isTransitioning: Bool {
        snapshot.stage == .starting || snapshot.stage == .stopping
    }

    public func isSelected(_ server: CoreServer) -> Bool {
        !snapshot.autoSelected && snapshot.selectedTag == server.tag
    }

    // MARK: Команды

    public func start() {
        guard !started else { return }
        started = true
        run {
            await $0.bootstrap()
            // Как во Flutter-версии: пинг серверов при запуске.
            if $0.snapshot().activeProfileId != nil {
                await $0.measureDelays()
            }
        }
    }

    public func toggleConnection() {
        switch snapshot.stage {
        case .connected, .starting: disconnect()
        case .disconnected, .failed, .stopping: connect()
        }
    }

    public func connect() { run { await $0.connect() } }
    public func disconnect() { run { await $0.disconnect() } }
    public func addSubscription(_ url: String) {
        run {
            await $0.addSubscription(url: url)
            // Новые серверы сразу проверяются, чтобы рядом с ними были числа.
            if case .subscriptionAdded = $0.snapshot().notice {
                await $0.measureDelays()
            }
        }
    }
    public func chooseProfile(_ id: String) { run { await $0.chooseProfile(profileId: id) } }
    public func refreshProfile(_ id: String) { run { await $0.refreshProfile(profileId: id) } }
    public func removeProfile(_ id: String) { run { await $0.removeProfile(profileId: id) } }
    public func undoRemove() { run { await $0.undoRemove() } }
    public func rename(profile id: String, to name: String) {
        run { await $0.renameProfile(profileId: id, name: name) }
    }
    public func select(server tag: String) { run { await $0.selectServer(tag: tag) } }
    public func selectAuto() { select(server: autoSelectTag) }

    /// Включить автовыбор и сразу подключиться — одной последовательной
    /// задачей, чтобы подключение не опередило выбор.
    public func selectAutoAndConnect() {
        let tag = autoSelectTag
        run {
            await $0.selectServer(tag: tag)
            await $0.connect()
        }
    }
    public func measureDelays() { run { await $0.measureDelays() } }
    public func setMode(_ mode: ConnectionMode) { run { await $0.setMode(mode: mode) } }

    /// Ставит помощника (macOS спросит пароль) и подключает.
    /// `prompt` — текст окна с паролем.
    public func installHelper(prompt: String) {
        let path = helperURL.path
        run { await $0.installHelper(helperPath: path, prompt: prompt) }
    }
    public func dismissMessage() { core.dismissMessage() }
    public func logs() -> [String] { core.logs() }

    /// Выход из приложения: ядро останавливается, прокси возвращается.
    public func shutdown() async {
        await core.shutdown()
    }

    private func run(_ work: @escaping @Sendable (GorionCore) async -> Void) {
        let core = core
        Task.detached { await work(core) }
    }
}

/// Мост наблюдателя: ядро зовёт его с фоновых потоков.
private final class ObserverBridge: CoreObserver, @unchecked Sendable {
    // Пишется один раз в init модели до первых событий; читается из задач.
    nonisolated(unsafe) weak var model: AppModel?

    func onSnapshot(snapshot: CoreSnapshot) {
        Task { @MainActor [weak self] in self?.model?.apply(snapshot) }
    }

    func onTraffic(upBytesPerSecond: UInt64, downBytesPerSecond: UInt64) {
        let rate = TrafficRate(up: upBytesPerSecond, down: downBytesPerSecond)
        Task { @MainActor [weak self] in self?.model?.apply(traffic: rate) }
    }
}
