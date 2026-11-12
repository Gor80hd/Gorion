import Foundation
import Testing

@testable import GorionDesign

struct MotionTests {
    @Test func springMatchesDesignFormula() {
        let token = GMotion.snappy
        #expect(abs(token.stiffness - pow(2 * .pi / 0.32, 2)) < 1e-9)
        #expect(abs(token.damping - 4 * .pi * 0.8 / 0.32) < 1e-9)
    }

    @Test func momentumTimeConstantIsAboutHalfSecond() {
        // τ = −1/ln(0.998) ≈ 499.5 мс
        #expect(abs(Momentum.timeConstant() - 0.4995) < 0.001)
        let end = Momentum.projectedEnd(position: 0, velocity: 1000)
        #expect(abs(end - 499.5) < 1)
        // Через много τ тело почти в точке остановки.
        #expect(abs(Momentum.position(at: 10, from: 0, velocity: 1000) - end) < 0.01)
    }

    @Test func snapUsesProjectedEndNotCurrentPosition() {
        // Лёгкий бросок вправо из середины выбирает правую точку.
        let target = Momentum.snapTarget(position: 40, velocity: 60, candidates: [0, 100])
        #expect(target == 100)
        #expect(Momentum.snapTarget(position: 40, velocity: 0, candidates: [0, 100]) == 0)
    }

    @Test func rubberBandIsSymmetricAndBounded() {
        let d: CGFloat = 200
        #expect(RubberBand.offset(0, dimension: d) == 0)
        #expect(RubberBand.offset(100, dimension: d) == -RubberBand.offset(-100, dimension: d))
        #expect(RubberBand.offset(1_000_000, dimension: d) < d)
        #expect(RubberBand.clamp(50, to: 0...100, dimension: d) == 50)
        #expect(RubberBand.clamp(150, to: 0...100, dimension: d) < 150)
    }

    @Test func pingThresholdsFollowTokens() {
        #expect(pingColor(nil) == GColor.pingUnknown)
        #expect(pingColor(0) == GColor.pingUnknown)
        #expect(pingColor(42) == GColor.statusSuccess)
        #expect(pingColor(150) == GColor.statusWarning)
        #expect(pingColor(900) == GColor.statusDanger)
        #expect(flagEmoji("nl") == "🇳🇱")
    }
}
