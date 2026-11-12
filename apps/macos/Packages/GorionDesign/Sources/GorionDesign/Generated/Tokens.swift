// Сгенерировано tool/gen_design_tokens.dart из design/tokens.json.
// Не редактируйте вручную.

import SwiftUI

public enum GColor {
    public static let brandAccent = DynamicColor(dark: RGBA(0x1EFFAC, 1), light: RGBA(0x0A7A55, 1))
    public static let brandOnAccent = DynamicColor(dark: RGBA(0x04120B, 1), light: RGBA(0xFFFFFF, 1))
    public static let brandSecondary = DynamicColor(dark: RGBA(0x57E3D0, 1), light: RGBA(0x0E865E, 1))
    public static let textPrimary = DynamicColor(dark: RGBA(0xF2F4F3, 1), light: RGBA(0x14181A, 1))
    public static let textMuted = DynamicColor(dark: RGBA(0x9BA3A0, 1), light: RGBA(0x5C6662, 1))
    public static let textSubtle = DynamicColor(dark: RGBA(0x6B7370, 1), light: RGBA(0x8A938F, 1))
    public static let statusSuccess = DynamicColor(dark: RGBA(0x34D399, 1), light: RGBA(0x0E9F6E, 1))
    public static let statusWarning = DynamicColor(dark: RGBA(0xFFB457, 1), light: RGBA(0xB7791F, 1))
    public static let statusDanger = DynamicColor(dark: RGBA(0xFF6B6B, 1), light: RGBA(0xC0362C, 1))
    public static let statusInfo = DynamicColor(dark: RGBA(0x6CB4FF, 1), light: RGBA(0x2F6FCC, 1))
    public static let statusUpload = DynamicColor(dark: RGBA(0xFF7AA8, 1), light: RGBA(0xC43C70, 1))
    public static let pingUnknown = DynamicColor(dark: RGBA(0x6B7370, 1), light: RGBA(0x8A938F, 1))
    public static let pingGoodBelowMs = 100
    public static let pingFairBelowMs = 300
    public static let categoryGeneral = DynamicColor(dark: RGBA(0x8E8E93, 1), light: RGBA(0x8E8E93, 1))
    public static let categoryServers = DynamicColor(dark: RGBA(0x30B0C7, 1), light: RGBA(0x30B0C7, 1))
    public static let categoryRouting = DynamicColor(dark: RGBA(0x34C759, 1), light: RGBA(0x34C759, 1))
    public static let categoryProtocols = DynamicColor(dark: RGBA(0x5E5CE6, 1), light: RGBA(0x5E5CE6, 1))
    public static let categoryAbout = DynamicColor(dark: RGBA(0xFF9F0A, 1), light: RGBA(0xFF9F0A, 1))
}

/// Заливки — запасной вариант для «Снизить прозрачность» и мест без стекла.
public enum GMaterial {
    public static let windowFallback = DynamicColor(dark: RGBA(0x0B0D0C, 1), light: RGBA(0xE9EDEB, 1))
    public static let windowTint = DynamicColor(dark: RGBA(0x000000, 0.28), light: RGBA(0xFFFFFF, 0.10))
    public static let islandFill = DynamicColor(dark: RGBA(0xFFFFFF, 0.055), light: RGBA(0xFFFFFF, 0.52))
    public static let islandStroke = DynamicColor(dark: RGBA(0xFFFFFF, 0.10), light: RGBA(0xFFFFFF, 0.75))
    public static let cardFill = DynamicColor(dark: RGBA(0xFFFFFF, 0.05), light: RGBA(0xFFFFFF, 0.55))
    public static let cardStroke = DynamicColor(dark: RGBA(0xFFFFFF, 0.07), light: RGBA(0x000000, 0.05))
    public static let controlFill = DynamicColor(dark: RGBA(0xFFFFFF, 0.07), light: RGBA(0x000000, 0.05))
    public static let controlFillHover = DynamicColor(dark: RGBA(0xFFFFFF, 0.11), light: RGBA(0x000000, 0.08))
    public static let controlFillPressed = DynamicColor(dark: RGBA(0xFFFFFF, 0.05), light: RGBA(0x000000, 0.10))
    public static let hairline = DynamicColor(dark: RGBA(0xFFFFFF, 0.08), light: RGBA(0x000000, 0.08))
    public static let overlayFill = DynamicColor(dark: RGBA(0x1B1E1D, 0.55), light: RGBA(0xFFFFFF, 0.62))
    public static let surface = DynamicColor(dark: RGBA(0x1C1F1E, 1), light: RGBA(0xFFFFFF, 1))
    public static let surfaceVariant = DynamicColor(dark: RGBA(0x262A28, 1), light: RGBA(0xEEF1F0, 1))
    public static let selectionFill = DynamicColor(dark: RGBA(0x1EFFAC, 0.14), light: RGBA(0x0A7A55, 0.12))
    public static let selectionStroke = DynamicColor(dark: RGBA(0x1EFFAC, 0.35), light: RGBA(0x0A7A55, 0.35))
    public static let glowIdle = DynamicColor(dark: RGBA(0x1EFFAC, 0.08), light: RGBA(0x0A7A55, 0.06))
    public static let glowBusy = DynamicColor(dark: RGBA(0x1EFFAC, 0.18), light: RGBA(0x0A7A55, 0.12))
    public static let glowConnected = DynamicColor(dark: RGBA(0x1EFFAC, 0.30), light: RGBA(0x0A7A55, 0.20))
    public static let glowSecondaryIdle = DynamicColor(dark: RGBA(0x57E3D0, 0.06), light: RGBA(0x0E865E, 0.05))
    public static let glowSecondaryConnected = DynamicColor(dark: RGBA(0x57E3D0, 0.16), light: RGBA(0x0E865E, 0.10))
    public static let heroCoreConnected = DynamicColor(dark: RGBA(0x1EFFAC, 0.55), light: RGBA(0x0A7A55, 0.40))
    public static let heroEdgeConnected = DynamicColor(dark: RGBA(0x1EFFAC, 0.04), light: RGBA(0x0A7A55, 0.04))
    public static let heroStrokeConnected = DynamicColor(dark: RGBA(0x1EFFAC, 0.35), light: RGBA(0x0A7A55, 0.35))
    public static let heroCoreIdle = DynamicColor(dark: RGBA(0x6B7370, 0.22), light: RGBA(0x8A938F, 0.22))
    public static let heroEdgeIdle = DynamicColor(dark: RGBA(0x6B7370, 0.04), light: RGBA(0x8A938F, 0.04))
    public static let heroStrokeIdle = DynamicColor(dark: RGBA(0x6B7370, 0.35), light: RGBA(0x8A938F, 0.35))
    public static let sidebarTint = DynamicColor(dark: RGBA(0x0A0F0D, 0.72), light: RGBA(0xFFFFFF, 0.45))
    public static let mainTint = DynamicColor(dark: RGBA(0x050907, 0.78), light: RGBA(0xF4F7F5, 0.55))
    public static let barShadow = DynamicColor(dark: RGBA(0x000000, 0.35), light: RGBA(0x000000, 0.14))
}

public enum GRadius {
    public static let island: CGFloat = 22
    public static let card: CGFloat = 14
    public static let control: CGFloat = 10
}

public enum GSpacing {
    public static let grid: CGFloat = 4
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let xxxl: CGFloat = 32
    public static let islandGap: CGFloat = 8
}

public enum GLayout {
    public static let windowDefaultWidth: CGFloat = 1280
    public static let windowDefaultHeight: CGFloat = 800
    public static let windowMinWidth: CGFloat = 940
    public static let windowMinHeight: CGFloat = 600
    public static let sidebarMinWidth: CGFloat = 220
    public static let sidebarMaxWidth: CGFloat = 320
    public static let sidebarFraction: CGFloat = 0.36
    public static let sidebarHeaderHeight: CGFloat = 52
    public static let trafficLightsWidth: CGFloat = 72
    public static let minHitTarget: CGFloat = 28
}

public enum GComponent {
    public static let buttonHeightSmall: CGFloat = 28
    public static let buttonHeightRegular: CGFloat = 32
    public static let buttonHeightLarge: CGFloat = 40
    public static let connectButtonHeight: CGFloat = 52
    public static let connectButtonMinWidth: CGFloat = 220
    public static let statusCardMaxWidth: CGFloat = 460
    public static let serverRowHeight: CGFloat = 44
    public static let flagSize: CGFloat = 20
    public static let iconSizeSmall: CGFloat = 12
    public static let iconSizeRegular: CGFloat = 14
    public static let iconSizeLarge: CGFloat = 18
    public static let toastMaxWidth: CGFloat = 440
    public static let sheetWidth: CGFloat = 460
    public static let statusDotSize: CGFloat = 8
    public static let emptyStateIconSize: CGFloat = 40
    public static let tagFillOpacity: CGFloat = 0.14
    public static let accentHoverOpacity: CGFloat = 0.92
    public static let accentPressedOpacity: CGFloat = 0.85
    public static let disabledOpacity: CGFloat = 0.45
    public static let pressedDim: CGFloat = 0.06
    public static let heroSize: CGFloat = 230
    public static let heroIdleScale: CGFloat = 0.86
    public static let heroFlagSize: CGFloat = 80
    public static let heroSymbolSize: CGFloat = 64
    public static let strokeWidth: CGFloat = 1
    public static let sparklineWidth: CGFloat = 1.5
    public static let backdropGlowRadius: CGFloat = 520
    public static let backdropSecondaryGlowRadius: CGFloat = 460
    public static let islandRadiusGlass: CGFloat = 22
    public static let connectionBarRadius: CGFloat = 28
    public static let connectionBarMaxWidth: CGFloat = 780
    public static let connectionBarGraphMinWidth: CGFloat = 600
    public static let connectionBarUploadMinWidth: CGFloat = 430
    public static let powerButtonSize: CGFloat = 56
    public static let powerIconSize: CGFloat = 20
    public static let barDividerHeight: CGFloat = 36
    public static let sparklineHeight: CGFloat = 40
    public static let sparklineStroke: CGFloat = 2
    public static let trafficHistory: CGFloat = 36
    public static let serverFlagSize: CGFloat = 22
    public static let serverLeadSize: CGFloat = 28
    public static let serverActionSize: CGFloat = 24
    public static let subscriptionRowHeight: CGFloat = 36
    public static let calloutWidth: CGFloat = 220
    public static let calloutFlagSize: CGFloat = 22
    public static let heroStatusIconSize: CGFloat = 14
    public static let emptyServersIconSize: CGFloat = 56
    public static let globeTopInset: CGFloat = 88
    public static let globeTopInsetCompact: CGFloat = 64
    public static let globeBottomInset: CGFloat = 16
    public static let globeBottomInsetCompact: CGFloat = 8
    public static let compactHeight: CGFloat = 620
    public static let shadowRadius: CGFloat = 16
    public static let shadowY: CGFloat = 14
}

/// Планета: физика вращения, геометрия и цвета.
public enum GGlobe {
    public static let samples: Int = 34000
    public static let frameInterval: Double = 0.016666
    public static let maxPitch: Double = 1.15
    public static let idleYawSpeed: Double = 0.2
    public static let hoverIdleFactor: Double = 0.3
    public static let yawVelocityLimit: Double = 6
    public static let pitchVelocityLimit: Double = 4
    public static let minDragRadius: Double = 80
    public static let focusPitchLimit: Double = 0.78
    public static let startYawOffset: Double = -0.9
    public static let startPitchMin: Double = 0.2
    public static let startPitchMax: Double = 0.6
    public static let restPitchMin: Double = 0.2
    public static let restPitchMax: Double = 0.55
    public static let resumeIdleAfter: Double = 1.2
    public static let autoFocusAfter: Double = 2.5
    public static let restAfter: Double = 4
    public static let introDuration: Double = 1.4
    public static let diameterIdle: Double = 0.88
    public static let diameterConnected: Double = 0.97
    public static let minRadius: Double = 40
    public static let dotScale: Double = 0.0068
    public static let dotMin: Double = 1.3
    public static let rimScale: Double = 0.004
    public static let markerHitRadius: Double = 18
    public static let rateIdleApproach: Double = 2.2
    public static let ratePitchDecay: Double = 3
    public static let rateFocusTurn: Double = 3.2
    public static let rateRestPitch: Double = 0.7
    public static let rateFocus: Double = 2.6
    public static let rateRevealIn: Double = 1.6
    public static let rateRevealOut: Double = 5
    public static let rateConnected: Double = 3
    public static let rateBusy: Double = 4
    public static let rateEmphasisIn: Double = 12
    public static let rateEmphasisOut: Double = 6
    public static let landColor = DynamicColor(dark: RGBA(0xFFFFFF, 0.92), light: RGBA(0x14201B, 0.62))
    public static let sphereColor = DynamicColor(dark: RGBA(0x000000, 0.38), light: RGBA(0x000000, 0.05))
    public static let idleRimColor = DynamicColor(dark: RGBA(0x8FB6D9, 1), light: RGBA(0x7A8C99, 1))
    public static let rimOpacity = DynamicValue(dark: 0.34, light: 0.3)
    public static let markerCoreColor = DynamicColor(dark: RGBA(0xFFFFFF, 1), light: RGBA(0x0B1A14, 1))
}

public enum GType {
    public static let displayLarge = TypeStyle(size: 48, weight: .bold, tracking: -1.2, lineHeight: 1.05)
    public static let displayMedium = TypeStyle(size: 40, weight: .bold, tracking: -0.9, lineHeight: 1.08)
    public static let displaySmall = TypeStyle(size: 34, weight: .bold, tracking: -0.6, lineHeight: 1.1)
    public static let headlineLarge = TypeStyle(size: 28, weight: .bold, tracking: -0.5, lineHeight: 1.14)
    public static let headlineMedium = TypeStyle(size: 22, weight: .bold, tracking: -0.3, lineHeight: 1.18)
    public static let headlineSmall = TypeStyle(size: 20, weight: .semibold, tracking: -0.2, lineHeight: 1.2)
    public static let titleLarge = TypeStyle(size: 17, weight: .semibold, tracking: -0.1, lineHeight: 1.25)
    public static let titleMedium = TypeStyle(size: 15, weight: .semibold, tracking: 0, lineHeight: 1.3)
    public static let titleSmall = TypeStyle(size: 13, weight: .semibold, tracking: 0, lineHeight: 1.3)
    public static let bodyLarge = TypeStyle(size: 15, weight: .regular, tracking: 0, lineHeight: 1.45)
    public static let body = TypeStyle(size: 13, weight: .regular, tracking: 0, lineHeight: 1.42)
    public static let bodySmall = TypeStyle(size: 12, weight: .regular, tracking: 0, lineHeight: 1.4)
    public static let labelLarge = TypeStyle(size: 13, weight: .semibold, tracking: 0, lineHeight: 1.2)
    public static let labelMedium = TypeStyle(size: 12, weight: .semibold, tracking: 0, lineHeight: 1.2)
    public static let labelSmall = TypeStyle(size: 11, weight: .semibold, tracking: 0, lineHeight: 1.2)
}

public enum GMotion {
    public static let press = SpringToken(response: 0.16, bounce: 0.0)
    public static let release = SpringToken(response: 0.34, bounce: 0.38)
    public static let hover = SpringToken(response: 0.2, bounce: 0.0)
    public static let snappy = SpringToken(response: 0.32, bounce: 0.2)
    public static let smooth = SpringToken(response: 0.45, bounce: 0.0)
    public static let bouncy = SpringToken(response: 0.42, bounce: 0.28)
    public static let heavy = SpringToken(response: 0.55, bounce: 0.08)
    public static let decelerationNormal: Double = 0.998
    public static let decelerationFast: Double = 0.99
    public static let rubberBandCoefficient: CGFloat = 0.55
    public static let pressScaleButton: CGFloat = 0.96
    public static let pressScaleSmallControl: CGFloat = 0.94
    public static let pressScaleCard: CGFloat = 0.985
    public static let breatheScale: CGFloat = 1.02
    public static let tooltipDelay: Duration = .milliseconds(520)
    public static let toastBase: Duration = .milliseconds(2600)
    public static let toastPerWord: Duration = .milliseconds(180)
    public static let toastMax: Duration = .milliseconds(7000)
}
