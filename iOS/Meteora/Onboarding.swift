import SwiftUI

enum Onboarding {
    static let key = "onboarding.done.v1"
    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// First launch: five short animated pages in the app's own style (п. 22).
/// Every scene is drawn in SwiftUI; under Reduce Motion they stand still.
struct OnboardingView: View {
    var finish: () -> Void
    @State var page = 0
    @ObservedObject var models = Models.shared
    @ObservedObject var shared = SharedFolder.shared
    @State private var pickingFolder = false
    private let count = 5

    var body: some View {
        ZStack {
            NebulaBackground(intensity: 1).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < count - 1 {
                        Button("Пропустить") { done() }
                            .font(Theme.ui(15, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 20)
                TabView(selection: $page) {
                    OnboardingPage(title: "Встречи — в текст",
                                   text: "Meteora записывает, расшифровывает и подводит итоги прямо на iPhone. Без облака, если вы не захотите иначе.") {
                        LogoScene()
                    }.tag(0)
                    OnboardingPage(title: "Запись в фоне",
                                   text: "Заблокируйте экран или переключитесь в Телемост — запись идёт. Таймер и «Стоп» — на экране блокировки и в Dynamic Island.") {
                        IslandScene()
                    }.tag(1)
                    OnboardingPage(title: "Кто что сказал",
                                   text: "Модель GigaAM-v3 распознаёт русскую речь на устройстве, а Meteora разделяет её по голосам. Фразу можно поправить, нажав и удерживая её.") {
                        TranscriptScene()
                    }.tag(2)
                    OnboardingPage(title: "Итоги встречи",
                                   text: "Суть, решения и задачи — локальной моделью или по вашему ключу API. Делитесь в Word, PDF, Markdown.") {
                        SummaryScene()
                    }.tag(3)
                    OnboardingPage(title: "Вместе с Mac",
                                   text: "Выберите папку в iCloud Drive: записи с iPhone окажутся на Mac и расшифруются там сами, а записи с Mac появятся здесь.") {
                        SyncScene()
                    }.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeOut(duration: 0.25), value: page)

                Dots(count: count, page: page).padding(.bottom, 18)
                bottom.padding(.horizontal, 24).padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $pickingFolder) {
            FolderPicker { url in shared.choose(url) }.ignoresSafeArea()
        }
    }

    @ViewBuilder private var bottom: some View {
        if page < count - 1 {
            Button("Дальше") { withAnimation { page += 1 } }.buttonStyle(PrimaryButtonStyle())
        } else {
            VStack(spacing: 10) {
                Button {
                    pickingFolder = true
                } label: {
                    Label(shared.name.map { "Папка: \($0)" } ?? "Выбрать общую папку", systemImage: shared.isSet ? "checkmark.icloud" : "icloud")
                }
                .buttonStyle(SecondaryButtonStyle())
                if case .speech = models.downloading {
                    ProgressRow(text: "Загрузка модели речи", value: models.progress, cancel: nil)
                } else if !models.speechInstalled {
                    Button { Task { await models.download(.speech) } } label: {
                        Label("Скачать модель речи · \(models.speechSize)", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button("Начать") { done() }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func done() {
        Onboarding.isDone = true
        finish()
    }
}

private struct OnboardingPage<Scene: View>: View {
    var title: String
    var text: String
    @ViewBuilder var scene: Scene
    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            scene.frame(height: 300)
            Text(title).titleStyle(28).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Text(text).font(Theme.ui(16)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
            Spacer(minLength: 0)
        }
    }
}

private struct Dots: View {
    var count: Int
    var page: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i == page ? Theme.accent : Theme.tertiary.opacity(0.4))
                    .frame(width: i == page ? 20 : 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.2), value: page)
    }
}

/// Time since the scene appeared (0 under Reduce Motion: the final frame).
private struct SceneClock<Content: View>: View {
    var period: Double
    @ViewBuilder var content: (Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    var body: some View {
        if reduceMotion {
            content(period)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                content(ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: period))
            }
            .onAppear { start = Date() }
        }
    }
}

// MARK: - Scenes

/// The meteor flies in and becomes the first stroke of the M.
private struct LogoScene: View {
    var body: some View {
        SceneClock(period: 6) { t in
            let p = min(1, t / 1.4)
            let eased = 1 - pow(1 - p, 3)
            ZStack {
                GlowHalo(size: 220).opacity(0.5 + 0.5 * eased)
                LogoMark().frame(width: 150, height: 150)
                    .opacity(eased)
                    .scaleEffect(0.9 + 0.1 * eased)
                // The incoming streak.
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.nacre[1], Theme.nacre[2].opacity(0)],
                                         startPoint: .trailing, endPoint: .leading))
                    .frame(width: 160, height: 4)
                    .rotationEffect(.degrees(50))
                    .offset(x: -40 - 160 * (1 - eased), y: -40 - 190 * (1 - eased))
                    .opacity(p < 1 ? 1 - p * 0.6 : max(0, 0.4 - (t - 1.4)))
            }
        }
    }
}

/// A Dynamic Island that grows into the expanded recording view.
private struct IslandScene: View {
    var body: some View {
        SceneClock(period: 7) { t in
            let open = t > 1.2 && t < 5.5
            let state = RecordingActivityAttributes.ContentState(startedAt: Date().addingTimeInterval(-754 - t),
                                                                 pausedElapsed: nil,
                                                                 level: 0.45 + 0.35 * sin(t * 5))
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .fill(Theme.stage)
                    .frame(width: 250, height: 300)
                    .overlay(RoundedRectangle(cornerRadius: 46, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 2))
                ZStack {
                    RoundedRectangle(cornerRadius: open ? 34 : 20, style: .continuous).fill(.black)
                    if open {
                        HStack(spacing: 10) {
                            RecordingDot(paused: false, size: 9)
                            ActivityTimer(state: state).font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                            Spacer()
                            LevelBars(level: state.level, paused: false)
                            Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 30, height: 30).background(Circle().fill(ActivityPalette.record))
                        }
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                    } else {
                        HStack {
                            RecordingDot(paused: false, size: 7)
                            Spacer()
                            Text(ActivityTimer.format(754 + t)).font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit().foregroundStyle(ActivityPalette.accent)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .frame(width: open ? 226 : 130, height: open ? 74 : 34)
                .padding(.top, 12)
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: open)
                VStack(spacing: 4) {
                    Text("12:41").font(.system(size: 48, weight: .semibold, design: .rounded)).foregroundStyle(Theme.stageText)
                    Text("четверг, 29 октября").font(.system(size: 13)).foregroundStyle(Theme.stageText.opacity(0.7))
                }
                .padding(.top, 120)
                .opacity(open ? 0.35 : 1)
            }
        }
    }
}

/// Phrases appear one by one, coloured by speaker.
private struct TranscriptScene: View {
    private let lines: [(Int, String)] = [
        (0, "Давайте решим по релизу."), (1, "Перенесём на следующую неделю."),
        (0, "Согласна. Олег, подготовь список ошибок."), (2, "Проверю оплату до пятницы."),
    ]
    var body: some View {
        SceneClock(period: 8) { t in
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    let appear = min(1, max(0, (t - Double(i) * 1.1) / 0.5))
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(Theme.speakerColor(l.0)).frame(width: 9, height: 9).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(["Анна", "Олег", "Мария"][l.0]).font(Theme.ui(13, weight: .semibold))
                                .foregroundStyle(Theme.speakerColor(l.0))
                            Text(l.1).font(Theme.ui(15)).foregroundStyle(Theme.text)
                        }
                    }
                    .opacity(appear)
                    .offset(y: 8 * (1 - appear))
                }
            }
            .padding(18)
            .frame(width: 300, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

/// Summary cards slide in.
private struct SummaryScene: View {
    private let items = [("sparkles", "Релиз переносится на неделю"), ("checkmark.seal", "Оплату проверить отдельно"),
                         ("arrow.right.circle", "Олег: список ошибок до пятницы")]
    var body: some View {
        SceneClock(period: 7) { t in
            VStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    let appear = min(1, max(0, (t - 0.3 - Double(i) * 0.7) / 0.5))
                    HStack(spacing: 12) {
                        Image(systemName: it.0).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34).background(Circle().fill(Theme.accentSoft))
                        Text(it.1).font(Theme.ui(15, weight: .medium)).foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(width: 300)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface.opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                    .opacity(appear)
                    .offset(x: 40 * (1 - appear))
                }
            }
        }
    }
}

/// iPhone and Mac with a meteor carrying a file between them.
private struct SyncScene: View {
    var body: some View {
        SceneClock(period: 4) { t in
            let p = t / 4
            ZStack {
                HStack(spacing: 130) {
                    device("iphone", "iPhone")
                    device("laptopcomputer", "Mac")
                }
                // Arc path, there and back.
                let x = -95 + 190 * (p < 0.5 ? p * 2 : 2 - p * 2)
                let y = -60 * sin(.pi * (p < 0.5 ? p * 2 : 2 - p * 2))
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 10, height: 10)
                        .shadow(color: Theme.accent, radius: 8)
                    Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                        .offset(y: -16)
                }
                .offset(x: x, y: y - 20)
                Image(systemName: "icloud").font(.system(size: 30, weight: .medium)).foregroundStyle(Theme.tertiary)
                    .offset(y: -110)
            }
        }
    }

    private func device(_ icon: String, _ name: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 64, weight: .light)).foregroundStyle(Theme.text)
            Text(name).font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }
}
