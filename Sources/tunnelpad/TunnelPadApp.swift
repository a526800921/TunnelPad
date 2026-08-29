import SwiftUI
import AppKit
import TunnelPadCore

@main
struct TunnelPadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("TunnelPad") {
            MainPanelView()
                .environmentObject(appDelegate.manager)
                .frame(minWidth: 620, minHeight: 380)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                Button("退出 TunnelPad") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}
