import GorionDesign
import GorionKit
import SwiftUI

/// Тосты (DESIGN.md → 6.6): въезжают снизу на `bouncy`, держатся
/// 2,6 с + 0,18 с на слово (не больше 7 с), не исчезают под курсором,
/// смахиваются вниз броском — решение по предсказанной точке остановки.
struct ToastHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toast: Copy.Toast?
    @State private var toastID = 0
    @State private var hovering = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            if let toast {
                ToastView(toast: toast, onUndo: {
                    model.undoRemove()
                    dismiss()
                })
                .offset(y: dragOffset)
                .onHover { hovering = $0 }
                .gesture(swipe)
                .id(toastID)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: GComponent.heroIdleScale)))
            }
        }
        .animation(GMotion.animation(GMotion.bouncy, reduceMotion: reduceMotion), value: toastID)
        .animation(GMotion.animation(GMotion.bouncy, reduceMotion: reduceMotion), value: toast == nil)
        .onChange(of: model.snapshot.noticeId) {
            guard let notice = model.snapshot.notice, let next = Copy.toast(notice) else { return }
            dragOffset = 0
            toast = next
            toastID += 1
        }
        .task(id: toastID) {
            guard let toast else { return }
            let words = toast.text.split(separator: " ").count
            let duration = min(GMotion.toastBase + GMotion.toastPerWord * words, GMotion.toastMax)
            try? await Task.sleep(for: duration)
            // Под курсором тост ждёт.
            while hovering && !Task.isCancelled {
                try? await Task.sleep(for: GMotion.tooltipDelay)
            }
            if !Task.isCancelled { dismiss() }
        }
    }

    private func dismiss() {
        toast = nil
    }

    private var swipe: some Gesture {
        DragGesture()
            .onChanged { value in
                // Вниз — свободно, вверх — резинка.
                let y = value.translation.height
                dragOffset = y > 0 ? y : RubberBand.offset(y, dimension: GComponent.buttonHeightLarge)
            }
            .onEnded { value in
                let end = Momentum.projectedEnd(position: dragOffset, velocity: value.velocity.height)
                if end > GComponent.buttonHeightLarge {
                    dismiss()
                } else {
                    withAnimation(GMotion.snappy.animation(velocity: value.velocity.height, from: dragOffset, to: 0)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

private struct ToastView: View {
    let toast: Copy.Toast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: GSpacing.md) {
            Text(toast.text)
                .textStyle(GType.body)
                .foregroundStyle(GColor.textPrimary)
                .lineLimit(2)
            if toast.undo {
                Button(Copy.undo, action: onUndo)
                    .buttonStyle(GButtonStyle(.quiet, size: .small))
                    .foregroundStyle(GColor.brandAccent)
            }
        }
        .padding(.horizontal, GSpacing.lg)
        .padding(.vertical, GSpacing.sm + GSpacing.xxs)
        .frame(maxWidth: GComponent.toastMaxWidth)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}
