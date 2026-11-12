import Foundation
import SwiftUI

/// Пружина из токенов `motion.springs` (DESIGN.md → 6.2).
/// stiffness = (2π/response)², damping = 4π(1−bounce)/response, mass = 1 —
/// ровно то, что SwiftUI строит из `Spring(duration:bounce:)`.
public struct SpringToken: Sendable, Hashable {
    public let response: Double
    public let bounce: Double

    public init(response: Double, bounce: Double) {
        self.response = response
        self.bounce = bounce
    }

    public var spring: Spring {
        Spring(duration: response, bounce: bounce)
    }

    public var stiffness: Double {
        pow(2 * .pi / response, 2)
    }

    public var damping: Double {
        4 * .pi * (1 - bounce) / response
    }

    /// Анимация пружины. SwiftUI сохраняет текущую скорость, если цель
    /// меняется посреди движения (6.1: прерывание продолжает движение).
    public var animation: Animation {
        .spring(spring)
    }

    /// Пружина, стартующая со скоростью жеста. `velocity` — в единицах
    /// значения в секунду; SwiftUI ждёт скорость, нормированную на
    /// оставшееся расстояние.
    public func animation(velocity: Double, from current: Double, to target: Double) -> Animation {
        let distance = target - current
        guard abs(distance) > .ulpOfOne else { return animation }
        return .interpolatingSpring(spring, initialVelocity: velocity / distance)
    }

    /// Тот же характер без перелёта — для прозрачности и цвета (6.2).
    public var withoutBounce: SpringToken {
        SpringToken(response: response, bounce: 0)
    }
}

extension GMotion {
    /// Анимация с учётом «Уменьшить движение»: вместо перемещения и упругости
    /// — плавная смена на `smooth` без перелёта (6.4).
    public static func animation(_ token: SpringToken, reduceMotion: Bool) -> Animation {
        reduceMotion ? smooth.withoutBounce.animation : token.animation
    }
}

/// Свободный полёт после броска (DESIGN.md → 6.3).
/// Скорость затухает как v·rate^ms; постоянная времени τ = −1/ln(rate) мс.
public enum Momentum {
    /// Постоянная времени в секундах.
    public static func timeConstant(rate: Double = GMotion.decelerationNormal) -> Double {
        -1 / log(rate) / 1000
    }

    /// Где остановится тело, брошенное из `position` со скоростью `velocity` (ед./с).
    public static func projectedEnd(
        position: CGFloat, velocity: CGFloat, rate: Double = GMotion.decelerationNormal
    ) -> CGFloat {
        position + velocity * CGFloat(timeConstant(rate: rate))
    }

    /// Положение через `t` секунд свободного полёта.
    public static func position(
        at t: Double, from position: CGFloat, velocity: CGFloat, rate: Double = GMotion.decelerationNormal
    ) -> CGFloat {
        let tau = timeConstant(rate: rate)
        return position + velocity * CGFloat(tau * (1 - exp(-t / tau)))
    }

    /// Ближайшая точка притяжения к предсказанной точке остановки.
    public static func snapTarget(
        position: CGFloat, velocity: CGFloat, candidates: [CGFloat], rate: Double = GMotion.decelerationNormal
    ) -> CGFloat? {
        let end = projectedEnd(position: position, velocity: velocity, rate: rate)
        return candidates.min { abs($0 - end) < abs($1 - end) }
    }
}

/// Резинка за границей: offset = (1 − 1/(x·c/d + 1))·d (DESIGN.md → 6.3).
public enum RubberBand {
    public static func offset(
        _ overshoot: CGFloat, dimension: CGFloat, coefficient: CGFloat = GMotion.rubberBandCoefficient
    ) -> CGFloat {
        guard dimension > 0 else { return 0 }
        let magnitude = abs(overshoot)
        let result = (1 - 1 / (magnitude * coefficient / dimension + 1)) * dimension
        return overshoot < 0 ? -result : result
    }

    /// Значение с резинкой за пределами `range`.
    public static func clamp(
        _ value: CGFloat, to range: ClosedRange<CGFloat>, dimension: CGFloat
    ) -> CGFloat {
        if value < range.lowerBound {
            return range.lowerBound + offset(value - range.lowerBound, dimension: dimension)
        }
        if value > range.upperBound {
            return range.upperBound + offset(value - range.upperBound, dimension: dimension)
        }
        return value
    }
}
