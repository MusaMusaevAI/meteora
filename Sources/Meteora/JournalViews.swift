import SwiftUI
import AppKit
import MeteoraCore

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
            TextField("Поиск по названиям и расшифровкам", text: $text)
                .onSubmit(onSubmit)
                .textFieldStyle(.plain)
                .font(Theme.ui(13.5))
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiary)
                    .help("Очистить")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(focused.wrappedValue ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: 1))
    }
}

struct DropOverlay: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            shape.fill(Theme.background.opacity(0.92))
            shape.strokeBorder(Nacre.gradient(.leading, .trailing), lineWidth: 2)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Отпустите, чтобы открыть").font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.text)
            }
        }
        .padding(16)
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}
