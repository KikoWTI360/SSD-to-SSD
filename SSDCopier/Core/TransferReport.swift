import Foundation

struct TransferIssue: Identifiable, Sendable {
    enum Severity: String, Sendable {
        case warning
        case error

        var label: String {
            L("issue.\(rawValue)")
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
            L("outcome.\(rawValue)")
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
    var mode: TransferMode = .copyAndVerify
    /// Set when the transfer aborted before finishing.
    var fatalMessage: String?

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    var averageRate: Double {
        guard duration > 0 else { return 0 }
        return Double(counters.copiedBytes) / duration
    }

    /// Plain-text log, used by "copy to clipboard" and by the export panel.
    func plainText() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        var rows: [(String, String)] = [
            (L("report.outcome"), outcome.title),
        ]
        if let fatalMessage {
            rows.append((L("report.reason"), fatalMessage))
        }
        rows.append(contentsOf: [
            (L("report.source"), sourcePath),
            (L("report.destination"), destinationPath),
            (L("report.start"), formatter.string(from: startedAt)),
            (L("report.end"), formatter.string(from: finishedAt)),
            (L("report.duration"), Fmt.duration(duration)),
            (L("report.mode"), mode.title),
            (L("report.verification"), verification.title),
            ("", ""),
            (L("report.folders"), Fmt.count(counters.totalDirectories)),
            (L("report.totalFiles"), Fmt.count(counters.totalFiles)),
            (L("report.symlinks"), Fmt.count(counters.totalSymlinks)),
            (L("report.copied"), "\(Fmt.count(counters.copiedFiles)) (\(Fmt.bytes(counters.copiedBytes)))"),
            (L("report.skipped"), "\(Fmt.count(counters.skippedFiles)) (\(Fmt.bytes(counters.skippedBytes)))"),
            (L("report.failed"), Fmt.count(counters.failedFiles)),
        ])
        if verification != .none {
            rows.append((L("report.verified"), "\(Fmt.count(counters.verifiedFiles)) (\(Fmt.bytes(counters.verifiedBytes)))"))
            rows.append((L("report.mismatched"), Fmt.count(counters.mismatchedFiles)))
        }
        rows.append((L("report.averageSpeed"), Fmt.rate(averageRate)))

        // Column width is measured, not hardcoded: label lengths differ per language.
        let width = rows.map { $0.0.count }.max() ?? 0

        var lines: [String] = []
        lines.append(L("report.title"))
        lines.append(String(repeating: "=", count: 46))
        for (label, value) in rows {
            if label.isEmpty && value.isEmpty {
                lines.append("")
            } else {
                let padded = label.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("\(padded)  \(value)")
            }
        }

        if !issues.isEmpty {
            lines.append("")
            lines.append(L("report.issues", Fmt.count(issues.count)))
            lines.append(String(repeating: "-", count: 46))
            for issue in issues {
                lines.append("[\(issue.severity.label)] \(issue.path.isEmpty ? "—" : issue.path)")
                lines.append("    \(issue.message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
