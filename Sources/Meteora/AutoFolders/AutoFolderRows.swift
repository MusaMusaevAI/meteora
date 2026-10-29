import SwiftUI

/// Small reusable pieces for the auto-folder settings. Layout is up to the
/// settings window.

/// «Слежу за 2 папками» / «Расшифровываю «…» · 42 %» with a thin progress
/// track while a file is processed.
struct AutoFolderStatusRow: View {
    @ObservedObject var store: AutoFolderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(store.current == nil ? Theme.tertiary : Theme.accent)
                Text(store.statusLine)
                    .font(Theme.ui(12.5).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if store.current != nil {
                    Button("Пропустить") { store.skipCurrent() }.buttonStyle(LinkButtonStyle())
                }
                if store.hasEnabledFolders {
                    Button(store.isPaused ? "Возобновить" : "Приостановить") { store.togglePause() }
                        .buttonStyle(LinkButtonStyle())
                }
            }
            if let c = store.current {
                ThinProgress(value: c.fraction, active: true)
                Text("\(c.stage) · папка «\(c.folderName)»")
                    .font(Theme.ui(11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
    }

    private var icon: String {
        if store.isPaused { return "pause.circle" }
        if store.current != nil { return "waveform" }
        return "folder.badge.gearshape"
    }
}

/// One line about a folder: name, path, formats, availability.
struct AutoFolderSummaryText: View {
    var folder: WatchedFolder
    var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(folder.displayName).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text)
                if folder.isICloud {
                    Image(systemName: "icloud").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        .help("Папка в iCloud Drive: записи скачиваются перед обработкой")
                }
            }
            Text(problem ?? details)
                .font(Theme.ui(11.5)).foregroundStyle(problem == nil ? Theme.secondary : Theme.danger)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private var details: String {
        var parts = [folder.orderedFormats.map(\.short).joined(separator: ", ")]
        if folder.separateSpeakers { parts.append("говорящие") }
        if folder.summarize { parts.append("итоги") }
        let place = folder.output.title
        parts.append(place.prefix(1).lowercased() + place.dropFirst())
        return parts.joined(separator: " · ")
    }
}
