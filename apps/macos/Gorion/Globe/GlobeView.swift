import AppKit
import GorionDesign
import SwiftUI

/// Интерактивная планета из точек (эталон — globe_view.dart):
/// * вращается сама, её можно крутить мышью — бросок сохраняет скорость;
/// * страны с серверами подсвечены и отмечены маркерами;
/// * наведение показывает страну и число серверов, щелчок выбирает её;
/// * при подключении рисуется дуга маршрута с бегущими пакетами.
struct GlobeView: View {
    var inputs: GlobeInputs
    /// Поля области, в центре которой стоит планета.
    var insets: EdgeInsets
    /// Щелчок по стране с серверами; `nil` — щелчок мимо (сброс выбора).
    var onSelectCountry: (String?) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var scene = GlobeScene()
    @State private var hover: Hover?
    @State private var dragging = false
    @State private var lastTranslation: CGSize = .zero
    /// Окно на экране: скрытое, свёрнутое или за заблокированным экраном
    /// окно не тратит процессор на кадры, которых никто не видит.
    @State private var onScreen = true

    private struct Hover: Equatable {
        let code: String
        let point: CGPoint
    }

    var body: some View {
        let scene = scene
        scene.inputs = inputs
        scene.insets = insets
        let palette = GlobeScene.Palette(
            land: GGlobe.landColor.rgba(scheme),
            sphere: GGlobe.sphereColor.rgba(scheme),
            accent: GColor.brandAccent.rgba(scheme),
            warning: GColor.statusWarning.rgba(scheme),
            idleRim: GGlobe.idleRimColor.rgba(scheme),
            rimOpacity: GGlobe.rimOpacity.value(scheme),
            source: GColor.statusInfo.rgba(scheme),
            destination: GColor.brandAccent.rgba(scheme),
            markerCore: GGlobe.markerCoreColor.rgba(scheme))

        return GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: GGlobe.frameInterval, paused: !onScreen)) { timeline in
                Canvas(rendersAsynchronously: true) { context, size in
                    scene.size = size
                    scene.step(to: timeline.date)
                    scene.draw(in: context, palette: palette)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag)
            .onTapGesture(coordinateSpace: .local) { point in tap(at: point) }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): updateHover(point)
                case .ended: clearHover()
                }
            }
            .pointerStyle(pointer)
            .overlay(alignment: .topLeading) {
                if let hover {
                    CountryCallout(
                        code: hover.code, info: inputs.countries[hover.code],
                        selected: hover.code == inputs.selectedCountry
                    )
                    // Предел ширины снаружи стекла: подсказка облегает текст.
                    .frame(width: GComponent.calloutWidth, alignment: .topLeading)
                    .offset(calloutOffset(hover.point, bounds: proxy.size))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(GMotion.hover.animation, value: hover?.code)
        }
        .task { scene.map = await GlobeMap.loaded() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            onScreen = NSApp.windows.contains { $0.occlusionState.contains(.visible) } || Self.alwaysAnimate
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    /// Для снимка окна в отладке (DebugSnapshot) планета крутится и за
    /// заблокированным экраном.
    private static var alwaysAnimate: Bool {
        #if DEBUG
            DebugSnapshot.path != nil
        #else
            false
        #endif
    }

    private var pointer: PointerStyle {
        if dragging { return .grabActive }
        if let hover, inputs.countries[hover.code] != nil { return .link }
        return .grabIdle
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    hover = nil
                    lastTranslation = .zero
                    scene.beginDrag()
                }
                let delta = CGSize(
                    width: value.translation.width - lastTranslation.width,
                    height: value.translation.height - lastTranslation.height)
                lastTranslation = value.translation
                scene.drag(by: delta)
            }
            .onEnded { value in
                dragging = false
                scene.endDrag(velocity: value.velocity)
            }
    }

    private func tap(at point: CGPoint) {
        let code = scene.country(at: point)
        if let code, inputs.countries[code] != nil {
            onSelectCountry(code == inputs.selectedCountry ? nil : code)
        } else if inputs.selectedCountry != nil {
            onSelectCountry(nil)
        }
    }

    private func updateHover(_ point: CGPoint) {
        scene.pointerOnSphere = scene.isOnSphere(point)
        guard !dragging else { return }
        let code = scene.pointerOnSphere ? scene.country(at: point) : nil
        scene.hoverCountry = code
        hover = code.map { Hover(code: $0, point: point) }
    }

    private func clearHover() {
        scene.pointerOnSphere = false
        scene.hoverCountry = nil
        hover = nil
    }

    private func calloutOffset(_ point: CGPoint, bounds: CGSize) -> CGSize {
        let width = GComponent.calloutWidth
        let x = min(max(GSpacing.sm, point.x + GSpacing.lg), bounds.width - width - GSpacing.sm)
        let y = min(max(GSpacing.sm, point.y - GSpacing.xxxl * 2), bounds.height - GSpacing.xxxl * 2.5)
        return CGSize(width: x, height: y)
    }

    private var accessibilityLabel: String {
        let count = inputs.countries.count
        let countries = Copy.plural(count, "страна", "страны", "стран")
        if inputs.connected, let code = inputs.destinationCountry {
            return "Планета. Маршрут в \(Copy.countryName(code)). Серверы в \(count) \(countries)."
        }
        return "Планета. Серверы в \(count) \(countries)."
    }
}

/// Подпись страны у курсора.
private struct CountryCallout: View {
    let code: String
    let info: GlobeCountryInfo?
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: GSpacing.sm) {
            Text(flagEmoji(code) ?? "")
                .font(.system(size: GComponent.calloutFlagSize))
            VStack(alignment: .leading, spacing: GSpacing.xxs) {
                Text(Copy.countryName(code))
                    .textStyle(GType.titleSmall)
                    .foregroundStyle(GColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .textStyle(GType.bodySmall)
                    .monospacedDigit()
                    .foregroundStyle(info == nil ? AnyShapeStyle(GColor.textSubtle) : AnyShapeStyle(GColor.brandAccent))
                if info != nil {
                    Text(selected ? "Щёлкните, чтобы показать все" : "Щёлкните, чтобы показать серверы")
                        .textStyle(GType.labelSmall)
                        .fontWeight(.regular)
                        .foregroundStyle(GColor.textSubtle)
                }
            }
        }
        .padding(.leading, GSpacing.sm + GSpacing.xxs)
        .padding(.trailing, GSpacing.md)
        .padding(.vertical, GSpacing.sm)
        .glassEffect(.regular, in: .rect(cornerRadius: GRadius.card))
    }

    private var subtitle: String {
        guard let info else { return "Нет серверов" }
        let count = "\(info.serverCount) \(Copy.plural(info.serverCount, "сервер", "сервера", "серверов"))"
        return info.bestPing > 0 ? "\(count) · \(info.bestPing) мс" : count
    }
}
