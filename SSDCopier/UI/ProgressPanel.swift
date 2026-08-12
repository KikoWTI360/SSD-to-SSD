import SwiftUI

/// The loader: ring, ETA, throughput and a per-phase bar.
struct ProgressPanel: View {
    let progress: TransferProgress
    let isPaused: Bool

    private var counters: TransferCounters { progress.counters }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 24) {
                ProgressRing(fraction: progress.overallFraction,
                             indeterminate: progress.phase.isIndeterminate,
                             paused: isPaused,
                             phaseTitle: isPaused ? L("status.paused") : progress.phase.title)
                    .frame(width: 168, height: 168)

                VStack(alignment: .leading, spacing: 16) {
                    remaining
                    stats
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            phaseBar
            currentItem
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18))
        )
    }

    private var remaining: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("progress.remaining"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(isPaused ? L("status.paused") : Fmt.eta(progress.eta))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: progress.eta)
        }
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading,
                  spacing: 14) {
            StatTile(label: L("progress.speed"), value: Fmt.rate(activeRate))
            StatTile(label: L("progress.elapsed"), value: Fmt.duration(progress.elapsed))
            StatTile(label: L("progress.completed"), value: Fmt.percent(progress.overallFraction))
            StatTile(label: L("progress.data"), value: dataValue)
            StatTile(label: L("progress.files"), value: filesValue)
            StatTile(label: L("progress.issues"),
                     value: counters.issueCount == 0 ? L("progress.noIssues") : Fmt.count(counters.issueCount),
                     tint: counters.issueCount == 0 ? .primary : .orange)
        }
    }

    private var activeRate: Double {
        progress.phase == .verifying ? progress.verifyRate : progress.copyRate
    }

    private var dataValue: String {
        if progress.phase == .verifying {
            return "\(Fmt.bytes(counters.verifiedBytes)) / \(Fmt.bytes(counters.totalBytes))"
        }
        if progress.phase.isIndeterminate {
            return Fmt.bytes(counters.totalBytes)
        }
        return "\(Fmt.bytes(counters.processedBytes)) / \(Fmt.bytes(counters.totalBytes))"
    }

    private var filesValue: String {
        if progress.phase == .scanning {
            return Fmt.count(counters.scannedEntries)
        }
        let done = progress.phase == .verifying ? counters.verifiedFiles : counters.processedFiles
        return "\(Fmt.count(done)) / \(Fmt.count(counters.totalFiles))"
    }

    private var phaseBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(phaseDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !progress.phase.isIndeterminate {
                    Text(Fmt.percent(progress.phaseFraction))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if progress.phase.isIndeterminate {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView(value: progress.phaseFraction)
                    .progressViewStyle(.linear)
                    .animation(.easeOut(duration: 0.3), value: progress.phaseFraction)
            }
        }
    }

    private var phaseDescription: String {
        switch progress.phase {
        case .scanning:
            L("phase.desc.scanning", Fmt.count(counters.scannedEntries))
        case .copying:
            L("phase.desc.copying")
        case .verifying:
            L("phase.desc.verifying")
        case .finalizing:
            L("phase.desc.finalizing")
        default:
            progress.phase.title
        }
    }

    @ViewBuilder
    private var currentItem: some View {
        if !counters.currentItem.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(Fmt.shortPath(counters.currentItem, max: 90))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

struct ProgressRing: View {
    let fraction: Double
    let indeterminate: Bool
    let paused: Bool
    let phaseTitle: String

    @State private var spin = false

    /// A NaN reaching `trim(from:to:)` produces an invalid CoreGraphics path, so the value is
    /// sanitised here too rather than trusting the caller.
    private var safeFraction: Double { Fmt.clampFraction(fraction) }

    private var gradient: AngularGradient {
        AngularGradient(colors: paused ? [.orange, .yellow] : [.blue, .cyan, .green],
                        center: .center)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 16)

            if indeterminate {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(gradient, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 270 : -90))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            } else {
                Circle()
                    .trim(from: 0, to: max(0.002, safeFraction))
                    .stroke(gradient, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: safeFraction)
            }

            VStack(spacing: 2) {
                if indeterminate {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(Fmt.percent(safeFraction))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: safeFraction)
                }
                Text(phaseTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phaseTitle)
        .accessibilityValue(indeterminate ? L("progress.inProgress") : Fmt.percent(safeFraction))
    }
}
