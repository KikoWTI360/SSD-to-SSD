import Foundation

/// Throughput estimator over a sliding time window, with exponential smoothing on top.
///
/// Used for the **speed readout only**. A responsive number is what the user wants to see there,
/// and its jitter is harmless — unlike in the progress bar, where it used to be poison.
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
        guard total.isFinite, time.isFinite else { return }
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
        guard instant.isFinite else { return }
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
/// Two rules earned the hard way:
///
/// 1. **The progress bar must not depend on speed.** The first version weighted each phase by
///    `bytes / current rate`, so the rate appeared in both the numerator and the denominator
///    without cancelling: when the drive slowed down the percentage went *backwards*. Phase
///    weights are now fixed constants, and the result is additionally clamped to a high-water
///    mark, so the bar can only ever move forward.
///
/// 2. **The ETA uses the running average of the current phase, not the sliding window.** A
///    momentary dip in a 6-second window once turned a 20-hour estimate into 866 hours. A
///    cumulative average converges instead of spiking.
struct ProgressCalculator {

    // Sliding-window estimators, for the speed readout only.
    private var copyRate = RateEstimator()
    private var verifyRate = RateEstimator()

    // Phase tracking, for the ETA's cumulative average.
    private var phase: TransferPhase = .idle
    private var phaseStartElapsed: TimeInterval = 0
    private var phaseStartBytes: Double = 0
    private var phaseStartFiles: Double = 0

    private var smoothedETA: Double?
    /// A progress bar that goes backwards is worse than one that is slightly wrong.
    private var highWaterFraction: Double = 0

    /// Cost of verifying a byte relative to writing it. Verification reads both sides without
    /// writing, which in practice lands close to the cost of the copy itself.
    private let checksumWeight = 1.0
    /// The quick pass only stats files: nearly free next to moving the data.
    private let quickWeight = 0.02
    /// Assumed read/write ratio, used to price the verify phase before it has begun.
    private let assumedVerifyToCopyRatio = 1.4
    /// An average needs a couple of seconds of history before it means anything.
    private let minimumPhaseDuration: TimeInterval = 2

    mutating func reset() {
        copyRate.reset()
        verifyRate.reset()
        phase = .idle
        phaseStartElapsed = 0
        phaseStartBytes = 0
        phaseStartFiles = 0
        smoothedETA = nil
        highWaterFraction = 0
    }

    mutating func update(counters: TransferCounters,
                         verification: VerificationMode,
                         mode: TransferMode,
                         elapsed: TimeInterval) -> TransferProgress {
        trackPhase(counters: counters, elapsed: elapsed)

        // Each estimator is fed only while its own phase runs. An idle estimator would keep
        // averaging in zeros and decay towards zero, and a decayed rate used as a divisor
        // overflows to infinity — which is how a NaN once reached `Fmt.percent` and killed
        // the process.
        switch counters.phase {
        case .copying:
            copyRate.record(total: Double(counters.processedBytes), at: elapsed)
        case .verifying:
            verifyRate.record(total: Double(counters.verifiedBytes), at: elapsed)
        default:
            break
        }

        var progress = TransferProgress()
        progress.counters = counters
        progress.elapsed = elapsed
        progress.copyRate = copyRate.rate
        progress.verifyRate = verifyRate.rate
        progress.overallFraction = overallFraction(counters: counters,
                                                   verification: verification,
                                                   mode: mode)
        progress.phaseFraction = phaseFraction(counters: counters, overall: progress.overallFraction)
        progress.eta = estimateRemaining(counters: counters,
                                         verification: verification,
                                         mode: mode,
                                         elapsed: elapsed)
        return progress
    }

    // MARK: - Phase tracking

    private mutating func trackPhase(counters: TransferCounters, elapsed: TimeInterval) {
        guard counters.phase != phase else { return }
        phase = counters.phase
        phaseStartElapsed = elapsed
        phaseStartBytes = counters.phase == .verifying
            ? Double(counters.verifiedBytes)
            : Double(counters.processedBytes)
        phaseStartFiles = Double(counters.verifiedFiles)
    }

    // MARK: - Progress

    /// Fixed weights, so the fraction depends only on how much work is done — never on how fast
    /// it is going.
    private mutating func overallFraction(counters: TransferCounters,
                                          verification: VerificationMode,
                                          mode: TransferMode) -> Double {
        let totalBytes = Double(counters.totalBytes)
        let totalFiles = Double(counters.totalFiles)

        let copyWork = mode.writesToDestination ? totalBytes : 0
        let verifyWork: Double = switch verification {
        case .none: 0
        case .quick: totalBytes * quickWeight
        case .checksum: totalBytes * checksumWeight
        }

        let copyDone = mode.writesToDestination ? Double(counters.processedBytes) : 0
        let verifyDone: Double = switch verification {
        case .none:
            0
        case .quick:
            // The quick pass is measured in files, so scale its file progress onto its weight.
            totalFiles > 0 ? Double(counters.verifiedFiles) / totalFiles * verifyWork : 0
        case .checksum:
            Double(counters.verifiedBytes) * checksumWeight
        }

        let totalWork = copyWork + verifyWork
        guard totalWork > 0, totalWork.isFinite else { return highWaterFraction }

        let raw = Fmt.clampFraction((copyDone + verifyDone) / totalWork)
        highWaterFraction = max(highWaterFraction, raw)

        if counters.phase == .completed {
            highWaterFraction = 1
        }
        return highWaterFraction
    }

    private func phaseFraction(counters: TransferCounters, overall: Double) -> Double {
        switch counters.phase {
        case .copying:
            return counters.totalBytes > 0
                ? Fmt.clampFraction(Double(counters.processedBytes) / Double(counters.totalBytes))
                : 0
        case .verifying:
            return counters.totalFiles > 0
                ? Fmt.clampFraction(Double(counters.verifiedFiles) / Double(counters.totalFiles))
                : 0
        case .completed:
            return 1
        default:
            return overall
        }
    }

    // MARK: - ETA

    private mutating func estimateRemaining(counters: TransferCounters,
                                            verification: VerificationMode,
                                            mode: TransferMode,
                                            elapsed: TimeInterval) -> TimeInterval? {
        switch counters.phase {
        case .completed, .cancelled, .failed:
            return 0
        case .idle, .preparing, .scanning:
            // The total is still unknown, so any number here would be a lie.
            return nil
        case .copying, .verifying, .finalizing:
            break
        }

        let inPhase = elapsed - phaseStartElapsed
        guard inPhase >= minimumPhaseDuration else { return smoothedETA }

        let remaining: Double
        switch counters.phase {
        case .verifying:
            let done = Double(counters.verifiedBytes) - phaseStartBytes
            let doneFiles = Double(counters.verifiedFiles) - phaseStartFiles
            switch verification {
            case .none:
                remaining = 0
            case .quick:
                guard doneFiles > 0 else { return smoothedETA }
                let filesPerSecond = doneFiles / inPhase
                remaining = Double(max(0, counters.totalFiles - counters.verifiedFiles)) / filesPerSecond
            case .checksum:
                guard done > 0 else { return smoothedETA }
                let bytesPerSecond = done / inPhase
                remaining = Double(max(0, counters.totalBytes - counters.verifiedBytes)) / bytesPerSecond
            }

        default:
            // Still copying: price the remaining bytes, then add the verification still to come.
            let done = Double(counters.processedBytes) - phaseStartBytes
            guard done > 0 else { return smoothedETA }
            let bytesPerSecond = done / inPhase
            let remainingCopy = Double(max(0, counters.totalBytes - counters.processedBytes)) / bytesPerSecond
            let verifyRateGuess = bytesPerSecond * assumedVerifyToCopyRatio
            let remainingVerify: Double = switch verification {
            case .none: 0
            case .quick: Double(counters.totalBytes) * quickWeight / bytesPerSecond
            case .checksum: Double(counters.totalBytes) / verifyRateGuess
            }
            remaining = remainingCopy + remainingVerify
        }

        guard remaining.isFinite, remaining >= 0 else { return smoothedETA }

        // Smooth the ETA itself: users read this number continuously and hate it bouncing.
        // It may fall freely but is damped on the way up, because a rising estimate is usually a
        // transient stall rather than a real change of pace.
        let previous = smoothedETA ?? remaining
        let smoothed = remaining < previous
            ? previous * 0.6 + remaining * 0.4
            : previous * 0.85 + remaining * 0.15
        smoothedETA = smoothed
        return smoothed
    }
}
