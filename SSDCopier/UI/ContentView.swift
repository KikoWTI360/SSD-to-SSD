import SwiftUI

struct ContentView: View {
    @Bindable var controller: TransferController

    private var languageSetting: LanguageSetting { LanguageSetting.shared }

    var body: some View {
        // Reading the selection here registers the dependency; `.id` then forces a full rebuild
        // so every cached subview picks up the new strings instead of keeping the old ones.
        let language = languageSetting.selection

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
        .id(language)
        .frame(minWidth: 880, minHeight: 660)
        .sheet(item: $controller.report) { report in
            ReportSheet(report: report) { controller.dismissReport() }
        }
        .alert(L("alert.cannotStart"), isPresented: alertBinding) {
            Button(L("action.ok"), role: .cancel) { controller.alertMessage = nil }
        } message: {
            Text(controller.alertMessage ?? "")
        }
        .alert(controller.confirmation?.title ?? "",
               isPresented: confirmationBinding,
               presenting: controller.confirmation) { confirmation in
            Button(confirmation.confirmTitle) { controller.confirmStart() }
            Button(L("action.cancel"), role: .cancel) { controller.confirmation = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("app.title"))
                    .font(.title2.weight(.semibold))
                Text(L("app.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            languageMenu

            Button {
                controller.refreshVolumes()
            } label: {
                Label(L("action.refreshDisks"), systemImage: "arrow.clockwise")
            }
            .help(L("action.refreshDisks.help"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    languageSetting.select(language)
                } label: {
                    if language == languageSetting.selection {
                        Label(language.displayName, systemImage: "checkmark")
                    } else {
                        Text(language.displayName)
                    }
                }
            }
        } label: {
            Label(L("language.label"), systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("language.help"))
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
                .help(L("action.swap.help"))
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
                Button(controller.isPaused ? L("action.resume") : L("action.pause")) {
                    controller.togglePause()
                }
                Button(L("action.cancel"), role: .destructive) {
                    controller.cancel()
                }
            } else {
                Button {
                    controller.requestStart(mode: .verifyOnly)
                } label: {
                    Label(L("action.verifyOnly"), systemImage: "checkmark.shield")
                }
                .help(L("action.verifyOnly.help"))
                .disabled(!controller.canStart)
            }

            Button {
                controller.requestStart()
            } label: {
                Label(L("action.start"), systemImage: "play.fill")
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
                Text(controller.isPaused ? L("status.paused") : controller.progress.phase.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if controller.source == nil || controller.destination == nil {
            Text(L("status.selectDisks"))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if controller.report?.mode == .verifyOnly {
            Text(L("status.readyVerify", controller.options.verification.title.lowercased()))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text(L("status.ready", controller.options.verification.title.lowercased()))
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
