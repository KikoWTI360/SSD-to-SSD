import Foundation

struct TransferIssue: Identifiable, Sendable {
    enum Severity: String, Sendable {
        case warning
        case error

        var label: String {
            switch self {
            case .warning: "Avviso"
            case .error: "Errore"
            }
        }

        var symbol: String {
            switch self {
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    let id = UUID()
    let path: String
    let message: String
    let severity: Severity
}

struct TransferReport: Identifiable, Sendable {
    let id = UUID()

    enum Outcome: String, Sendable {
        case completed
        case completedWithIssues
        case cancelled
        case failed

        var title: String {
            switch self {
            case .completed: "Copia completata e verificata"
            case .completedWithIssues: "Completata con avvisi"
            case .cancelled: "Copia annullata"
            case .failed: "Copia interrotta"
            }
        }

        var symbol: String {
            switch self {
            case .completed: "checkmark.seal.fill"
            case .completedWithIssues: "exclamationmark.triangle.fill"
            case .cancelled: "stop.circle.fill"
            case .failed: "xmark.octagon.fill"
            }
        }
    }

    var outcome: Outcome = .completed
    var counters = TransferCounters()
    var issues: [TransferIssue] = []
    var startedAt = Date()
    var finishedAt = Date()
    var sourcePath = ""
    var destinationPath = ""
    var verification: VerificationMode = .checksum
    /// Set when the transfer aborted before finishing.
    var fatalMessage: String?

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    var averageRate: Double {
        guard duration > 0 else { return 0 }
        return Double(counters.copiedBytes) / duration
    }

    /// Plain-text log, used by "Copia negli appunti" and by the export panel.
    func plainText() -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium

        var lines: [String] = []
        lines.append("SSD Copier — rapporto di trasferimento")
        lines.append(String(repeating: "=", count: 46))
        lines.append("Esito:          \(outcome.title)")
        if let fatalMessage { lines.append("Motivo:         \(fatalMessage)") }
        lines.append("Origine:        \(sourcePath)")
        lines.append("Destinazione:   \(destinationPath)")
        lines.append("Inizio:         \(df.string(from: startedAt))")
        lines.append("Fine:           \(df.string(from: finishedAt))")
        lines.append("Durata:         \(Fmt.duration(duration))")
        lines.append("Verifica:       \(verification.title)")
        lines.append("")
        lines.append("Cartelle:       \(counters.totalDirectories)")
        lines.append("File totali:    \(counters.totalFiles)")
        lines.append("Link simbolici: \(counters.totalSymlinks)")
        lines.append("Copiati:        \(counters.copiedFiles) (\(Fmt.bytes(counters.copiedBytes)))")
        lines.append("Saltati:        \(counters.skippedFiles) (\(Fmt.bytes(counters.skippedBytes)))")
        lines.append("Non riusciti:   \(counters.failedFiles)")
        if verification != .none {
            lines.append("Verificati:     \(counters.verifiedFiles) (\(Fmt.bytes(counters.verifiedBytes)))")
            lines.append("Discordanti:    \(counters.mismatchedFiles)")
        }
        lines.append("Velocità media: \(Fmt.rate(averageRate))")

        if !issues.isEmpty {
            lines.append("")
            lines.append("Problemi (\(issues.count))")
            lines.append(String(repeating: "-", count: 46))
            for issue in issues {
                lines.append("[\(issue.severity.label)] \(issue.path.isEmpty ? "—" : issue.path)")
                lines.append("    \(issue.message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
