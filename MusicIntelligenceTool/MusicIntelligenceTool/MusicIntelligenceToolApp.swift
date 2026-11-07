import SwiftUI

@main
struct MusicIntelligenceToolApp: App {
    @State private var studio = Studio()
    @State private var page = AppPage.workspace
    var body: some Scene {
        Window("音乐分析工作台", id: "studio") {
            ContentView(studio: studio, page: $page)
                .task {
                    #if DEBUG
                    // Hosted unit tests create isolated Studio instances. The
                    // host window must not start a service on the user's library.
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
                    #endif
                    studio.startMCP()
                    if let path = ProcessInfo.processInfo.environment["MIT_OPEN_AUDIO"] {
                        do { try studio.open(URL(fileURLWithPath:path)) } catch { studio.notice=error.localizedDescription }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)) { _ in studio.stop() }
        }
        .defaultSize(width: 1080,height: 740)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { page = .settings }.keyboardShortcut(",")
            }
        }
    }
}
