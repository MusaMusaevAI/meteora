import SwiftUI
import AppKit
import Combine
import MeteoraCore

@main
struct MeteoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The main window is created by the app delegate (AppKit) so it exists
    // deterministically however the app is launched. This scene only carries
    // the menu commands.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Проверить обновления…") { UpdateChecker.shared.checkInteractively() }
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Настройки…") { SettingsWindow.show(model: delegate.model) }
                        .keyboardShortcut(",")
                    Button("Хранилище…") { SettingsWindow.show(.storage, model: delegate.model) }
                    Button("Словарь…") { DictionaryWindow.show() }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                }
                AppCommands(model: delegate.model)
                CommandGroup(replacing: .help) {
                    Button("Знакомство с Meteora") { OnboardingWindow.show(model: delegate.model) }
                }
            }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: MeetingModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Открыть запись…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
            Button("Записать встречу…") { RecordingWindow.show() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Пакетная обработка…") { BatchWindow.show() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Закрыть запись") { model.requestClose() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.loadState == .empty)
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
            Button("Передать звук в другое приложение") { Task { await model.sendToMacWhisper() } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.canExportAudio)
            Button("Расшифровать запись") { Task { await model.transcribe() } }
                .keyboardShortcut("t")
                .disabled(!model.canTranscribe || !SpeechModelController.shared.isInstalled)
            Divider()
            Button("Найти ключевые кадры") { Task { await model.analyzeScenes() } }
                .keyboardShortcut("k")
                .disabled(!model.hasVideo || model.sceneProgress != nil)
            Button("Экспортировать…") { model.exportSheetShown = true }
                .keyboardShortcut("e")
                .disabled(!model.canExportDocuments)
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = MeetingModel()
    private var selfTest: SelfTest?
    private var mainWindow: NSWindow?
    private var titleWatch: AnyCancellable?

    func showMainWindow() {
        if let w = mainWindow {
            w.makeKeyAndOrderFront(nil)
            return
        }
        // Three panes want room: as large as the screen comfortably allows.
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: min(1480, max(1100, screen.width - 80)), height: min(940, max(720, screen.height - 60)))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Meteora"
        w.titlebarAppearsTransparent = true
        // The title lives in the work area's top strip (TitleTab), so a long
        // name never runs over the list of recordings.
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 820, height: 620)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.backgroundColor = Theme.windowNS
        let host = NSHostingView(rootView: ContentView(model: model))
        // The window decides its size; long lists scroll instead of
        // stretching it past the screen.
        host.sizingOptions = [.minSize]
        w.contentView = host
        w.setFrameAutosaveName("MeteoraMain3")
        if !w.setFrameUsingName("MeteoraMain3") { w.center() }
        w.delegate = self
        mainWindow = w
        titleWatch = model.$url.combineLatest(model.$customTitle).sink { [weak w] url, custom in
            w?.title = custom ?? url.map { sanitizedBaseName($0) } ?? "Meteora"
            w?.representedURL = url
        }
        w.makeKeyAndOrderFront(nil)
    }

    /// ⌘W and the close button put the recording away and return to the
    /// list of meetings; only an empty window actually closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == mainWindow, model.loadState != .empty else { return true }
        model.requestClose()
        return false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if model.cinema { model.cinema = false }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceSettings.apply()
        let isSelfTest = ProcessInfo.processInfo.environment["METEORA_SELFTEST"] == "1"
        // Opened by macOS at login with auto-folders on: stay in the menu bar.
        let quietStart = !isSelfTest && LoginItem.wasLaunchedAtLogin && AutoFolderStore.shared.hasEnabledFolders
        installAutoFolders(isSelfTest: isSelfTest)
        AutoFolderStore.shared.onOpenSettings = { [weak self] in
            guard let self else { return }
            SettingsWindow.show(.autoFolders, model: self.model)
        }
        if !quietStart { showMainWindow() }
        UpdateChecker.shared.checkOnLaunchIfNeeded()
        if !isSelfTest { Task.detached(priority: .background) { TempCleanup.run() } }
        TermDictionaryStore.shared.onChange = { [weak self] in self?.model.reapplyDictionary() }
        // A finished recording opens right away and is transcribed.
        MeetingRecorder.shared.onFinished = { [weak self] url in
            guard let self else { return }
            self.showMainWindow()
            self.model.open(url) { [weak self] in
                guard let model = self?.model, SpeechModelController.shared.isInstalled else { return }
                Task { await model.transcribe() }
            }
        }
        if !quietStart { NSApp.activate(ignoringOtherApps: true) }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        let args = CommandLine.arguments
        if !isSelfTest, !Onboarding.isDone {
            OnboardingWindow.show(model: model)
        }
        // Self-test is for CI only: it needs an explicit environment switch.
        if isSelfTest,
           let i = args.firstIndex(of: "--selftest"), args.count > i + 2 {
            let wav = args.firstIndex(of: "--asr-wav").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            let convert = args.firstIndex(of: "--convert-fixtures").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil }
            let test = SelfTest(model: model, input: URL(fileURLWithPath: args[i + 1]),
                                output: URL(fileURLWithPath: args[i + 2], isDirectory: true), asrWav: wav,
                                convertFixtures: convert)
            selfTest = test
            Task { await test.run() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: MediaFormats.isSupported) else { return }
        showMainWindow()
        model.openMany(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Background mode: with an auto-folder on, closing the window keeps
    /// Meteora running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        selfTest == nil && !AutoFolderStore.shared.keepsAppRunning
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Finder → Services → «Meteora: передать звук». Users can bind a
    /// global keyboard shortcut to it in System Settings → Keyboard.
    @objc func sendToMacWhisper(_ pboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let url = urls.first(where: MediaFormats.isSupported) else {
            error.pointee = "Выберите запись встречи" as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        showMainWindow()
        model.open(url) { [weak self] in
            Task { await self?.model.sendToMacWhisper() }
        }
    }
}
