import SwiftUI
import AppKit
import VolantCore

@main
struct VolantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Volant", id: "main") {
            ContentView(model: delegate.model)
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands { AppCommands(model: delegate.model) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: MeetingModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Открыть запись…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Сохранить звук как…") { model.presentSaveAudioPanel() }
                .keyboardShortcut("s")
                .disabled(!model.canExportAudio)
        }
        CommandMenu("Запись") {
            Button(model.player?.isPlaying == true ? "Пауза" : "Воспроизвести") { model.player?.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.player == nil)
            Button("Назад на 5 секунд") { model.player?.skip(-5) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model.player == nil)
            Button("Вперёд на 5 секунд") { model.player?.skip(5) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(model.player == nil)
            Divider()
            Button("Отправить звук в MacWhisper") { Task { await model.sendToMacWhisper() } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.canExportAudio)
            Divider()
            Button("Найти ключевые кадры") { Task { await model.analyzeScenes() } }
                .keyboardShortcut("k")
                .disabled(!model.hasVideo || model.sceneProgress != nil)
            Button("Сохранить кадры в PDF…") { model.presentSavePDFPanel() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.frames.isEmpty)
            Button("Сохранить кадры в папку…") { model.presentSaveFolderPanel() }
                .disabled(model.frames.isEmpty)
            Button("Скопировать текст кадров") { model.copyFramesText() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.frames.isEmpty)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MeetingModel()
    private var selfTest: SelfTest?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        let args = CommandLine.arguments
        // Self-test is for CI only: it needs an explicit environment switch.
        if ProcessInfo.processInfo.environment["VOLANT_SELFTEST"] == "1",
           let i = args.firstIndex(of: "--selftest"), args.count > i + 2 {
            let test = SelfTest(model: model, input: URL(fileURLWithPath: args[i + 1]),
                                output: URL(fileURLWithPath: args[i + 2], isDirectory: true))
            selfTest = test
            Task { await test.run() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "webm" }) else { return }
        model.open(url)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { selfTest == nil }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Finder → Services → «Volant: звук в MacWhisper». Users can bind a
    /// global keyboard shortcut to it in System Settings → Keyboard.
    @objc func sendToMacWhisper(_ pboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "webm" }) else {
            error.pointee = "Выберите файл .webm" as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        model.open(url) { [weak self] in
            Task { await self?.model.sendToMacWhisper() }
        }
    }
}
