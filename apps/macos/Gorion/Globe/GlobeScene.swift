import GorionDesign
import GorionKit
import SwiftUI

/// Сводка по стране для планеты: сколько серверов и лучший пинг.
struct GlobeCountryInfo: Equatable, Sendable {
    let code: String
    let serverCount: Int
    /// Лучшая задержка в мс; 0 — ещё не измерена.
    let bestPing: Int
}

/// Что планета показывает. Меняется вместе с состоянием приложения.
struct GlobeInputs: Equatable {
    var source = Vector3(x: 0, y: 0, z: 1)
    var destination = Vector3(x: 0, y: 0, z: 1)
    var sourceCountry: String?
    var destinationCountry: String?
    /// Маршрут на планете: подключено или переключаемся.
    var showConnection = false
    var connected = false
    /// Подключаемся или меняем маршрут.
    var busy = false
    var countries: [String: GlobeCountryInfo] = [:]
    var selectedCountry: String?
    var highlightedCountry: String?
    var reduceMotion = false

    static func == (a: GlobeInputs, b: GlobeInputs) -> Bool {
        a.sourceCountry == b.sourceCountry && a.destinationCountry == b.destinationCountry
            && a.showConnection == b.showConnection && a.connected == b.connected && a.busy == b.busy
            && a.countries == b.countries && a.selectedCountry == b.selectedCountry
            && a.highlightedCountry == b.highlightedCountry && a.reduceMotion == b.reduceMotion
            && a.source.x == b.source.x && a.source.y == b.source.y && a.source.z == b.source.z
            && a.destination.x == b.destination.x && a.destination.y == b.destination.y
            && a.destination.z == b.destination.z
    }
}

/// Пропорции рисунка, перенесённые из globe_view.dart без изменений: доли
/// радиуса, прозрачности слоёв глубины и множители размеров точек.
private enum Art {
    static let depthCull = 0.02
    static let nearDepth = 0.62
    static let midDepth = 0.3
    static let bandAlpha = [1.0, 0.78, 0.48]
    static let emphasisLift = 0.018
    static let availableMix = 0.72
    static let availableAlpha = 0.92
    static let availableDot = 1.2
    static let sourceHalo = (alpha: 0.2, dot: 2.6)
    static let sourceCore = (alpha: 0.9, dot: 1.4)
    static let destinationHalo = (alpha: 0.2, dot: 3.6)
    static let destinationCore = (alpha: 0.95, dot: 1.5)
    static let scanInset = 5.0
    static let scanSpeed = 2.6
    static let scanSpan = 0.7
    static let scanStroke = 2.2
    static let routeSteps = 72
    static let packets = 3
    static let trail = 7
    static let packetPeriod = 3.0
    static let trailStep = 0.012
}

/// Изменяемое состояние планеты. Тикер `TimelineView` двигает его каждый
/// кадр; SwiftUI-представление не пересобирается — как сцена во Flutter.
@MainActor
final class GlobeScene {
    var map: GlobeMap?
    var inputs = GlobeInputs()
    var size: CGSize = .zero
    var insets = EdgeInsets()

    private(set) var yaw = 0.0
    private(set) var pitch = 0.3
    private var focus = 0.0
    private var reveal = 0.0
    private var connected = 0.0
    private var busy = 0.0
    private var intro = 0.0
    private var time = 0.0
    private var lastFrame: Date?
    private var initialized = false

    private var yawVelocity = GGlobe.idleYawSpeed
    private var pitchVelocity = 0.0
    private var lastDragAt = -100.0
    private(set) var dragging = false
    var pointerOnSphere = false
    var hoverCountry: String?

    private var emphasis = [Double](repeating: 0, count: 256)
    private var available = [Bool](repeating: false, count: 256)
    private var markers: [Marker] = []
    private var markerSource: [String: GlobeCountryInfo] = [:]

    private struct Marker {
        let code: String
        let index: Int
        let vector: Vector3
        let phase: Double
    }

    // MARK: Кадр

    func step(to date: Date) {
        let dt = lastFrame.map { min(0.05, max(0, date.timeIntervalSince($0))) } ?? 0
        lastFrame = date
        time += dt
        let reduce = inputs.reduceMotion

        func approach(_ current: Double, _ target: Double, _ rate: Double) -> Double {
            current + (target - current) * (1 - exp(-dt * rate))
        }

        if !initialized {
            let start = orientation(for: inputs.source)
            yaw = start.yaw + GGlobe.startYawOffset
            pitch = min(GGlobe.startPitchMax, max(GGlobe.startPitchMin, start.pitch))
            initialized = true
        }

        let target = inputs.showConnection ? 1.0 : 0.0
        focus = reduce ? target : approach(focus, target, GGlobe.rateFocus)
        reveal = reduce ? target : approach(reveal, target, inputs.showConnection ? GGlobe.rateRevealIn : GGlobe.rateRevealOut)
        connected = approach(connected, inputs.connected ? 1 : 0, GGlobe.rateConnected)
        busy = approach(busy, inputs.busy ? 1 : 0, GGlobe.rateBusy)
        if map != nil {
            intro = reduce ? 1 : min(1, intro + dt / GGlobe.introDuration)
        }

        if !dragging {
            let sinceDrag = time - lastDragAt
            if let focusTarget = autoTarget(), sinceDrag > GGlobe.autoFocusAfter {
                let k = reduce ? 1 : 1 - exp(-dt * GGlobe.rateFocusTurn)
                yaw += angleDiff(focusTarget.yaw, yaw) * k
                pitch += (focusTarget.pitch - pitch) * k
                yawVelocity = 0
                pitchVelocity = 0
            } else {
                // Планета вращается всегда; под курсором притормаживает,
                // чтобы по стране было легко попасть. «Уменьшить движение»
                // выключает самовращение, инерция броска остаётся.
                let idleSpeed = reduce ? 0 : (pointerOnSphere ? GGlobe.idleYawSpeed * GGlobe.hoverIdleFactor : GGlobe.idleYawSpeed)
                let idle = autoTarget() == nil && sinceDrag > GGlobe.resumeIdleAfter
                yawVelocity = approach(yawVelocity, idle ? idleSpeed : 0, GGlobe.rateIdleApproach)
                pitchVelocity *= exp(-dt * GGlobe.ratePitchDecay)
                yaw += yawVelocity * dt
                pitch = min(GGlobe.maxPitch, max(-GGlobe.maxPitch, pitch + pitchVelocity * dt))
                if autoTarget() == nil && sinceDrag > GGlobe.restAfter {
                    let rest = min(GGlobe.restPitchMax, max(GGlobe.restPitchMin, asin(inputs.source.y)))
                    pitch = approach(pitch, rest, GGlobe.rateRestPitch)
                }
            }
        }

        syncCountries()
        let hoverIndex = map?.index(of: hoverCountry) ?? 0
        let listIndex = map?.index(of: inputs.highlightedCountry) ?? 0
        let selectedIndex = map?.index(of: inputs.selectedCountry) ?? 0
        for i in 1..<emphasis.count {
            let goal = (i == hoverIndex || i == listIndex) ? 1.0 : (i == selectedIndex ? 0.85 : 0)
            let current = emphasis[i]
            if current == goal { continue }
            let next = reduce ? goal : approach(current, goal, goal > current ? GGlobe.rateEmphasisIn : GGlobe.rateEmphasisOut)
            emphasis[i] = abs(next - goal) < 0.004 ? goal : next
        }
    }

    private func syncCountries() {
        guard let map, inputs.countries != markerSource || markers.isEmpty && !inputs.countries.isEmpty else { return }
        markerSource = inputs.countries
        available = [Bool](repeating: false, count: 256)
        markers = inputs.countries.values.compactMap { info in
            let index = map.index(of: info.code)
            if index > 0 && index < available.count { available[index] = true }
            guard let point = countryLocation(code: info.code) else { return nil }
            let scalars = Array(info.code.unicodeScalars)
            let phase = scalars.count == 2 ? Double((Int(scalars[0].value) * 37 + Int(scalars[1].value)) % 100) / 100 : 0
            return Marker(code: info.code, index: index, vector: Vector3(lat: point.lat, lon: point.lon), phase: phase)
        }
    }

    private func autoTarget() -> (yaw: Double, pitch: Double)? {
        for code in [inputs.highlightedCountry, inputs.selectedCountry] {
            if let code, let point = countryLocation(code: code) {
                return orientation(for: Vector3(lat: point.lat, lon: point.lon))
            }
        }
        return nil
    }

    private func orientation(for v: Vector3) -> (yaw: Double, pitch: Double) {
        let lat = asin(min(1, max(-1, v.y)))
        let lon = atan2(v.x, v.z)
        return (-lon, min(GGlobe.focusPitchLimit, max(-GGlobe.focusPitchLimit, lat)))
    }

    // MARK: Геометрия и ввод

    struct Geometry {
        let center: CGPoint
        let radius: Double
    }

    var geometry: Geometry {
        let rect = CGRect(
            x: insets.leading, y: insets.top,
            width: max(1, size.width - insets.leading - insets.trailing),
            height: max(1, size.height - insets.top - insets.bottom))
        let base = Double(min(rect.width, rect.height))
        let eased = easeInOutCubic(min(1, max(0, focus)))
        let diameter = base * (GGlobe.diameterIdle + (GGlobe.diameterConnected - GGlobe.diameterIdle) * eased)
        return Geometry(center: CGPoint(x: rect.midX, y: rect.midY), radius: max(GGlobe.minRadius, diameter / 2))
    }

    func beginDrag() {
        dragging = true
        hoverCountry = nil
        yawVelocity = 0
        pitchVelocity = 0
    }

    func drag(by delta: CGSize) {
        let radius = max(GGlobe.minDragRadius, geometry.radius)
        yaw += Double(delta.width) / radius
        pitch = min(GGlobe.maxPitch, max(-GGlobe.maxPitch, pitch + Double(delta.height) / radius))
    }

    /// Бросок: скорость пальца становится угловой скоростью и гаснет сама.
    func endDrag(velocity: CGSize) {
        let radius = max(GGlobe.minDragRadius, geometry.radius)
        yawVelocity = min(GGlobe.yawVelocityLimit, max(-GGlobe.yawVelocityLimit, Double(velocity.width) / radius))
        pitchVelocity = min(GGlobe.pitchVelocityLimit, max(-GGlobe.pitchVelocityLimit, Double(velocity.height) / radius))
        lastDragAt = time
        dragging = false
    }

    func isOnSphere(_ p: CGPoint) -> Bool {
        let g = geometry
        return hypot(p.x - g.center.x, p.y - g.center.y) <= g.radius
    }

    /// Страна под курсором: сначала ближайший маркер, затем пиксель карты.
    func country(at p: CGPoint) -> String? {
        guard let map else { return nil }
        let g = geometry
        var nearest: String?
        var best = GGlobe.markerHitRadius
        for marker in markers {
            guard let projected = project(marker.vector, g, cull: true), projected.depth >= 0.12 else { continue }
            let d = hypot(projected.point.x - p.x, projected.point.y - p.y)
            if d < best {
                best = d
                nearest = marker.code
            }
        }
        if let nearest { return nearest }
        guard let v = unproject(p, g) else { return nil }
        return map.code(at: map.countryIndex(at: v))
    }

    private func project(_ v: Vector3, _ g: Geometry, radius: Double? = nil, cull: Bool) -> (point: CGPoint, depth: Double)? {
        let r = radius ?? g.radius
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let x1 = v.x * cy + v.z * sy
        let z1 = -v.x * sy + v.z * cy
        let y2 = v.y * cp - z1 * sp
        let z2 = v.y * sp + z1 * cp
        if cull && z2 <= 0 { return nil }
        return (CGPoint(x: g.center.x + x1 * r, y: g.center.y - y2 * r), z2)
    }

    private func unproject(_ p: CGPoint, _ g: Geometry) -> Vector3? {
        let x1 = Double(p.x - g.center.x) / g.radius
        let y2 = -Double(p.y - g.center.y) / g.radius
        let squared = 1 - x1 * x1 - y2 * y2
        if squared < 0 { return nil }
        let z2 = squared.squareRoot()
        let cp = cos(pitch), sp = sin(pitch), cy = cos(yaw), sy = sin(yaw)
        let y = y2 * cp + z2 * sp
        let z1 = -y2 * sp + z2 * cp
        return Vector3(x: x1 * cy - z1 * sy, y: y, z: x1 * sy + z1 * cy)
    }

    // MARK: Рисунок

    struct Palette {
        let land: RGBA
        let sphere: RGBA
        let accent: RGBA
        let warning: RGBA
        let idleRim: RGBA
        let rimOpacity: Double
        let source: RGBA
        let destination: RGBA
        let markerCore: RGBA
    }

    func draw(in context: GraphicsContext, palette: Palette) {
        guard size.width > 0, size.height > 0 else { return }
        let g = geometry
        let state = palette.idleRim.mix(palette.accent, connected).mix(palette.warning, busy * (1 - connected))
        let disc = Path(ellipseIn: CGRect(x: g.center.x - g.radius, y: g.center.y - g.radius, width: g.radius * 2, height: g.radius * 2))

        // Плоский диск: объём дают только точки суши.
        context.fill(disc, with: .color(palette.sphere.color))
        var clipped = context
        clipped.clip(to: disc)
        drawLand(clipped, g, palette)

        context.stroke(disc, with: .color(state.withAlpha(palette.rimOpacity).color), lineWidth: max(1, g.radius * GGlobe.rimScale))
        drawMarkers(context, g, palette)
        if busy > 0.02 { drawScan(context, g, state) }
        if reveal > 0.02 { drawRoute(context, g, palette) }
    }

    private func drawLand(_ context: GraphicsContext, _ g: Geometry, _ palette: Palette) {
        guard let map else { return }
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let introLimit = 1 - 2.2 * easeOutCubic(intro)
        let dot = max(GGlobe.dotMin, g.radius * GGlobe.dotScale)
        let sourceIndex = map.index(of: inputs.sourceCountry)
        let destinationIndex = inputs.showConnection ? map.index(of: inputs.destinationCountry) : 0

        var base = [Path](repeating: Path(), count: 3)
        var avail = [Path](repeating: Path(), count: 3)
        var source: [CGPoint] = []
        var destination: [CGPoint] = []
        var emphasized: [CGPoint] = []
        var emphasisStrength = 0.0

        func add(_ path: inout Path, _ x: Double, _ y: Double, _ d: Double) {
            path.addEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
        }

        let vectors = map.vectors
        let indices = map.indices
        for i in 0..<indices.count {
            let o = i * 3
            let vx = Double(vectors[o]), vy = Double(vectors[o + 1]), vz = Double(vectors[o + 2])
            if vy < introLimit { continue }
            let z1 = -vx * sy + vz * cy
            let z2 = vy * sp + z1 * cp
            if z2 <= Art.depthCull { continue }
            let country = Int(indices[i])
            let e = emphasis[country]
            let lift = 1 + e * Art.emphasisLift
            let x1 = vx * cy + vz * sy
            let y2 = vy * cp - z1 * sp
            let x = Double(g.center.x) + x1 * g.radius * lift
            let y = Double(g.center.y) - y2 * g.radius * lift
            let band = z2 > Art.nearDepth ? 0 : (z2 > Art.midDepth ? 1 : 2)
            if e > 0.01 {
                emphasisStrength = max(emphasisStrength, e)
                emphasized.append(CGPoint(x: x, y: y))
            } else if country == destinationIndex {
                destination.append(CGPoint(x: x, y: y))
            } else if country == sourceIndex {
                source.append(CGPoint(x: x, y: y))
            } else if available[country] {
                add(&avail[band], x, y, dot * Art.availableDot)
            } else {
                add(&base[band], x, y, dot)
            }
        }

        let land = palette.land
        let opaqueLand = land.withAlpha(1)
        for band in 0..<3 {
            context.fill(base[band], with: .color(land.withAlpha(land.alpha * Art.bandAlpha[band]).color))
            context.fill(
                avail[band],
                with: .color(opaqueLand.mix(palette.accent, Art.availableMix).withAlpha(Art.availableAlpha * Art.bandAlpha[band]).color))
        }

        // Страны маршрута рисуются двумя слоями: ореол и ядро.
        func layered(_ points: [CGPoint], _ color: RGBA, _ halo: (alpha: Double, dot: Double), _ core: (alpha: Double, dot: Double), strength: Double) {
            guard !points.isEmpty else { return }
            for layer in [halo, core] {
                var path = Path()
                for p in points { add(&path, Double(p.x), Double(p.y), dot * layer.dot) }
                context.fill(path, with: .color(color.withAlpha(layer.alpha * strength).color))
            }
        }
        layered(source, palette.source, Art.sourceHalo, Art.sourceCore, strength: 1)
        if !destination.isEmpty {
            let pulse = inputs.reduceMotion ? 1 : 0.82 + 0.18 * sin(time * .pi)
            let strength = (0.55 + 0.45 * reveal) * (1 + (pulse - 1) * connected)
            layered(destination, palette.destination, Art.destinationHalo, Art.destinationCore, strength: strength)
        }

        if !emphasized.isEmpty {
            let e = min(1, max(0, emphasisStrength))
            var halo = Path()
            var core = Path()
            for p in emphasized {
                add(&halo, Double(p.x), Double(p.y), dot * (2.4 + 2.2 * e))
                add(&core, Double(p.x), Double(p.y), dot * (1.2 + 0.7 * e))
            }
            context.fill(halo, with: .color(palette.accent.withAlpha(0.22 * e).color))
            context.fill(core, with: .color(opaqueLand.mix(palette.accent, 0.5 + 0.5 * e).withAlpha(0.98).color))
        }
    }

    private func drawMarkers(_ context: GraphicsContext, _ g: Geometry, _ palette: Palette) {
        for marker in markers {
            guard let p = project(marker.vector, g, cull: true) else { continue }
            let visibility = min(1, max(0, (p.depth - 0.08) / 0.3)) * intro
            if visibility <= 0 { continue }
            let e = marker.index < emphasis.count ? emphasis[marker.index] : 0
            let size = (3.0 + e * 2.2) * (0.7 + 0.3 * p.depth)
            if !inputs.reduceMotion {
                let wave = (time * 0.45 + marker.phase).truncatingRemainder(dividingBy: 1)
                context.stroke(
                    circle(p.point, size + wave * (10 + e * 8)),
                    with: .color(palette.accent.withAlpha((1 - wave) * (0.35 + e * 0.4) * visibility).color), lineWidth: 1.2)
            }
            context.fill(circle(p.point, size + 2.5), with: .color(palette.accent.withAlpha(0.28 * visibility).color))
            context.fill(circle(p.point, size), with: .color(palette.accent.withAlpha(visibility).color))
            context.fill(circle(p.point, size * 0.42), with: .color(palette.markerCore.withAlpha(0.9 * visibility).color))
        }
    }

    /// Бегущая дуга по кромке, пока идёт подключение.
    private func drawScan(_ context: GraphicsContext, _ g: Geometry, _ color: RGBA) {
        let angle = inputs.reduceMotion ? 0 : time * Art.scanSpeed
        var arc = Path()
        arc.addArc(
            center: g.center, radius: g.radius + Art.scanInset, startAngle: .radians(angle),
            endAngle: .radians(angle + .pi * Art.scanSpan), clockwise: false)
        let gradient = Gradient(stops: [
            .init(color: color.withAlpha(0).color, location: 0),
            .init(color: color.withAlpha(busy).color, location: 0.195),
            .init(color: color.withAlpha(busy).color, location: 1),
        ])
        context.stroke(
            arc, with: .conicGradient(gradient, center: g.center, angle: .radians(angle)),
            style: StrokeStyle(lineWidth: Art.scanStroke, lineCap: .round))
    }

    private func drawRoute(_ context: GraphicsContext, _ g: Geometry, _ palette: Palette) {
        let a = inputs.source, b = inputs.destination
        let distance = acos(min(1, max(-1, a.dot(b))))
        let lift = 0.08 + 0.14 * min(1, max(0, distance / .pi))
        let visible = easeOutCubic(min(1, max(0, reveal)))
        let fade = min(1, max(0, reveal))

        func point(_ t: Double) -> (point: CGPoint, depth: Double)? {
            project(Vector3.slerp(a, b, t), g, radius: g.radius * (1 + sin(.pi * t) * lift), cull: false)
        }

        var segments: [[CGPoint]] = []
        var active: [CGPoint] = []
        for i in 0...Art.routeSteps {
            guard let p = point(Double(i) / Double(Art.routeSteps) * visible), p.depth >= -0.04 else {
                if active.count > 1 { segments.append(active) }
                active = []
                continue
            }
            active.append(p.point)
        }
        if active.count > 1 { segments.append(active) }

        let start = point(0)
        let end = point(visible)
        let from = start?.point ?? g.center
        let to = end?.point ?? g.center
        let hasSpan = hypot(to.x - from.x, to.y - from.y) > 1

        func shading(_ alpha: Double) -> GraphicsContext.Shading {
            hasSpan
                ? .linearGradient(
                    Gradient(colors: [palette.source.withAlpha(alpha * fade).color, palette.destination.withAlpha(alpha * fade).color]),
                    startPoint: from, endPoint: to)
                : .color(palette.destination.withAlpha(alpha * fade).color)
        }
        for segment in segments {
            var path = Path()
            path.addLines(segment)
            context.stroke(path, with: shading(0.12), style: StrokeStyle(lineWidth: max(5, g.radius * 0.03), lineCap: .round, lineJoin: .round))
            context.stroke(path, with: shading(0.95), style: StrokeStyle(lineWidth: max(1.6, g.radius * 0.007), lineCap: .round, lineJoin: .round))
        }

        // Пакеты с затухающим шлейфом.
        if !inputs.reduceMotion {
            for packet in 0..<Art.packets {
                let head = (time / Art.packetPeriod + Double(packet) / Double(Art.packets)).truncatingRemainder(dividingBy: 1)
                for s in 0..<Art.trail {
                    let t = head - Double(s) * Art.trailStep
                    guard t >= 0, t <= visible, let p = point(t), p.depth >= 0 else { continue }
                    let k = 1 - Double(s) / Double(Art.trail)
                    let color = palette.source.mix(palette.destination, t)
                    if s == 0 {
                        context.fill(circle(p.point, max(4.5, g.radius * 0.016)), with: .color(color.withAlpha(0.25 * fade).color))
                    }
                    let tint = s == 0 ? RGBA(0xFFFFFF, 1) : color
                    context.fill(
                        circle(p.point, max(1.2, g.radius * 0.0068) * (0.45 + 0.55 * k)),
                        with: .color(tint.withAlpha((s == 0 ? 0.95 : 0.7 * k) * fade).color))
                }
            }
        }

        func endpoint(_ p: (point: CGPoint, depth: Double)?, _ color: RGBA, _ pulseScale: Double) {
            guard let p, p.depth >= 0 else { return }
            if !inputs.reduceMotion {
                let wave = (time * 0.6).truncatingRemainder(dividingBy: 1)
                context.stroke(
                    circle(p.point, 5 + wave * 14 * pulseScale), with: .color(color.withAlpha((1 - wave) * 0.6 * fade).color),
                    lineWidth: 1.4)
            }
            context.fill(circle(p.point, 7), with: .color(color.withAlpha(0.28 * fade).color))
            context.fill(circle(p.point, 4), with: .color(color.withAlpha(fade).color))
            context.fill(circle(p.point, 1.7), with: .color(RGBA(0xFFFFFF, 0.95 * fade).color))
        }
        endpoint(start, palette.source, 0.7)
        if visible > 0.97 {
            endpoint(end, palette.destination, 1 + connected * 0.4)
        }
    }

    private func circle(_ c: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
}

private func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

private func easeInOutCubic(_ t: Double) -> Double {
    t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}

/// Кратчайшая разница углов в (-π, π].
private func angleDiff(_ target: Double, _ current: Double) -> Double {
    let d = target - current
    return atan2(sin(d), cos(d))
}
