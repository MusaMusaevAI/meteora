import SwiftUI
import UIKit

@main
struct MeteoraiOSApp: App {
    @StateObject private var router = Router.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .onOpenURL { url in
                    Task {
                        if let r = await Library.shared.importFile(url) { router.open(r.id) }
                    }
                }
                .task {
                    _ = Recorder.shared // listens for Live Activity buttons from launch
                    if SelfTest.isRunning {
                        await SelfTest.shared.run()
                    } else {
                        await refreshSources()
                    }
                }
                .onChange(of: phase) { _, p in
                    if p == .active, !SelfTest.isRunning { Task { await refreshSources() } }
                }
        }
    }

    /// New files in Documents (added via Files) and in the shared folder.
    @MainActor private func refreshSources() async {
        await Library.shared.scanDocuments()
        await SharedFolder.shared.scan()
    }
}

/// Navigation state, also driven by the self-test.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var path: [UUID] = []
    @Published var showRecorder = false
    @Published var showSettings = false
    @Published var showOnboarding = !Onboarding.isDone && !SelfTest.isRunning
    /// First page when the onboarding opens (the self-test shows each one).
    @Published var onboardingPage = 0

    func open(_ id: UUID) {
        showRecorder = false
        showSettings = false
        path = [id]
    }
}

struct RootView: View {
    @EnvironmentObject var router: Router
    @ObservedObject var recorder = Recorder.shared

    var body: some View {
        NavigationStack(path: $router.path) {
            LibraryView()
                .navigationDestination(for: UUID.self) { id in
                    if let r = Library.shared.recording(id) {
                        MeetingView(recording: r)
                    } else {
                        Text("Запись не найдена").font(Theme.ui(15)).foregroundStyle(Theme.secondary)
                    }
                }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $router.showRecorder) {
            RecorderView(preview: SelfTest.shared.recorderPreview)
                .presentationDetents([.large])
                .interactiveDismissDisabled(recorder.isActive)
        }
        .sheet(isPresented: $router.showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $router.showOnboarding) {
            OnboardingView(finish: { router.showOnboarding = false }, page: router.onboardingPage)
        }
        .onChange(of: recorder.finished) { _, r in
            guard let r else { return }
            recorder.finished = nil
            router.open(r.id)
            if Models.shared.speechInstalled {
                // Transcribe right away, like the Mac does.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    NotificationCenter.default.post(name: MeetingView.autoTranscribe, object: r.id)
                }
            }
        }
    }
}
