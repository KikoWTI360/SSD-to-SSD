import Foundation

enum TransferPhase: String, Sendable {
    case idle
    case preparing
    case scanning
    case copying
    case verifying
    case finalizing
    case completed
    case cancelled
    case failed

    var title: String {
        L("phase.\(rawValue)")
    }

    /// Phases where a byte-accurate percentage is meaningless (we don't yet know the total).
    var isIndeterminate: Bool {
        self == .preparing || self == .scanning
    }

    var isActive: Bool {
        switch self {
        case .preparing, .scanning, .copying, .verifying, .finalizing: true
        case .idle, .completed, .cancelled, .failed: false
        }
    }
}

/// Raw counters owned by the engine and read atomically by the UI.
struct TransferCounters: Sendable {
    var phase: TransferPhase = .idle

    // Discovered during the scan pass.
    var totalFiles = 0
    var totalDirectories = 0
    var totalSymlinks = 0
    var totalBytes: Int64 = 0

    // Live scan feedback (before totals are known).
    var scannedEntries = 0

    // Copy pass. `processedBytes` includes copied + skipped + failed so the bar always reaches 100 %.
    var processedFiles = 0
    var processedBytes: Int64 = 0
    var copiedFiles = 0
    var copiedBytes: Int64 = 0
    var skippedFiles = 0
    var skippedBytes: Int64 = 0
    var failedFiles = 0

    // Verify pass.
    var verifiedFiles = 0
    var verifiedBytes: Int64 = 0
    var mismatchedFiles = 0

    var currentItem = ""
    var issueCount = 0
}

/// UI-facing snapshot: counters plus everything derived (rates, ETA, fractions).
struct TransferProgress: Sendable {
    var counters = TransferCounters()
    var elapsed: TimeInterval = 0
    /// Smoothed write throughput, bytes/s. Zero until enough samples exist.
    var copyRate: Double = 0
    /// Smoothed verification throughput expressed in source bytes/s.
    var verifyRate: Double = 0
    /// Seconds remaining across all remaining phases, `nil` while unknown.
    var eta: TimeInterval?
    /// 0…1 across the whole job, time-weighted so the copy and verify phases advance realistically.
    var overallFraction: Double = 0
    /// 0…1 within the current phase.
    var phaseFraction: Double = 0

    var phase: TransferPhase { counters.phase }
}
