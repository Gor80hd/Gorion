# Таблица паритета функций

Каждая строка — функция Flutter-версии, которая должна появиться в новых
приложениях. Строка закрыта, когда ядро покрыто тестами/фикстурами, а
интерфейс проверен вручную по DESIGN.md.

Обозначения: `—` не начато · `◐` в работе · `●` готово · `×` снято осознанно ·
`Δ` переносим с изменением (причина в примечании) · `н/п` не применимо.

Пути источников — относительно `lib/`.

## Ядро и сеть

| Функция | Источник Flutter | Ядро | macOS | Windows | Примечание |
| --- | --- | --- | --- | --- | --- |
| Модели профиля, сервера, подписки | `features/profiles/model/*` | ● | ● | — | JSON совместим со старым хранилищем (данные в `app.gorion.client/gorion`) |
| Разбор ссылок (vless, vmess, trojan, ss, hy2, tuic, anytls) | `features/profiles/data/profile_parser.dart`, `utils/link_parsers.dart` | ● | н/п | н/п | Фикстура `parser.json`. Δ XHTTP переводится в транспорт своего движка (`type: xhttp`, поля Xray в snake_case, `extra` — тоже); эталон отказывал, потому что sing-box его не умеет. Переводятся и `downloadSettings` (отдельный сервер скачивания), размещения сессии, номера и данных, свой метод отправки, обфускация паддинга; сочетания, которые Xray не принимает (`GET` или данные в заголовках без packet-up, `downloadSettings` со stream-one или без адреса и порта), — отказ. Δ фрагмент `#имя` декодируется. Δ ссылка, которую нельзя перевести, пропускается, остальные серверы подписки остаются; ошибка — только если не перевелось ничего. Δ REALITY без `fp` получает отпечаток Chrome (как Xray), иначе sing-box не запускается |
| Подписки Xray JSON (Remnawave, Marzban, 3x-ui) | — (во Flutter нет) | ● | н/п | н/п | Δ новая функция по просьбе владельца: массив конфигураций Xray или одна конфигурация, в том числе в base64. VLESS (REALITY, Vision), VMess, Trojan, Shadowsocks, Hysteria2; транспорты raw/tcp+http, ws, grpc, httpupgrade, h2, xhttp (`xhttpSettings` и `splithttpSettings`). mKCP, QUIC Xray пропускаются. Имя сервера — `remarks`. Итог принимает свой движок, а без XHTTP — ещё и `sing-box check` (`tests/subscriptions.rs`) |
| Подписки: base64, списки, JSON sing-box | `features/profiles/data/profile_parser.dart` | ● | н/п | н/п | |
| Хранилище профилей, активный профиль | `features/profiles/data/profile_repository.dart`, `notifier/*` | ● | н/п | н/п | атомарная запись (tmp + rename), удаление с отменой |
| Обновление подписок | `features/profiles/notifier/profiles_update_notifier.dart` | ◐ | ◐ | — | ручное обновление есть (переподключает, если было подключение); автообновление по расписанию — нет |
| Порядок показа профилей | `features/profiles/utils/profile_display_order.dart` | — | н/п | н/п | |
| Сборка конфига sing-box | `features/runtime/data/singbox_config_builder.dart` | ● | н/п | н/п | шаблоны недоверенные: вырезать файлы и лишние inbound. Фикстура `config_builder.json` |
| Переопределения TLS/VLESS | `features/settings/data/connection_tuning_config_overrides.dart` | — | н/п | н/п | |
| Раздельное туннелирование | `features/settings/model/split_tunnel_settings.dart`, `features/settings/data/split_tunnel_catalog.dart` | ◐ | н/п | н/п | маршрут в конфиге есть; каталог и настройки — нет |
| Runtime: дочерний sing-box, `check`, очередь start/stop | `features/runtime/data/singbox_runtime_service.dart`, `features/runtime/data/singbox_runtime_support.dart` | ● | н/п | н/п | живой тест `tests/runtime_live.rs`. Δ ядро — `gorion-engine`, если `gorion-engine check` принимает профиль (ADR-0005), в режиме TUN тоже; иначе sing-box. Если через движок не нашлось рабочего сервера или движок не запустился — повтор через sing-box, но только когда sing-box есть в сборке. Δ сейчас в сборке macOS sing-box нет (решение владельца 2026-11-12): профиль, который движок не принял, даёт ошибку `EngineUnsupported` с причиной от `gorion-engine check`, откатов нет. `GORION_CORE=sing-box` отключает движок. Δ движок всегда показывает ClientHello Chrome, какой бы отпечаток `utls` ни был в профиле, и без `utls` тоже. Δ движок говорит только TLS 1.3: сервер Trojan или VLESS с одним TLS 1.2 через движок не подключится (через sing-box подключится). Δ для WebSocket и HTTPUpgrade движок не предлагает h2 в ALPN, даже если он задан в профиле: иначе CDN выбирает HTTP/2 и Upgrade не работает. Транспорты HTTP и QUIC, а также таймауты пингов gRPC (`idle_timeout`, `ping_timeout`) движок не поддерживает: первые уводят профиль в sing-box, вторые не используются. Δ Hysteria2 в движке: TCP и UDP (датаграммы QUIC, `network` ограничивает одно из них), смена порта из `server_ports` раз в `hop_interval` (по умолчанию 30 с, не меньше 5 с, как у hysteria); перегрузкой всегда управляет BBR (скорости `up_mbps`/`down_mbps` не используются, Brutal нет). Δ UDP через движок есть только у Hysteria2 и direct (вход SOCKS5 UDP ASSOCIATE и TUN); у Shadowsocks, Trojan и VLESS UDP пока нет. Δ XHTTP в движке: HTTP/3 (только TLS с ALPN `h3`), HTTP/2 и HTTP/1.1 во всех режимах, `downloadSettings`, обфускация паддинга, размещения как в Xray 26.3; пинги HTTP/2 xmux (`h_keep_alive_period`) не шлются; заголовки браузера — как у Xray (Chrome), версия Chrome считается по той же формуле, но может отличаться от Xray на единицу |
| Адаптивный runtime (процесс / помощник) | `features/runtime/data/adaptive_runtime_engine.dart`, `features/runtime/data/privileged_helper_runtime_engine.dart` | ◐ | н/п | н/п | TUN — в помощнике (`TunRuntime`), остальные режимы — в процессе приложения; другой путь при запуске останавливается. Неожиданный выход ядра в помощнике приходит событием. Помощнику передаётся «только sing-box» для повтора после движка. Δ TUN через свой движок (macOS, первый срез): без разбора SNI — сервер получает IP-адрес цели, а не имя; UDP, кроме DNS, идёт через сервер, если тот умеет UDP (сейчас Hysteria2 и direct), иначе приложение получает «порт недоступен» и QUIC переходит на TCP; ICMP (ping) не передаётся; DNS — только управляемый (DoH 1.1.1.1 через сервер), DNS шаблона и раздельное туннелирование уводят в sing-box; имена серверов разрешаются один раз при подъёме туннеля. Вживую с настоящим TUN не проверено (правило 5) |
| Clash API | `features/runtime/data/clash_api_client.dart` | ● | н/п | н/п | Δ задержка — по каждому прокси (`/proxies/{tag}/delay`, 16 параллельно): групповой замер возвращал `{}` во время стартового URLTest |
| Системный прокси macOS | `features/runtime/data/macos_system_proxy.dart` | ◐ | н/п | н/п | все правила из runtime-audit.md; покрыто тестами с подставным networksetup; на основной сети вживую не проверено (правило 5) |
| Системный прокси Windows + WinHTTP | `features/runtime/data/windows_system_proxy.dart`, `features/runtime/data/windows_winhttp_proxy_service.dart` | — | н/п | н/п | |
| Watchdog очистки после сбоя | `features/runtime/data/*_runtime_cleanup_watchdog.dart` | ◐ | н/п | н/п | macOS готов; Windows — нет |
| Привилегированный помощник: протокол, сервер, клиент | `core/privileged_helper/*` | ◐ | Δ | — | Δ протокол 3: строки JSON через Unix-сокет root:admin 0660 вместо HTTP с токеном; владелец — соединение-аренда вместо опроса PID через `ps` (закрылось — ядро остановлено сразу). Протокол 4: помощник ставит `gorion-engine` и sing-box, только если тот есть в сборке (иначе убирает старую копию); помощник протокола 3 считается устаревшим. Помощник собирает и чистит шаблон сам; в TUN вырезаются `*_path` и локальные rule-set (ядро от root). Раздельное туннелирование через помощника пока не передаётся. Сквозные тесты без root (`gorion-helper/tests`) |
| Установка помощника macOS | `core/privileged_helper/macos_helper_installer.dart` | ◐ | ◐ | н/п | как во Flutter: osascript с паролем + LaunchDaemon с той же меткой. Δ ставит себя сам `gorion-helper install` (копия в `/Library/Application Support/Gorion/bin`, root:wheel), убирает Flutter-копию `Helper.app` и файл с токеном. `SMAppService.daemon` требует подписи Developer ID — отложено (ADR-0005). Настоящая установка не проверена: нужен пароль владельца |
| Повышение прав Windows, перезапуск | `core/windows/*` | н/п | н/п | — | |
| Замеры серверов (benchmark) | `features/home/data/server_benchmark_runtime_service.dart`, `features/home/application/server_benchmark_controller.dart` | ◐ | ◐ | — | задержка по всем серверам; скорость — только при выборе сервера |
| Автовыбор сервера, предподключение | `features/auto_select/**`, `features/home/application/dashboard_auto_select.dart` | ◐ | ◐ | — | только end-to-end сигналы. Δ пока один проход при подключении (до 6 кандидатов): нет фонового сопровождения, кулдаунов, кэша |
| Подключение / переподключение / выход | `features/home/application/dashboard_connection.dart`, `features/home/application/dashboard_controller.dart` | ◐ | ◐ | — | проверка после подключения: домен + IP + скорость через локальный прокси. Δ режим по умолчанию — «Весь компьютер» (TUN через помощника, ADR-0005); режим хранится в `native-settings.json` под ключом `connectionMode` (прежний `runtimeMode` не читается) |
| IP и страна выхода | `features/proxy/**`, `features/proxy/utils/ip_info_display.dart` | ◐ | ◐ | — | ядро `ipinfo`: ip.sb → ipwho.is → ipapi.co (4 с), напрямую и через локальный прокси, с отбрасыванием устаревших ответов; страна выхода — `geo` (имя сервера → маршрут). Строка места — как во Flutter, на языке сервиса |
| Статистика трафика | `features/stats/notifier/stats_notifier.dart` | ● | ● | — | |
| Определение региона | `features/intro/utils/region_detector.dart` | — | — | — | |
| Обновления приложения | `features/update/**` | — | — | — | macOS: решить Sparkle |
| Журнал (консоль) | `core/logging/gorion_console_log.dart` | — | — | — | `tracing` + os_log |
| Сброс всех настроек | `features/settings/data/app_settings_reset_service.dart` | — | — | — | |

## Интерфейс

| Функция | Источник Flutter | macOS | Windows | Примечание |
| --- | --- | --- | --- | --- |
| Окно из островков, мин. 940×600, старт 1280×800 | `app/shell.dart`, `app/shell_chrome.dart`, `macos/Runner/MainFlutterWindow.swift` | ◐ | — | два отдельных островка `NSGlassEffectView` с тонировкой из токенов, прозрачный зазор, окно без системной тени, перетаскивание за зазоры и шапку, кнопки окна внутри шапки бокового островка. Проверено вживую в обеих темах; минимальный размер — нет. В светлой теме подписи над пёстрыми обоями читаются слабее (тонировка как во Flutter) |
| Боковой островок: серверы ↔ разделы настроек | `app/shell.dart`, `features/settings/widget/settings_sidebar.dart` | ◐ | — | серверы — да. Δ шапка «Серверы» вместо сегментов «Серверы \| Настройки», пока нет экрана настроек |
| Планета, вращение с инерцией, страны с серверами | `features/home/widget/globe_view.dart`, `features/home/application/globe_interaction.dart` | ● | — | 34000 точек, страны из `world_map_countries.png`, бросок с инерцией, автофокус, раскрытие, маркеры, сканирование при подключении, дуга маршрута с пакетами; параметры — `globe` в токенах. Проверено вживую: бросок, наведение с подсказкой, подключение и маршрут. Δ кадры не рисуются, пока окно не видно; не чаще 60 в секунду |
| Карточка подключения (герой + плашка) | `features/home/widget/map_connection_card.dart` | ● | — | герой (статус, сервер, теги, таймер сессии), плашка Liquid Glass: кнопка, IP, загрузка, график, отдача. Δ переключателя режима на главном экране нет: одна кнопка включает VPN для всего компьютера; другие режимы — в меню «Подключение → Режим», напоминает метка. Без помощника вместо ошибки — карточка «Ещё один шаг» с кнопкой «Установить» (проверено снимком окна) |
| Панель трафика (загрузка/отдача) | `features/home/widget/map_traffic_panel.dart` | ● | — | скорость + график |
| Элементы управления картой | `features/home/widget/map_controls.dart` | — | — | |
| Список серверов: группы, карточки, пинг | `features/home/widget/servers_panel*.dart`, `features/home/widget/server_card.dart` | ◐ | — | карточки и пинг есть; группы по странам — нет |
| Сортировка: без / пинг / скорость / имя | `features/home/model/server_sort_mode.dart` | ◐ | — | без / пинг / имя; по скорости — нет |
| Избранное | `features/home/application/server_favorites_controller.dart` | — | — | |
| Фильтр по стране с планеты, подсветка при наведении | `features/home/application/globe_interaction.dart` | ◐ | — | наведение на страну — подсветка и подсказка (проверено). Щелчок по стране с серверами и подсветка страны при наведении на сервер в списке вживую не проверены: синтетический курсор не даёт событий входа и выхода |
| Параллельный тест серверов (старт/стоп) | `features/home/widget/servers_panel.dart` | ◐ | — | запуск есть, остановки нет |
| Параметры сервера (JSON, копировать) | `features/home/widget/server_settings_dialog.dart` | — | — | |
| Добавление и управление подписками | `core/router/bottom_sheets/bottom_sheets_notifier.dart`, `features/home/widget/servers_panel_controls.dart` | ◐ | — | Δ пересобрать поток по DESIGN.md. Есть: лист добавления, меню профиля (обновить, переименовать, удалить с отменой) |
| Настройки → Основные (тема, запуск, трей) | `features/settings/widget/settings_page.dart` | — | — | |
| Настройки → Серверы (автовыбор, задержка) | `features/settings/widget/settings_page.dart` | — | — | |
| Настройки → Маршрутизация | `features/settings/widget/split_tunnel_section.dart`, `features/settings/widget/split_tunnel_cards.dart`, `features/settings/widget/split_tunnel_dialogs.dart` | — | — | Δ упростить для обычного пользователя |
| Настройки → Протоколы (TLS, VLESS) | `features/settings/widget/settings_page.dart` | — | — | раздел «для опытных» |
| Настройки → О приложении (версия, обновления, сброс) | `features/settings/widget/settings_page.dart` | — | — | |
| Всплывающее окно обновления | `app/shell_update_popup.dart` | — | — | |
| Тосты, меню, подсказки, диалоги | `core/widget/glass_*.dart` | ◐ | — | системные где возможно; тост — свой (смахивание с инерцией, пауза под курсором) |
| Трей / строка меню | `app/windows_tray_controller.dart` | ● | — | macOS: `MenuBarExtra` |
| Запуск при входе, приоритет | `features/settings/data/launch_at_startup_service.dart` | — | — | macOS: `SMAppService.mainApp` |
| Автоподключение при запуске | `app/shell.dart` | — | — | |
| Тема: системная / светлая / тёмная | `app/theme_preferences.dart`, `app/theme_settings.dart` | — | — | |
| Флаги стран | `core/widget/emoji_flag_text.dart` | ◐ | — | известно: у серверов без страны бывает флаг «SS» — исправить |
| Названия стран по-русски | `features/home/application/globe_interaction.dart` | ● | — | словарь из Flutter (`CountryNames.swift`). Δ для стран вне словаря — системное русское название вместо кода («Алжир», а не «DZ») |
