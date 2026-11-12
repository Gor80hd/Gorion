import AppKit
import GorionDesign
import GorionKit
import SwiftUI

/// Добавление подписки: поле, подсказка из буфера обмена, ошибка на месте.
struct AddSubscriptionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var submittedAt: UInt64?
    @State private var clipboardURL: String?
    @FocusState private var focused: Bool

    var body: some View {
        let submitting = submittedAt != nil && model.snapshot.busy
        VStack(alignment: .leading, spacing: GSpacing.lg) {
            VStack(alignment: .leading, spacing: GSpacing.xs) {
                Text(Copy.addSubscription)
                    .textStyle(GType.headlineSmall)
                    .foregroundStyle(GColor.textPrimary)
                Text(Copy.addSubscriptionHint)
                    .textStyle(GType.body)
                    .foregroundStyle(GColor.textMuted)
            }
            TextField(Copy.addSubscriptionPlaceholder, text: $url)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(submitting)
                .onSubmit(submit)
                .accessibilityLabel("Ссылка на подписку")
            if let clipboardURL, url.isEmpty {
                Button {
                    url = clipboardURL
                } label: {
                    Label("\(Copy.clipboardSuggestion): \(shortened(clipboardURL))", systemImage: "doc.on.clipboard")
                        .lineLimit(1)
                }
                .buttonStyle(GButtonStyle(.quiet, size: .small))
            }
            if let error = model.snapshot.error, submittedAt != nil, !model.snapshot.busy {
                Label {
                    Text(Copy.problem(error.code, serverName: nil, autoSelected: false).message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(GColor.statusDanger)
                }
                .textStyle(GType.body)
                .foregroundStyle(GColor.textPrimary)
            }
            HStack(spacing: GSpacing.sm) {
                Spacer()
                Button(Copy.cancel) { dismiss() }
                    .buttonStyle(GButtonStyle(.regular))
                    .keyboardShortcut(.cancelAction)
                Button(submitting ? Copy.adding : Copy.add, action: submit)
                    .buttonStyle(GButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
            }
        }
        .padding(GSpacing.xxl)
        .frame(width: GComponent.sheetWidth)
        .onAppear {
            focused = true
            clipboardURL = Self.clipboardSubscriptionURL()
        }
        .onChange(of: model.snapshot.noticeId) {
            if case .subscriptionAdded = model.snapshot.notice, submittedAt != nil {
                dismiss()
            }
        }
    }

    private func submit() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submittedAt = model.snapshot.revision
        model.addSubscription(trimmed)
    }

    private func shortened(_ value: String) -> String {
        guard let host = URL(string: value)?.host() else { return value }
        return host
    }

    /// Ссылка из буфера обмена, если она похожа на подписку (http/https).
    private static func clipboardSubscriptionURL() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: text),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host() != nil
        else { return nil }
        return text
    }
}
