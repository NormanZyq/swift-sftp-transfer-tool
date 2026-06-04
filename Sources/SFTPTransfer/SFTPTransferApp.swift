import SwiftUI

@main
struct SFTPTransferApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("SSH 文件传输") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            AppCommands(model: model)
        }
    }
}
