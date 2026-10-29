import SwiftUI

/// Settings → Автопапки. Placeholder until the folder watcher is wired in.
struct AutoFoldersSettings: View {
    var body: some View {
        SettingsCard {
            Text("Скоро здесь можно будет выбрать папки, новые записи в которых Meteora обработает сама.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.secondary)
        }
    }
}
