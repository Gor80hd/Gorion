import CoreGraphics
import Foundation
import GorionDesign
import GorionKit
import ImageIO

/// Единичный вектор на сфере: x — восток, y — север, z — к зрителю
/// при нулевом повороте (как в globe_view.dart).
struct Vector3: Sendable {
    var x: Double
    var y: Double
    var z: Double

    func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }

    static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func * (a: Vector3, k: Double) -> Vector3 { Vector3(x: a.x * k, y: a.y * k, z: a.z * k) }

    var normalized: Vector3 {
        let length = (x * x + y * y + z * z).squareRoot()
        return length <= 0.000001 ? Vector3(x: 0, y: 0, z: 1) : self * (1 / length)
    }

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(lat: Double, lon: Double) {
        let la = lat * .pi / 180
        let lo = lon * .pi / 180
        self.init(x: cos(la) * sin(lo), y: sin(la), z: cos(la) * cos(lo))
    }

    /// Сферическая интерполяция по большой дуге.
    static func slerp(_ a: Vector3, _ b: Vector3, _ t: Double) -> Vector3 {
        let angle = acos(min(1, max(-1, a.dot(b))))
        if abs(angle) < 0.00001 { return a }
        let s = sin(angle)
        return (a * (sin((1 - t) * angle) / s) + b * (sin(t * angle) / s)).normalized
    }
}

/// Карта стран для планеты: точки суши (сфера Фибоначчи) и индекс страны
/// каждой точки. Источник — `world_map_countries.png`, где значение
/// пикселя — номер страны в `globeCountryCodes()` + 1, а 0 — океан.
final class GlobeMap: Sendable {
    /// x, y, z подряд для каждой точки суши.
    let vectors: [Float]
    /// Индекс страны (с единицы) для каждой точки.
    let indices: [UInt8]
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    /// Коды стран по индексу − 1.
    let codes: [String]

    private init(vectors: [Float], indices: [UInt8], pixels: [UInt8], width: Int, height: Int, codes: [String]) {
        self.vectors = vectors
        self.indices = indices
        self.pixels = pixels
        self.width = width
        self.height = height
        self.codes = codes
    }

    var count: Int { indices.count }

    func index(of code: String?) -> Int {
        guard let code, let i = codes.firstIndex(of: code.uppercased()) else { return 0 }
        return i + 1
    }

    func code(at index: Int) -> String? {
        index > 0 && index <= codes.count ? codes[index - 1] : nil
    }

    /// Индекс страны в точке сферы; берега и мелкие страны ищутся рядом.
    func countryIndex(at v: Vector3) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let (px, py) = pixel(for: v)
        let direct = pixels[py * width + px]
        if direct != 0 { return Int(direct) }
        for r in 1...2 {
            for dy in -r...r {
                for dx in -r...r {
                    let x = ((px + dx) % width + width) % width
                    let y = min(height - 1, max(0, py + dy))
                    let value = pixels[y * width + x]
                    if value != 0 { return Int(value) }
                }
            }
        }
        return 0
    }

    private func pixel(for v: Vector3) -> (Int, Int) {
        let lon = atan2(v.x, v.z)
        let lat = asin(min(1, max(-1, v.y)))
        let u = ((lon + .pi) / (2 * .pi)).truncatingRemainder(dividingBy: 1)
        let t = min(1, max(0, (.pi / 2 - lat) / .pi))
        let px = min(width - 1, max(0, Int((u * Double(width - 1)).rounded())))
        let py = min(height - 1, max(0, Int((t * Double(height - 1)).rounded())))
        return (px, py)
    }

    // MARK: Загрузка

    private static let shared = Task.detached(priority: .userInitiated) { () -> GlobeMap? in
        load()
    }

    /// Карта грузится один раз на всё приложение.
    static func loaded() async -> GlobeMap? {
        await shared.value
    }

    private static func load() -> GlobeMap? {
        guard let url = Bundle.main.url(forResource: "world_map_countries", withExtension: "png"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let gray = grayscalePixels(image)
        else { return nil }
        let width = image.width
        let height = image.height
        let samples = GGlobe.samples
        let golden = Double.pi * (3 - 5.0.squareRoot())
        var vectors: [Float] = []
        var indices: [UInt8] = []
        vectors.reserveCapacity(samples)
        indices.reserveCapacity(samples / 3)
        let map = GlobeMap(vectors: [], indices: [], pixels: gray, width: width, height: height, codes: [])
        for i in 0..<samples {
            let t = (Double(i) + 0.5) / Double(samples)
            let y = 1 - 2 * t
            let radial = max(0, 1 - y * y).squareRoot()
            let angle = golden * Double(i)
            let v = Vector3(x: cos(angle) * radial, y: y, z: sin(angle) * radial)
            let (px, py) = map.pixel(for: v)
            let country = gray[py * width + px]
            if country == 0 { continue }
            vectors.append(contentsOf: [Float(v.x), Float(v.y), Float(v.z)])
            indices.append(country)
        }
        return GlobeMap(
            vectors: vectors, indices: indices, pixels: gray, width: width, height: height,
            codes: globeCountryCodes())
    }

    /// Значения пикселей без цветокоррекции: это номера стран, а не яркость.
    private static func grayscalePixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        if image.bitsPerPixel == 8, image.bitsPerComponent == 8,
            let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
        {
            let rowBytes = image.bytesPerRow
            var out = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    out[y * width + x] = bytes[y * rowBytes + x]
                }
            }
            return out
        }
        // Запасной путь: рисуем в серый контекст без цветового профиля.
        var out = [UInt8](repeating: 0, count: width * height)
        let drawn = out.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? out : nil
    }
}
