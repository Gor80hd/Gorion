# AGENTS.md

Инструкции для ИИ-агентов (Claude Code, Codex и других). Читайте целиком перед
первой правкой.

## Что это

Gorion — десктопный VPN/прокси-клиент на базе `sing-box` для сетей с цензурой.
Проект **переезжает с Flutter на нативные приложения**:

- macOS — SwiftUI + Liquid Glass (приоритет 1);
- Windows — Rust + акрил, дизайн почти как на macOS (приоритет 2);
- логика — общее ядро на Rust (ADR-0001), интерфейсы нативные.

Где мы сейчас: [docs/migration/PLAN.md](docs/migration/PLAN.md).
Что осталось перенести: [docs/migration/parity.md](docs/migration/parity.md).
Как должно выглядеть и двигаться: [DESIGN.md](DESIGN.md).
Почему так решили: [docs/adr/](docs/adr/).

## Карта репозитория

| Путь | Что там | Статус |
| --- | --- | --- |
| `core/` | Cargo workspace: `gorion-core` (логика + runtime macOS), `gorion-engine` (свой движок подключения, ADR-0005), `gorion-ffi` (UniFFI), `gorion-helper` (помощник root для TUN, launchd) | этап 1, в работе |
| `apps/macos/` | SwiftUI-приложение (`project.yml` для XcodeGen), пакеты `GorionDesign`, `GorionKit` | этапы 2–3, в работе |
| `apps/windows/` | Rust-приложение для Windows | этап 5 |
| `design/tokens.json` | единственный источник токенов дизайна | действует |
| `docs/` | план, паритет, ADR, аудит runtime | действует |
| `lib/`, `test/`, `macos/`, `windows/`, `linux/`, `pubspec.yaml` | Flutter-версия — **источник поведения**, заморожена | только критичные исправления |
| `tool/` | загрузка sing-box с проверкой SHA-256, сборка установщика | действует |

Flutter-код — эталон: прежде чем переносить функцию, прочитайте её реализацию
и тесты в `lib/` и `test/`. Там учтены реальные сбои (`docs/runtime-audit.md`).

## Команды

```bash
# Flutter (эталон)
flutter analyze
flutter test
dart run tool/vendor_singbox.dart          # бинарники sing-box для этой ОС

# Ядро (Rust; на этой машине: export PATH="/opt/homebrew/opt/rustup/bin:$PATH")
cargo test --workspace --manifest-path core/Cargo.toml
cargo clippy --workspace --all-targets --manifest-path core/Cargo.toml -- -D warnings
cargo fmt --all --manifest-path core/Cargo.toml
# Совместимость своего движка с сервером sing-box (ADR-0005)
GORION_SINGBOX=/путь/к/sing-box cargo test -p gorion-engine --manifest-path core/Cargo.toml
# Свой движок на своём сервере: ссылка только из окружения (правило 6)
#   read -rs GORION_VLESS && export GORION_VLESS      # вставить vless://…
#   cargo run -p gorion-engine --example mixed_proxy --manifest-path core/Cargo.toml
#   curl -x socks5h://127.0.0.1:2080 https://cloudflare.com/cdn-cgi/trace
# Процесс движка так, как его запускает приложение: конфиг sing-box + Clash API
#   gorion-engine check -c config.json   # подходит ли профиль движку
#   GORION_CORE=sing-box …/Gorion        # приложение: всегда sing-box, без движка
# Помощник TUN (ADR-0005): тесты без root — ядро в режиме «Вручную»
cargo test -p gorion-helper --manifest-path core/Cargo.toml
# Ставит его только владелец (пароль): кнопка «Установить» в приложении или
#   sudo Gorion.app/Contents/Helpers/gorion-helper install --singbox Gorion.app/Contents/Resources/sing-box
#   sudo /Library/Application\ Support/Gorion/bin/gorion-helper uninstall
# GORION_HELPER_SOCKET=/путь/к/сокету — приложение говорит с тестовым помощником

# Токены дизайна: правка design/tokens.json → генерация Tokens.swift
dart run tool/gen_design_tokens.dart

# macOS: ядро → XCFramework и Swift-биндинги, затем проект и сборка
core/scripts/build-xcframework.sh debug     # или release; заодно собирает gorion-engine
(cd apps/macos && xcodegen generate)        # Gorion.xcodeproj не хранится в git
xcodebuild -project apps/macos/Gorion.xcodeproj -scheme Gorion -destination 'platform=macOS' \
  -configuration Debug -derivedDataPath apps/macos/build/DerivedData build
(cd apps/macos/Packages/GorionDesign && swift test)

# Запуск для проверок: отдельные данные и тема, настоящие подписки не трогаются
GORION_DATA_DIR=/путь/к/тестовым/данным GORION_APPEARANCE=dark \
  apps/macos/build/DerivedData/Build/Products/Debug/Gorion.app/Contents/MacOS/Gorion
# Отладка без доступа к экрану: снимок окна каждые 3 с (стекло не рисуется);
# GORION_SNAPSHOT_CONNECT=1 подключает, но только в ручном режиме или в режиме
# «Весь компьютер» без помощника (покажется карточка установки);
# GORION_SNAPSHOT_SUBSCRIPTION=URL добавляет подписку в пустой каталог данных
GORION_SNAPSHOT=/путь/к/снимку.png GORION_DATA_DIR=… \
  apps/macos/build/DerivedData/Build/Products/Debug/Gorion.app/Contents/MacOS/Gorion
```

Когда команды меняются — обновляйте этот раздел в том же коммите.

## Правила, которые нельзя нарушать

**Сеть и безопасность**

1. Здоровье сервера — только по сквозным сигналам через локальный прокси или
   TUN (URLTest, HTTP(S) через прокси, проверка выхода). Успешный TCP-коннект —
   **не** признак рабочего сервера.
2. Шаблоны подписок недоверенные: вырезать файловые цели и лишние inbound.
3. Бинарники sing-box только через `tool/singbox.lock.json` с проверкой хеша.
4. Системный прокси: снимок исходных настроек → применение → откат при любой
   ошибке. Все правила из `docs/runtime-audit.md` переносятся без упрощений.
5. Не включайте TUN и не меняйте прокси основной сетевой службы на машине
   разработчика без явной просьбы. Тесты не трогают системные маршруты.
6. Никаких секретов, токенов и ссылок подписок в логах, коммитах и фикстурах.

**Перенос**

7. Паритет раньше улучшений. Меняете поведение — отметьте `Δ` в parity.md с причиной.
8. Поведение ядра фиксируется золотыми фикстурами из Flutter-версии
   (`core/fixtures/`), Rust обязан их воспроизвести.
9. Ядро не содержит текстов для пользователя — только коды и данные.
10. В `lib/` не добавлять новых функций.

**Интерфейс**

11. Цвета, отступы, скругления, шрифты, пружины — только из токенов
    (`design/tokens.json` → сгенерированный код). Чисел «на глаз» в коде интерфейса нет.
12. Любое движение — пружина или инерция по DESIGN.md. Никаких `linear`,
    `easeInOut`, фиксированных длительностей для перемещения и масштаба.
13. Каждый экран проверяется в светлой и тёмной теме, с «Уменьшить движение»
    и VoiceOver/экранным диктором.
14. Тексты — по разделу «Тексты» DESIGN.md: человеческий язык, без жаргона в
    основных сценариях.

## Языки и стиль

- Интерфейс — на русском. Комментарии в коде — на русском, как в существующем коде.
  Идентификаторы, коммиты — на английском.
- Swift: Swift 6, строгая конкурентность, `@Observable`, `@MainActor` для моделей
  интерфейса, без force-unwrap вне тестов. Форматирование — `swift-format`.
- Rust: edition 2024, `thiserror` для ошибок библиотек, `tracing` для логов,
  `tokio` для асинхронности, без `unwrap()` вне тестов.
- Коммиты — маленькие, по одному шагу плана, сообщение говорит «что и зачем».

## Как работать над задачей

1. Найдите шаг в PLAN.md и строку в parity.md. Если их нет — добавьте.
2. Прочитайте эталон во Flutter (`lib/…` + `test/…`).
3. Логика → ядро с тестами и фикстурами. Интерфейс → по DESIGN.md.
4. Проверьте: тесты, линтеры, **запустите приложение** и посмотрите на результат
   (скриншот). Для интерфейса пройдите чек-лист DESIGN.md → «Проверка экрана».
5. Обновите статус в PLAN.md и parity.md в том же коммите.

Значимое решение (библиотека, формат, отказ от функции) — новый ADR по
шаблону `docs/adr/TEMPLATE.md`.

## Готово — это когда

- тесты и линтеры зелёные, предупреждений компилятора нет;
- функция проверена вживую, а не только тестами;
- интерфейс прошёл чек-лист DESIGN.md;
- PLAN.md и parity.md обновлены;
- в ответе честно сказано, что не проверено.
