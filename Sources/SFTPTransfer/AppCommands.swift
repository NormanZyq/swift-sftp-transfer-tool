import SwiftUI

/// 菜单栏命令（连接 / 断开）。逐面板的增删改通过右键菜单与快捷键完成。
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button(L10n.tr("连接")) { model.connect() }
                .keyboardShortcut("k", modifiers: .command)
            Button(L10n.tr("断开连接")) { model.disconnect() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}
