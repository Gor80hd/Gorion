import AppKit
import SwiftUI

/// Цвет в sRGB с прозрачностью; значения приходят из tokens.json.
public struct RGBA: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(_ hex: UInt32, _ alpha: Double) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Цвет, который сам выбирает вариант для светлой и тёмной темы.
/// Используется как стиль (`.foregroundStyle(GColor.textPrimary)`) или как
/// `Color` через `.color`.
public struct DynamicColor: ShapeStyle, Sendable, Hashable {
    public let dark: RGBA
    public let light: RGBA

    public init(dark: RGBA, light: RGBA) {
        self.dark = dark
        self.light = light
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        Color(nsColor: (environment.colorScheme == .dark ? dark : light).nsColor)
    }

    /// Цвет, следящий за темой окна (для мест, где нужен `Color`).
    public var color: Color {
        let dark = dark.nsColor
        let light = light.nsColor
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
    }

    public func opacity(_ factor: Double) -> DynamicColor {
        func scaled(_ c: RGBA) -> RGBA {
            RGBA(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha * factor)
        }
        return DynamicColor(dark: scaled(dark), light: scaled(light))
    }
}

extension RGBA {
    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Стиль текста из шкалы `typography.scale`. Размер следует системному
/// масштабу текста через `relativeTo`.
public struct TypeStyle: Sendable {
    public let size: CGFloat
    public let weight: Font.Weight
    public let tracking: CGFloat
    public let lineHeight: CGFloat

    public init(size: CGFloat, weight: Font.Weight, tracking: CGFloat, lineHeight: CGFloat) {
        self.size = size
        self.weight = weight
        self.tracking = tracking
        self.lineHeight = lineHeight
    }

    public var font: Font {
        .system(size: size, weight: weight)
    }

    /// Дополнительный межстрочный интервал до заданной высоты строки.
    public var lineSpacing: CGFloat {
        max(0, size * lineHeight - size * 1.2)
    }
}

extension View {
    /// Текст по токену шкалы: шрифт, трекинг и высота строки сразу.
    public func textStyle(_ style: TypeStyle) -> some View {
        font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}

extension DynamicColor {
    /// Вариант для схемы — для `Canvas`, где нет ShapeStyle-окружения.
    public func rgba(_ scheme: ColorScheme) -> RGBA {
        scheme == .dark ? dark : light
    }

    public func resolved(_ scheme: ColorScheme) -> Color {
        Color(nsColor: rgba(scheme).nsColor)
    }
}

extension RGBA {
    public var color: Color { Color(nsColor: nsColor) }

    public func withAlpha(_ value: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: value)
    }

    /// Линейное смешение (как `Color.lerp` во Flutter).
    public func mix(_ other: RGBA, _ t: Double) -> RGBA {
        RGBA(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t)
    }
}

/// Число, зависящее от темы (например, прозрачность обводки планеты).
public struct DynamicValue: Sendable, Hashable {
    public let dark: Double
    public let light: Double

    public init(dark: Double, light: Double) {
        self.dark = dark
        self.light = light
    }

    public func value(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? dark : light
    }
}
