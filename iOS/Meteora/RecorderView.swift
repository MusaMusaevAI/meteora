import SwiftUI

/// Recording screen: big timer, live meter, pause / stop.
struct RecorderView: View {
    @ObservedObject var recorder = Recorder.shared
    @ObservedObject var shared = SharedFolder.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false
    /// Self-test: draw a running recording without a microphone.
    var preview: (elapsed: TimeInterval, level: Double)?

    private var isActive: Bool { preview != nil || recorder.isActive }
    private var paused: Bool { preview == nil && recorder.state == .paused }
    private var elapsed: TimeInterval { preview?.elapsed ?? recorder.elapsed }
    private var level: Double { preview?.level ?? recorder.level }

    var body: some View {
        ZStack {
            NebulaBackground(intensity: 1).ignoresSafeArea()
            VStack(spacing: 22) {
                HStack {
                    Button("Свернуть") { dismiss() }
                        .font(Theme.ui(16, weight: .medium)).foregroundStyle(Theme.accent)
                    Spacer()
                }
                Spacer()
                Text(isActive ? (paused ? "Пауза" : "Идёт запись") : "Новая запись")
                    .font(Theme.ui(16, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text(ActivityTimer.format(elapsed))
                    .font(Theme.display(58, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.text)
                Meter(level: level, active: isActive && !paused)
                    .frame(height: 90)
                Spacer()
                if case .failed(let msg) = recorder.state {
                    Text(msg).font(Theme.ui(14)).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                }
                controls
                Text(footnote).font(Theme.ui(13)).foregroundStyle(Theme.tertiary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .confirmationDialog("Удалить эту запись?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { Task { await recorder.discard() } }
        }
    }

    private var footnote: String {
        if isActive {
            return "Можно заблокировать iPhone или переключиться в Телемост — запись продолжится. Остановить можно с экрана блокировки или из Dynamic Island."
        }
        return shared.isSet && shared.saveRecordingsHere
            ? "Запись сохранится в общую папку «\(shared.name ?? "")» — Mac увидит её сам."
            : "Запись сохранится на iPhone (Файлы → На iPhone → Meteora)."
    }

    @ViewBuilder private var controls: some View {
        if isActive {
            HStack(spacing: 36) {
                Button { confirmDiscard = true } label: {
                    Image(systemName: "trash").font(.system(size: 20, weight: .medium)).frame(width: 60, height: 60)
                        .background(Circle().fill(Theme.surface)).foregroundStyle(Theme.secondary)
                }
                .accessibilityLabel("Удалить запись")
                Button { Task { await recorder.stop() } } label: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white).frame(width: 28, height: 28)
                        .frame(width: 84, height: 84)
                        .background(Circle().fill(Theme.record))
                        .shadow(color: Theme.record.opacity(0.5), radius: 18)
                }
                .accessibilityLabel("Остановить и сохранить")
                Button { recorder.togglePause() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 22, weight: .semibold))
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Theme.surface)).foregroundStyle(Theme.text)
                }
                .accessibilityLabel(paused ? "Продолжить" : "Пауза")
            }
        } else {
            Button { Task { await recorder.start() } } label: {
                Circle().fill(.white).frame(width: 30, height: 30)
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(Theme.record))
                    .shadow(color: Theme.record.opacity(0.5), radius: 18)
            }
            .accessibilityLabel("Начать запись")
        }
    }
}

/// A row of bars that follows the input level, with a slow pearl sheen.
struct Meter: View {
    var level: Double
    var active: Bool
    @State private var history: [Double] = Array(repeating: 0, count: 36)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !active)) { ctx in
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<history.count, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accent, Theme.nacre[i % 4]], startPoint: .bottom, endPoint: .top))
                        .frame(width: 4, height: max(4, 86 * history[i]))
                        .opacity(active ? 1 : 0.35)
                }
            }
            .onChange(of: ctx.date) { _, _ in
                history.removeFirst()
                history.append(active ? max(0.05, level) : 0.05)
            }
        }
        .animation(.easeOut(duration: 0.08), value: history)
    }
}
