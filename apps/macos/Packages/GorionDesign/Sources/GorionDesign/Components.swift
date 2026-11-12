import SwiftUI

// MARK: - Кнопка

/// Варианты кнопки из каталога DESIGN.md → 7.
public enum GButtonKind: Sendable {
    /// Одно главное действие на экране (акцент).
    case primary
    case regular
    /// Тихая: без подложки, пока на неё не навели.
    case quiet
    case danger
}

public enum GButtonSize: Sendable {
    case small, regular, large

    var height: CGFloat {
        switch self {
        case .small: GComponent.buttonHeightSmall
        case .regular: GComponent.buttonHeightRegular
        case .large: GComponent.buttonHeightLarge
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: GSpacing.sm
        case .regular: GSpacing.md
        case .large: GSpacing.lg
        }
    }

    var type: TypeStyle {
        self == .large ? GType.titleMedium : GType.labelLarge
    }
}

/// Кнопка с физическим откликом: проседает на `press`, возвращается на
/// `release` с накопленной скоростью (DESIGN.md → 6.6).
public struct GButtonStyle: ButtonStyle {
    let kind: GButtonKind
    let size: GButtonSize
    let fullWidth: Bool

    public init(_ kind: GButtonKind = .regular, size: GButtonSize = .regular, fullWidth: Bool = false) {
        self.kind = kind
        self.size = size
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        GButtonBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
    }
}

private struct GButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: GButtonKind
    let size: GButtonSize
    let fullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .textStyle(size.type)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: size.height)
            .background(background(pressed: pressed), in: .rect(cornerRadius: GRadius.control))
            .contentShape(.rect(cornerRadius: GRadius.control))
            .pressFeedback(pressed: pressed, scale: size == .small ? GMotion.pressScaleSmallControl : GMotion.pressScaleButton)
            .opacity(isEnabled ? 1 : GComponent.disabledOpacity)
            .onHover { hovering = $0 }
            .animation(GMotion.hover.animation, value: hovering)
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(GColor.brandOnAccent)
        case .danger: AnyShapeStyle(GColor.statusDanger)
        case .regular, .quiet: AnyShapeStyle(GColor.textPrimary)
        }
    }

    private func background(pressed: Bool) -> AnyShapeStyle {
        switch kind {
        case .primary:
            return AnyShapeStyle(GColor.brandAccent.opacity(pressed ? GComponent.accentPressedOpacity : hovering ? GComponent.accentHoverOpacity : 1))
        case .regular, .danger:
            return AnyShapeStyle(pressed ? GMaterial.controlFillPressed : hovering ? GMaterial.controlFillHover : GMaterial.controlFill)
        case .quiet:
            return AnyShapeStyle(pressed ? GMaterial.controlFillPressed : hovering ? GMaterial.controlFill : GMaterial.controlFill.opacity(0))
        }
    }
}

extension View {
    /// Отклик на нажатие: масштаб на `press`, возврат на `release`.
    /// С «Уменьшить движение» — затемнение вместо масштаба (6.4).
    public func pressFeedback(pressed: Bool, scale: CGFloat = GMotion.pressScaleButton) -> some View {
        modifier(PressFeedback(pressed: pressed, scale: scale))
    }
}

private struct PressFeedback: ViewModifier {
    let pressed: Bool
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .brightness(pressed && reduceMotion ? -GComponent.pressedDim : 0)
            .animation(pressed ? GMotion.press.animation : GMotion.release.animation, value: pressed)
    }
}

// MARK: - Карточка и островок

extension View {
    /// Карточка внутри островка: заливка `cardFill`, без стекла (стекло на
    /// стекло не кладётся, DESIGN.md → 4).
    public func cardSurface(cornerRadius: CGFloat = GRadius.card) -> some View {
        background(GMaterial.cardFill, in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(GMaterial.cardStroke))
    }

    /// Островок окна: Liquid Glass; при «Снизить прозрачность» — сплошная
    /// поверхность из токенов.
    public func islandSurface() -> some View {
        modifier(IslandSurface())
    }
}

private struct IslandSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(GMaterial.surface, in: .rect(cornerRadius: GRadius.island))
                .overlay(RoundedRectangle(cornerRadius: GRadius.island).strokeBorder(GMaterial.hairline))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: GRadius.island))
        }
    }
}

// MARK: - Тег

/// Маленькая метка: «Авто», «VLESS», «Сессия 04:12». Не кнопка.
public struct GTag: View {
    let text: String
    let value: String?
    let symbol: String?
    let tint: DynamicColor

    public init(_ text: String, value: String? = nil, symbol: String? = nil, tint: DynamicColor = GColor.textMuted) {
        self.text = text
        self.value = value
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: GSpacing.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: GComponent.iconSizeSmall - GSpacing.xxs, weight: .semibold))
            }
            Text(text)
            if let value {
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(GColor.textPrimary)
                    .contentTransition(.numericText())
            }
        }
        .textStyle(GType.labelSmall)
        .foregroundStyle(tint)
        .padding(.horizontal, GSpacing.sm)
        .padding(.vertical, GSpacing.xs)
        .background(tint.opacity(GComponent.tagFillOpacity), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Пинг

/// Цвет задержки по порогам из токенов (DESIGN.md → 5).
public func pingColor(_ delay: Int64?) -> DynamicColor {
    guard let delay, delay > 0 else { return GColor.pingUnknown }
    if delay < GColor.pingGoodBelowMs { return GColor.statusSuccess }
    if delay < GColor.pingFairBelowMs { return GColor.statusWarning }
    return GColor.statusDanger
}

// MARK: - Флаг

/// Флаг страны из кода ISO 3166-1 alpha-2.
public func flagEmoji(_ countryCode: String?) -> String? {
    guard let code = countryCode?.uppercased(), code.count == 2 else { return nil }
    var result = ""
    for scalar in code.unicodeScalars {
        guard let flag = UnicodeScalar(0x1F1E6 + scalar.value - 0x41) else { return nil }
        result.unicodeScalars.append(flag)
    }
    return result
}
