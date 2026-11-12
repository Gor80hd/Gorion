import AppKit
import SwiftUI

extension DynamicColor {
    /// `NSColor`, сам меняющийся вместе с темой окна.
    public var nsColor: NSColor {
        let dark = dark.nsColor
        let light = light.nsColor
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// Системное стекло окна (`NSGlassEffectView`) с подкраской: как у
/// островков Flutter-версии. В прозрачном окне оно преломляет рабочий стол.
public struct GlassBackdrop: NSViewRepresentable {
    let cornerRadius: CGFloat
    let tint: DynamicColor

    public init(cornerRadius: CGFloat, tint: DynamicColor) {
        self.cornerRadius = cornerRadius
        self.tint = tint
    }

    public func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        return view
    }

    public func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
        view.tintColor = tint.nsColor
    }
}

extension View {
    /// Островок окна: подкрашенное системное стекло; при «Снизить
    /// прозрачность» — сплошная поверхность из токенов.
    public func islandSurface(tint: DynamicColor) -> some View {
        modifier(TintedIsland(tint: tint))
    }
}

/// Сплошные островки вместо системного стекла — для снимков окна изнутри
/// приложения (в отладке): `cacheDisplay` не умеет рисовать стекло и
/// заливает островок белым.
@MainActor
public enum IslandRendering {
    public static var forceSolid = false
}

private struct TintedIsland: ViewModifier {
    let tint: DynamicColor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: GRadius.island, style: .continuous)
        if reduceTransparency || IslandRendering.forceSolid {
            content
                .background(GMaterial.surface, in: shape)
                .overlay(shape.strokeBorder(GMaterial.hairline))
        } else {
            content
                .background(GlassBackdrop(cornerRadius: GRadius.island, tint: tint))
                .clipShape(shape)
        }
    }
}
