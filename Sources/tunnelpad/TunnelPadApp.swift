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
                .environmentObject(appDelegate)
                .frame(minWidth: 900, minHeight: 560)
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
