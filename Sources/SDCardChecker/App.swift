import SwiftUI

@main
struct SDCardCheckerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var drives = DriveManager()
    @StateObject private var runner = TestRunner()

    var body: some Scene {
        WindowGroup("SD Card Checker") {
            ContentView()
                .environmentObject(drives)
                .environmentObject(runner)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
