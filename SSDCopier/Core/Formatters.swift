import Foundation

enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, value))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        // `Int64(_: Double)` traps above `Int64.max`, so cap before converting.
        let capped = min(bytesPerSecond, 1e15)
        return byteFormatter.string(fromByteCount: Int64(capped)) + "/s"
    }

    /// Forces a value into 0…1, mapping NaN to 0.
    ///
    /// This exists because `Int(_: Double)` **traps** on NaN and infinity — it aborts the process
    /// rather than returning something wrong. Clamping alone is not enough: `min(max(nan, 0), 1)`
    /// is still NaN, since every comparison against NaN is false. Any fraction that reaches a
    /// formatter or a SwiftUI shape has to pass through here first.
    static func clampFraction(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(max(value, 0), 1)
    }

    static func percent(_ fraction: Double) -> String {
        let clamped = clampFraction(fraction)
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// Compact Italian duration: "48 s", "12 min 05 s", "2 h 07 min".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60

        if h > 0 {
            return String(format: "%d h %02d min", h, m)
        } else if m > 0 {
            return String(format: "%d min %02d s", m, s)
        } else {
            return "\(s) s"
        }
    }

    /// ETA rounded to a sensible granularity so the label stops flickering on long jobs.
    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return L("time.calculating") }
        if seconds < 5 { return L("time.fewSeconds") }
        let rounded: TimeInterval = if seconds > 3600 {
            (seconds / 60).rounded() * 60
        } else if seconds > 300 {
            (seconds / 30).rounded() * 30
        } else {
            seconds.rounded()
        }
        return duration(rounded)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// Middle-truncated path so both the volume and the file name stay visible.
    static func shortPath(_ path: String, max limit: Int = 72) -> String {
        guard path.count > limit else { return path }
        let head = path.prefix(limit / 3)
        let tail = path.suffix(limit - limit / 3 - 1)
        return "\(head)…\(tail)"
    }
}
