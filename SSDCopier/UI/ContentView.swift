import SwiftUI

struct ContentView: View {
    @Bindable var controller: TransferController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    disks
                    if controller.isRunning || controller.report != nil {
                        ProgressPanel(progress: controller.progress, isPaused: controller.isPaused)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    OptionsPanel(options: $controller.options, isLocked: controller.isRunning)
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.25), value: controller.isRunning)
            }
            .onChange(of: controller.options) { _, _ in
                controller.persistOptions()
            }

            Divider()
            footer
        }
        .frame(minWidth: 880, minHeight: 660)
        .sheet(item: $controller.report) { report in
            ReportSheet(report: report) { controller.dismissReport() }
        }
        .alert("Impossibile iniziare", isPresented: alertBinding) {
            Button("OK", role: .cancel) { controller.alertMessage = nil }
        } message: {
            Text(controller.alertMessage ?? "")
        }
        .alert(controller.confirmation?.title ?? "",
               isPresented: confirmationBinding,
               presenting: controller.confirmation) { confirmation in
            Button(confirmation.confirmTitle) { controller.confirmStart() }
            Button("Annulla", role: .cancel) { controller.confirmation = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Copia da SSD a SSD")
                    .font(.title2.weight(.semibold))
                Text("Copia integrale con verifica e tempo rimanente calcolato")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                controller.refreshVolumes()
            } label: {
                Label("Aggiorna dischi", systemImage: "arrow.clockwise")
            }
            .help("Rileggi l'elenco dei volumi collegati")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var disks: some View {
        HStack(alignment: .center, spacing: 12) {
            DiskCard(role: .source,
                     selection: controller.source,
                     volumes: controller.volumes,
                     isEnabled: !controller.isRunning,
                     onChoose: { controller.chooseSource(startingAt: $0) },
                     onReveal: { if let url = controller.source?.url { controller.revealInFinder(url) } })

            VStack(spacing: 8) {
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Button {
                    controller.swapSelections()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Inverti origine e destinazione")
                .disabled(controller.isRunning)
            }
            .frame(width: 44)

            DiskCard(role: .destination,
                     selection: controller.destination,
                     volumes: controller.volumes,
                     isEnabled: !controller.isRunning,
                     onChoose: { controller.chooseDestination(startingAt: $0) },
                     onReveal: { if let url = controller.destination?.url { controller.revealInFinder(url) } })
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            statusLine
            Spacer()

            if controller.isRunning {
                Button(controller.isPaused ? "Riprendi" : "Pausa") {
                    controller.togglePause()
                }
                Button("Annulla", role: .destructive) {
                    controller.cancel()
                }
            }

            Button {
                controller.requestStart()
            } label: {
                Label("Avvia copia", systemImage: "play.fill")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canStart)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusLine: some View {
        if controller.isRunning {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(controller.isPaused ? "In pausa" : controller.progress.phase.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if controller.source == nil || controller.destination == nil {
            Text("Seleziona il disco di origine e quello di destinazione.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("Pronto: verifica \(controller.options.verification.title.lowercased()).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private var alertBinding: Binding<Bool> {
        Binding(get: { controller.alertMessage != nil },
                set: { if !$0 { controller.alertMessage = nil } })
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { controller.confirmation != nil },
                set: { if !$0 { controller.confirmation = nil } })
    }
}

#Preview {
    ContentView(controller: TransferController())
}
