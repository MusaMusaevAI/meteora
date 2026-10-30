import SwiftUI
import AppKit

/// The small recording window: choose what to record, start; while
/// recording — elapsed time, a level meter, Pause/Resume and Stop.
struct RecordingPanel: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject private var catalog: AudioInputCatalog

    init(recorder: MeetingRecorder) {
        _recorder = ObservedObject(wrappedValue: recorder)
        _catalog = ObservedObject(wrappedValue: recorder.catalog)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if recorder.isActive {
                activeContent
            } else {
                setupContent
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(width: 360, height: 280, alignment: .topLeading)
        .background(Theme.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if recorder.isActive {
                Circle()
                    .fill(recorder.state == .recording ? Theme.danger : Theme.tertiary)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(title).titleStyle(17).foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        switch recorder.state {
        case .idle, .failed: return "Запись встречи"
        case .starting: return "Подготовка…"
        case .recording: return "Идёт запись"
        case .paused: return "Пауза"
        case .finishing: return "Сохранение…"
        }
    }

    // MARK: Before recording

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recorder.availableSources.count > 1 {
                PillPicker(options: recorder.availableSources, selection: $recorder.source) { $0.title }
            }
            if recorder.source.usesMicrophone {
                microphonePicker
            }
            Text(sourceNote)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if case .failed(let message) = recorder.state {
                Text(message)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            } else if let notice = recorder.notice {
                Text(notice).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary).lineLimit(3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(recorder.folderName.map { "Папка: \($0)" } ?? "Папку выберете перед первой записью")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button("Изменить") { recorder.chooseFolder() }
                    .buttonStyle(LinkButtonStyle())
            }
            Button {
                Task { await recorder.start() }
            } label: {
                Label("Начать запись", systemImage: "record.circle")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sourceNote: String {
        switch recorder.source {
        case .microphone: return "Ваш голос и всё, что слышит микрофон."
        case .system: return "Всё, что звучит на Mac: встреча в браузере, Zoom, Телемост. Микрофон не используется."
        case .both:
            let mic = catalog.device(recorder.deviceID ?? catalog.defaultDeviceID)
            if mic?.kind == .bluetooth {
                return "Микрофон и звук Mac сводятся в одну дорожку. С микрофоном Bluetooth-наушников macOS переводит их в режим гарнитуры, и голоса собеседников звучат глуше — для лучшего качества выберите встроенный микрофон Mac, а наушники оставьте для звука."
            }
            return "Микрофон и звук Mac сводятся в одну дорожку — слышны все участники."
        }
    }

    /// System menu of inputs: built-in, AirPods, USB, iPhone (Continuity).
    private var microphonePicker: some View {
        HStack(spacing: 8) {
            Text("Микрофон").font(Theme.ui(12.5)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Picker("Микрофон", selection: deviceSelection) {
                Text(defaultTitle).tag(String?.none)
                if !catalog.devices.isEmpty { Divider() }
                ForEach(catalog.devices) { device in
                    Label(device.name, systemImage: device.kind.symbol).tag(String?.some(device.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(recorder.state == .recording || recorder.state == .finishing || recorder.state == .starting)
        }
    }

    private var defaultTitle: String {
        if let d = catalog.device(catalog.defaultDeviceID) { return "Как в системе — \(d.name)" }
        return "Как в системе"
    }

    /// A remembered device that is not connected right now shows as the
    /// default; the choice comes back when it reconnects.
    private var deviceSelection: Binding<String?> {
        Binding(get: {
            guard let id = recorder.deviceID, catalog.isConnected(id) else { return nil }
            return id
        }, set: { recorder.deviceID = $0 })
    }

    // MARK: While recording

    private var activeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RecordingTime.string(recorder.elapsed))
                .font(.system(size: 34, weight: .medium).monospacedDigit())
                .tracking(-0.5)
                .foregroundStyle(recorder.state == .recording ? Theme.text : Theme.secondary)
                .accessibilityLabel("Записано: \(RecordingTime.spoken(recorder.elapsed))")
            LevelMeter(level: recorder.level, active: recorder.state == .recording)
            Text(activeSourceLine)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let notice = recorder.notice {
                Text(notice)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            } else if let hint = recorder.systemAudioHint {
                Text(hint)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }
            if recorder.state == .paused, recorder.source.usesMicrophone, recorder.notice != nil {
                microphonePicker
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button {
                    recorder.togglePause()
                } label: {
                    Label(recorder.state == .paused ? "Продолжить" : "Пауза",
                          systemImage: recorder.state == .paused ? "record.circle" : "pause.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(recorder.state != .recording && recorder.state != .paused)

                Button {
                    recorder.stop()
                } label: {
                    Label("Остановить", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(recorder.state != .recording && recorder.state != .paused)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var activeSourceLine: String {
        switch recorder.source {
        case .microphone: return recorder.microphoneName
        case .system: return "Звук Mac"
        case .both: return "\(recorder.microphoneName) · звук Mac"
        }
    }
}

/// Thin input-level bar in the style of the app's progress track.
struct LevelMeter: View {
    var level: Float
    var active: Bool

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceSunken)
                Capsule()
                    .fill(level > 0.95 ? Theme.danger : Theme.accent)
                    .frame(width: active ? max(0, g.size.width * CGFloat(min(1, level))) : 0)
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityElement()
        .accessibilityLabel("Уровень сигнала")
        .accessibilityValue("\(Int(min(1, level) * 100)) %")
    }
}

/// Hosts the recording panel in its own small window. Closing the window
/// doesn't stop a recording: the menu-bar item keeps the controls.
@MainActor
enum RecordingWindow {
    private static var window: NSWindow?

    static func show() {
        show(recorder: MeetingRecorder.shared)
    }

    static func show(recorder: MeetingRecorder) {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Запись встречи"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = Theme.windowNS
        w.contentView = NSHostingView(rootView: RecordingPanel(recorder: recorder))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    static var isVisible: Bool { window?.isVisible == true }
}
