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
        return byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
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
