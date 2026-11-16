import GorionDesign
import GorionKit

/// Все тексты интерфейса. Ядро отдаёт коды — слова подбираются здесь
/// (DESIGN.md → 8: что случилось, что делать, кнопка; без жаргона).
enum Copy {
    // MARK: Состояние

    static func stage(_ stage: ConnectionStage) -> String {
        switch stage {
        case .disconnected: "Не подключено"
        case .starting: "Подключаемся…"
        case .connected: "Подключено"
        case .stopping: "Отключаемся…"
        case .failed: "Не подключено"
        }
    }

    static func connectButton(_ stage: ConnectionStage) -> String {
        switch stage {
        case .disconnected, .failed: "Подключить"
        case .starting: "Отменить"
        case .connected: "Отключить"
        case .stopping: "Отключаемся…"
        }
    }

    // MARK: Режимы

    static let modeMenu = "Режим"
    static let modes: [ConnectionMode] = [.wholeComputer, .systemProxy, .manual]

    static func modeTitle(_ mode: ConnectionMode) -> String {
        switch mode {
        case .manual: "Вручную"
        case .systemProxy: "Только системный прокси"
        case .wholeComputer: "Весь компьютер"
        }
    }

    static func modeExplanation(_ mode: ConnectionMode, port: UInt16?) -> String {
        switch mode {
        case .manual:
            if let port {
                "Прокси открыт на 127.0.0.1:\(port) — укажите его в нужной программе."
            } else {
                "Gorion откроет локальный прокси, а программы вы настроите сами."
            }
        case .systemProxy: "Через VPN идут браузеры и программы, которые используют системный прокси."
        case .wholeComputer: "Весь трафик компьютера идёт через VPN."
        }
    }

    // MARK: Серверы

    static let autoTitle = "Автовыбор"
    static let autoSubtitle = "Gorion сам найдёт рабочий сервер"
    static let serversTitle = "Серверы"
    static let searchPrompt = "Поиск"
    static let nothingFound = "Ничего не найдено"
    static let measure = "Проверить серверы"
    static let measuring = "Проверяем…"

    static func delay(_ ms: Int64?) -> String {
        guard let ms else { return "—" }
        return ms > 0 ? "\(ms)\u{00A0}мс" : "нет ответа"
    }

    static func delayAccessibility(_ ms: Int64?) -> String {
        guard let ms else { return "задержка не измерена" }
        return ms > 0 ? "задержка \(ms) миллисекунд" : "сервер не ответил"
    }

    static func serverCount(_ count: UInt32) -> String {
        "\(count)\u{00A0}\(plural(Int(count), "сервер", "сервера", "серверов"))"
    }

    // MARK: Подписки

    static let addSubscription = "Добавить подписку"
    static let addSubscriptionHint = "Вставьте ссылку, которую дал провайдер VPN."
    static let addSubscriptionPlaceholder = "https://…"
    static let add = "Добавить"
    static let adding = "Добавляем…"
    static let cancel = "Отмена"
    static let refresh = "Обновить подписку"
    static let remove = "Удалить подписку"
    static let undo = "Вернуть"
    static let subscriptions = "Подписки"
    static let emptyTitle = "Подписок пока нет"
    static let emptyMessage = "Добавьте ссылку на подписку — и можно подключаться."
    static let clipboardSuggestion = "Ссылка из буфера обмена"

    // MARK: Трафик

    static func rate(_ bytesPerSecond: UInt64) -> String {
        "\(bytes(bytesPerSecond))/с"
    }

    static func bytes(_ value: UInt64) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var size = Double(value)
        var unit = 0
        while size >= 1024 && unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        let digits = unit >= 2 ? 1 : 0
        let number = size.formatted(.number.precision(.fractionLength(digits)).locale(.init(identifier: "ru_RU")))
        return "\(number)\u{00A0}\(units[unit])"
    }

    static func elapsed(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    // MARK: Уведомления

    struct Toast: Equatable {
        var text: String
        var undo: Bool = false
    }

    /// Уведомления о подключении/отключении в тост не идут — их видно на
    /// карточке состояния (и их объявляет VoiceOver).
    static func toast(_ notice: CoreNotice) -> Toast? {
        switch notice {
        case .subscriptionAdded(let name): Toast(text: "Подписка «\(name)» добавлена")
        case .profileUpdated(let reconnected):
            Toast(text: reconnected ? "Подписка обновлена, подключение восстановлено" : "Подписка обновлена")
        case .profileRemoved(let name): Toast(text: "Подписка «\(name)» удалена", undo: true)
        case .profileRestored(let name): Toast(text: "Подписка «\(name)» возвращена")
        case .serverSavedForNextConnection: Toast(text: "Сервер выбран — он будет использован при подключении")
        case .serverSwitched(let name): Toast(text: "Переключились на «\(name)»")
        case .autoSelectSaved: Toast(text: "Автовыбор включён")
        case .autoSelectChose(let name): Toast(text: "Автовыбор выбрал «\(name)»")
        case .modeSaved: Toast(text: "Режим подключения сохранён")
        case .connected, .disconnected: nil
        }
    }

    static func announcement(_ notice: CoreNotice) -> String? {
        switch notice {
        case .connected(let name): name.map { "Подключено через \($0)" } ?? "Подключено"
        case .disconnected: "Отключено"
        default: toast(notice)?.text
        }
    }

    // MARK: Ошибки

    enum Action: Equatable {
        case retryConnect
        case useAutoSelect
        case addSubscription
        case switchToManual
        case refreshProfile
        case installHelper
    }

    struct Problem: Equatable {
        var message: String
        var action: Action?
        var actionTitle: String? {
            switch action {
            case .retryConnect: "Подключить снова"
            case .useAutoSelect: "Включить автовыбор"
            case .addSubscription: Copy.addSubscription
            case .switchToManual: "Режим «Вручную»"
            case .installHelper: "Установить снова"
            case .refreshProfile: "Обновить подписку"
            case nil: nil
            }
        }
    }

    static func problem(_ code: CoreErrorCode, serverName: String?, autoSelected: Bool) -> Problem {
        switch code {
        case .invalidSubscriptionUrl:
            Problem(message: "Это не похоже на ссылку подписки. Скопируйте её целиком — она начинается с https://.")
        case .subscriptionFetchFailed:
            Problem(message: "Не удалось загрузить подписку. Проверьте интернет и попробуйте ещё раз.")
        case .unsupportedSubscriptionFormat:
            Problem(message: "Gorion не узнал формат подписки. Попросите у провайдера ссылку для v2ray или Xray.")
        case .noSelectableServers:
            Problem(message: "В подписке нет серверов, к которым можно подключиться.")
        case .unsupportedTransport, .invalidShareLink:
            Problem(message: "В подписке есть сервер, который Gorion пока не поддерживает. Попросите у провайдера другую ссылку.")
        case .invalidTemplate, .storage:
            Problem(message: "Не удалось прочитать сохранённую подписку. Обновите её — данные загрузятся заново.", action: .refreshProfile)
        case .profileNotFound:
            Problem(message: "Эта подписка уже удалена.")
        case .coreBinaryMissing:
            Problem(message: "В приложении не хватает компонента подключения. Переустановите Gorion.")
        case .coreStartFailed, .controllerUnavailable, .internal:
            Problem(message: "Не получилось запустить подключение. Попробуйте ещё раз.", action: .retryConnect)
        case .systemProxyFailed:
            Problem(message: "macOS не дала включить системный прокси. Попробуйте режим «Вручную».", action: .switchToManual)
        case .recoveryPending:
            Problem(message: "Gorion ещё возвращает настройки сети после прошлого запуска. Попробуйте через несколько секунд.", action: .retryConnect)
        case .anotherInstanceRunning:
            Problem(message: "Подключением уже управляет другая копия Gorion. Закройте её и попробуйте снова.", action: .retryConnect)
        case .unsupported:
            Problem(message: "Этот режим на вашем Mac недоступен. Выберите другой в меню «Подключение → Режим».")
        case .tunHelperRequired, .helperOutdated, .helperInstallCancelled:
            // Показывается карточкой установки (HelperSetupCard), не ошибкой.
            Problem(message: helperSetupBody)
        case .helperInstallFailed:
            Problem(message: "Не получилось установить системный компонент. Попробуйте ещё раз.", action: .installHelper)
        case .internetUnavailable:
            if autoSelected || serverName == nil {
                Problem(message: "Ни один сервер не открыл сайты. Проверьте интернет или обновите подписку.", action: .refreshProfile)
            } else {
                Problem(message: "Сервер «\(serverName ?? "")» не открывает сайты. Выберите другой — или включите автовыбор.", action: .useAutoSelect)
            }
        case .unexpectedExit:
            Problem(message: "Подключение неожиданно прервалось.", action: .retryConnect)
        case .noProfile:
            Problem(message: "Сначала добавьте подписку.", action: .addSubscription)
        case .engineUnsupported:
            Problem(message: "Gorion пока не умеет подключаться к этой подписке: в ней есть сервер или настройка, которых ещё нет в ядре.", action: .refreshProfile)
        }
    }

    static let details = "Подробнее"

    // MARK: Помощник (режим «Весь компьютер»)

    static let helperSetupTitle = "Ещё один шаг"
    static let helperUpdateTitle = "Нужно обновить компонент"
    static let helperSetupBody = "Чтобы VPN работал для всего компьютера, Gorion установит системный компонент. Это нужно один раз — macOS попросит пароль администратора."
    static let helperUpdateBody = "Системный компонент Gorion устарел. Обновите его — macOS попросит пароль администратора."
    static let helperInstall = "Установить"
    static let helperUpdate = "Обновить"
    static let notNow = "Не сейчас"
    /// Текст в окне пароля macOS; система допишет просьбу ввести пароль.
    static let helperPasswordPrompt = "Gorion устанавливает системный компонент, чтобы VPN работал для всего компьютера."

    // MARK: Меню и команды

    static let openWindow = "Открыть Gorion"
    static let quit = "Завершить Gorion"

    // MARK: Главный экран

    /// Строка состояния над планетой (map_connection_card.dart).
    static func heroStatus(_ stage: ConnectionStage, switching: Bool) -> String {
        if switching { return "Переключаем маршрут" }
        switch stage {
        case .starting: return "Подключаемся"
        case .connected: return "Подключение защищено"
        case .stopping: return "Отключаемся"
        case .disconnected, .failed: return "Подключение отключено"
        }
    }

    static let autoServerTitle = "Автоматически"
    static let noServer = "Не выбран"
    static let autoTag = "Авто"
    static let session = "Сессия"
    static let autoActive = "Автовыбор активен"

    /// Флаг и имя сервера.
    static func serverTitle(_ server: CoreServer) -> String {
        flagEmoji(server.countryCode).map { "\($0) \(server.name)" } ?? server.name
    }

    static func servers(_ count: Int) -> String {
        "\(count) \(plural(count, "сервер", "сервера", "серверов"))"
    }

    // MARK: Служебное

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }
}
