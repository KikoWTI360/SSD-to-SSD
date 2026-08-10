import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReportSheet: View {
    let report: TransferReport
    var onDismiss: () -> Void

    private var tint: Color {
        switch report.outcome {
        case .completed: .green
        case .completedWithIssues: .orange
        case .cancelled: .secondary
        case .failed: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summary
                    if !report.issues.isEmpty { issues }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 540)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: report.outcome.symbol)
                .font(.system(size: 34))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(report.outcome.title)
                    .font(.title2.weight(.semibold))
                if let fatal = report.fatalMessage {
                    Text(fatal)
                        .font(.callout)
                        .foregroundStyle(.red)
                } else {
                    Text("\(Fmt.bytes(report.counters.copiedBytes)) in \(Fmt.duration(report.duration)) · media \(Fmt.rate(report.averageRate))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Riepilogo")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading,
                      spacing: 12) {
                StatTile(label: "File copiati",
                         value: "\(Fmt.count(report.counters.copiedFiles)) · \(Fmt.bytes(report.counters.copiedBytes))")
                StatTile(label: "File saltati",
                         value: "\(Fmt.count(report.counters.skippedFiles)) · \(Fmt.bytes(report.counters.skippedBytes))")
                StatTile(label: "Cartelle", value: Fmt.count(report.counters.totalDirectories))
                StatTile(label: "Link simbolici", value: Fmt.count(report.counters.totalSymlinks))
                StatTile(label: "Non riusciti",
                         value: Fmt.count(report.counters.failedFiles),
                         tint: report.counters.failedFiles > 0 ? .red : .primary)
                StatTile(label: "Verifica \(report.verification.title)",
                         value: verificationSummary,
                         tint: report.counters.mismatchedFiles > 0 ? .red : .primary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Origine") {
                        Text(report.sourcePath).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Destinazione") {
                        Text(report.destinationPath).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.caption)
                .padding(4)
            }
        }
    }

    private var verificationSummary: String {
        switch report.verification {
        case .none:
            "non eseguita"
        case .quick, .checksum:
            report.counters.mismatchedFiles == 0
                ? "\(Fmt.count(report.counters.verifiedFiles)) file OK"
                : "\(Fmt.count(report.counters.mismatchedFiles)) discordanti"
        }
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Problemi (\(report.issues.count))")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(report.issues.prefix(300)) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: issue.severity.symbol)
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                            .font(.caption)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(issue.path.isEmpty ? "—" : issue.path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    Divider()
                }

                if report.issues.count > 300 {
                    Text("… e altri \(report.issues.count - 300). Esporta il rapporto per l'elenco completo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
        }
    }

    private var footer: some View {
        HStack {
            Button("Copia negli appunti") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.plainText(), forType: .string)
            }
            Button("Esporta rapporto…", action: exportReport)
            Spacer()
            Button("Chiudi", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Rapporto copia SSD.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.plainText().write(to: url, atomically: true, encoding: .utf8)
    }
}
