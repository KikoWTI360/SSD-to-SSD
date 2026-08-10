import AppKit
import SwiftUI

@main
struct SSDCopierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = TransferController()

    var body: some Scene {
        Window("Copia da SSD a SSD", id: "main") {
            ContentView(controller: controller)
                .onAppear { appDelegate.controller = controller }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Replaces the useless "New / Open" group: this app has no documents.
            CommandGroup(replacing: .newItem) {
                Button("Avvia copia") { controller.requestStart() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!controller.canStart)

                Button("Aggiorna dischi") { controller.refreshVolumes() }
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
        alert.messageText = "Copia in corso"
        alert.informativeText = "Uscire adesso lascerà la destinazione incompleta. Vuoi interrompere il trasferimento e uscire?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Interrompi ed esci")
        alert.addButton(withTitle: "Continua la copia")

        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        controller.cancel()
        BookmarkStore.releaseAll()
        return .terminateNow
    }
}
