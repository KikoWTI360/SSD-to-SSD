import Foundation

/// Throughput estimator over a sliding time window, with exponential smoothing on top.
///
/// A plain "total bytes / elapsed" average is useless for an ETA: it reacts far too slowly when the
/// drive changes speed (SLC cache exhaustion, a run of tiny files, thermal throttling). The sliding
/// window keeps the estimate responsive, the EWMA keeps the label from jittering every tick.
struct RateEstimator {
    private struct Sample {
        let time: TimeInterval
        let value: Double
    }

    private var samples: [Sample] = []
    private var smoothed: Double = 0
    private let window: TimeInterval
    private let smoothing: Double

    init(window: TimeInterval = 6, smoothing: Double = 0.25) {
        self.window = window
        self.smoothing = smoothing
    }

    /// Feed the running total (bytes or files). Deltas are derived internally.
    mutating func record(total: Double, at time: TimeInterval) {
        samples.append(Sample(time: time, value: total))

        let cutoff = time - window
        if let lastStale = samples.lastIndex(where: { $0.time < cutoff }), lastStale > 0 {
            samples.removeFirst(lastStale)
        }

        guard let first = samples.first, let last = samples.last else { return }
        let dt = last.time - first.time
        let dv = last.value - first.value
        // Need a bit of history before the instantaneous rate means anything.
        guard dt >= 0.5, dv >= 0 else { return }

        let instant = dv / dt
        smoothed = smoothed == 0 ? instant : smoothed * (1 - smoothing) + instant * smoothing
    }

    /// Units per second, or 0 when not enough data has been collected yet.
    var rate: Double { smoothed }

    var hasEstimate: Bool { smoothed > 0 }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        smoothed = 0
    }
}

/// Turns raw counters into the ETA and the two progress fractions shown by the loader.
///
/// Copy and verify move at different speeds, so a byte-based bar would visibly stall when the
/// verification pass starts. Instead both phases are converted to *estimated seconds* and the
/// overall bar shows the fraction of total time consumed.
struct ProgressCalculator {
    private var copyRate = RateEstimator()
    private var verifyRate = RateEstimator()
    private var quickVerifyRate = RateEstimator()
    private var smoothedETA: Double?

    /// Assumed read/write ratio before either phase has produced a measurement.
    private let assumedVerifyToCopyRatio = 1.4
    /// Fallback throughput (200 MB/s) used only to weight the bar before any sample exists.
    private let fallbackCopyRate: Double = 200 * 1024 * 1024
    /// Rough files/s for the metadata-only verification pass.
    private let fallbackQuickVerifyRate: Double = 1500

    mutating func reset() {
        copyRate.reset()
        verifyRate.reset()
        quickVerifyRate.reset()
        smoothedETA = nil
    }

    mutating func update(counters: TransferCounters,
                         verification: VerificationMode,
                         mode: TransferMode,
                         elapsed: TimeInterval) -> TransferProgress {
        copyRate.record(total: Double(counters.processedBytes), at: elapsed)
        switch verification {
        case .checksum:
            verifyRate.record(total: Double(counters.verifiedBytes), at: elapsed)
        case .quick:
            quickVerifyRate.record(total: Double(counters.verifiedFiles), at: elapsed)
        case .none:
            break
        }

        var progress = TransferProgress()
        progress.counters = counters
        progress.elapsed = elapsed
        progress.copyRate = copyRate.rate
        progress.verifyRate = verifyRate.rate

        let effectiveCopyRate = copyRate.hasEstimate ? copyRate.rate : fallbackCopyRate
        let effectiveVerifyRate = verifyRate.hasEstimate
            ? verifyRate.rate
            : effectiveCopyRate * assumedVerifyToCopyRatio
        let effectiveQuickRate = quickVerifyRate.hasEstimate ? quickVerifyRate.rate : fallbackQuickVerifyRate

        // Total cost of each phase, expressed in seconds. A verify-only run has no copy phase,
        // so charging it for one would peg the bar near zero for the whole job.
        let copyCost = mode.writesToDestination ? Double(counters.totalBytes) / effectiveCopyRate : 0
        let verifyCost: Double = switch verification {
        case .none: 0
        case .quick: Double(counters.totalFiles) / effectiveQuickRate
        case .checksum: Double(counters.totalBytes) / effectiveVerifyRate
        }

        let copyDone = mode.writesToDestination ? Double(counters.processedBytes) / effectiveCopyRate : 0
        let verifyDone: Double = switch verification {
        case .none: 0
        case .quick: Double(counters.verifiedFiles) / effectiveQuickRate
        case .checksum: Double(counters.verifiedBytes) / effectiveVerifyRate
        }

        let totalCost = copyCost + verifyCost
        if totalCost > 0 {
            progress.overallFraction = min(max((copyDone + verifyDone) / totalCost, 0), 1)
        }

        switch counters.phase {
        case .copying:
            progress.phaseFraction = counters.totalBytes > 0
                ? min(max(Double(counters.processedBytes) / Double(counters.totalBytes), 0), 1)
                : 0
        case .verifying:
            let done = Double(counters.verifiedFiles)
            let total = Double(counters.totalFiles)
            progress.phaseFraction = total > 0 ? min(max(done / total, 0), 1) : 0
        case .completed:
            progress.phaseFraction = 1
            progress.overallFraction = 1
        default:
            progress.phaseFraction = progress.overallFraction
        }

        progress.eta = estimateRemaining(counters: counters,
                                         verification: verification,
                                         mode: mode,
                                         copyBytesPerSecond: effectiveCopyRate,
                                         verifyBytesPerSecond: effectiveVerifyRate,
                                         quickFilesPerSecond: effectiveQuickRate)
        return progress
    }

    private mutating func estimateRemaining(counters: TransferCounters,
                                            verification: VerificationMode,
                                            mode: TransferMode,
                                            copyBytesPerSecond: Double,
                                            verifyBytesPerSecond: Double,
                                            quickFilesPerSecond: Double) -> TimeInterval? {
        switch counters.phase {
        case .completed, .cancelled, .failed:
            return 0
        case .idle, .preparing, .scanning:
            // The total is still unknown, so any number here would be a lie.
            return nil
        case .copying, .verifying, .finalizing:
            break
        }

        // Nothing measured yet — don't show a wildly wrong first guess.
        guard copyRate.hasEstimate || counters.phase == .verifying else { return nil }

        let remainingCopyBytes = mode.writesToDestination
            ? max(0, counters.totalBytes - counters.processedBytes)
            : 0
        let remainingCopy = Double(remainingCopyBytes) / max(copyBytesPerSecond, 1)

        let remainingVerify: Double = switch verification {
        case .none:
            0
        case .quick:
            Double(max(0, counters.totalFiles - counters.verifiedFiles)) / max(quickFilesPerSecond, 1)
        case .checksum:
            Double(max(0, counters.totalBytes - counters.verifiedBytes)) / max(verifyBytesPerSecond, 1)
        }

        let raw = remainingCopy + remainingVerify
        guard raw.isFinite else { return nil }

        // Smooth the ETA itself: users read this number continuously and hate it bouncing.
        let previous = smoothedETA ?? raw
        // Let it fall freely, damp it on the way up — a rising ETA is usually a transient stall.
        let smoothed = raw < previous ? previous * 0.6 + raw * 0.4 : previous * 0.85 + raw * 0.15
        smoothedETA = smoothed
        return smoothed
    }
}
