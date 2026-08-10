import AppKit
import SwiftUI

@main
struct SSDCopierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = TransferController()

    var body: some Scene {
        // Neutral window title: a Scene title is fixed for the process lifetime, so it must not
        // be a translated string. The localised title lives in the window's own header instead.
        Window("SSD Copier", id: "main") {
            ContentView(controller: controller)
                .onAppear { appDelegate.controller = controller }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Replaces the useless "New / Open" group: this app has no documents.
            CommandGroup(replacing: .newItem) {
                Button(L("action.start")) { controller.requestStart() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!controller.canStart)

                Button(L("action.refreshDisks")) { controller.refreshVolumes() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: TransferController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting mid-copy would leave a half-written file on the destination; make it deliberate.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.isRunning else {
            BookmarkStore.releaseAll()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = L("quit.title")
        alert.informativeText = L("quit.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("quit.stopAndQuit"))
        alert.addButton(withTitle: L("quit.continue"))

        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        controller.cancel()
        BookmarkStore.releaseAll()
        return .terminateNow
    }
}
