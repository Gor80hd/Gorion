# ADR-0002. macOS: SwiftUI, Liquid Glass, macOS 26+

Статус: принято · 2026-11-11

## Решение

- Интерфейс — SwiftUI; AppKit только там, где SwiftUI не хватает (окно, строка
  заголовка, редкие контролы), через `NSViewRepresentable`.
- Минимальная система — **macOS 26**. Liquid Glass (`glassEffect`,
  `GlassEffectContainer`, `.buttonStyle(.glass)`) есть только там; поддержка
  старых систем удвоила бы дизайн ради уходящей аудитории.
- Swift 6, строгая проверка конкурентности. Модели — `@Observable`, `@MainActor`.
- Структура: приложение + локальные пакеты `GorionDesign` (токены, пружины,
  компоненты, без зависимостей от ядра) и `GorionKit` (обёртка ядра).
- Планета — Metal (или SceneKit, если хватит) за `NSViewRepresentable`;
  стеклянные плашки поверх неё преломляют её по-настоящему.
- Помощник TUN — `SMAppService.daemon`, запуск при входе — `SMAppService.mainApp`.
- Тесты — Swift Testing для моделей, XCUITest — дымовой сценарий подключения.

## Почему не AppKit целиком

Liquid Glass, морфинг стекла (`glassEffectID`), пружинные анимации с
сохранением скорости и доступность в SwiftUI даются бесплатно.

## Последствия

- Пользователи macOS 15 и старше остаются на последней Flutter-сборке.
- Для подписи и `SMAppService.daemon` нужна подпись Developer ID.
