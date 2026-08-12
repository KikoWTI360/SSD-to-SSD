import Foundation

/// How the destination is checked against the source once the data has been written.
enum VerificationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// No verification at all — fastest, least safe.
    case none
    /// Compares size and modification date of every file. Cheap, catches truncated copies.
    case quick
    /// Re-reads source and destination bypassing the unified buffer cache and compares SHA-256.
    case checksum

    var id: String { rawValue }

    var title: String {
        L("verify.\(rawValue).title")
    }

    var subtitle: String {
        L("verify.\(rawValue).subtitle")
    }
}

/// What a run actually does. Not a persisted preference — it is chosen per run, by which
/// button the user presses.
enum TransferMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Scan, copy, then verify.
    case copyAndVerify
    /// Verify an existing copy without writing anything. Recovers from an interrupted transfer.
    case verifyOnly

    var id: String { rawValue }

    var title: String { L("mode.\(rawValue).title") }

    var writesToDestination: Bool { self == .copyAndVerify }
}

/// User-tunable knobs for a transfer. Persisted in `UserDefaults` between launches.
struct TransferOptions: Codable, Equatable, Sendable {
    var verification: VerificationMode = .checksum
    /// Skip files already present in the destination with identical size and modification date.
    var skipIdenticalFiles = true
    /// Skip `.Spotlight-V100`, `.fseventsd`, `.Trashes`, `$RECYCLE.BIN`, …
    var excludeSystemFiles = true
    /// Skip `.DS_Store`.
    var excludeDSStore = false
    /// Copy permissions, ACLs, extended attributes and timestamps via `copyfile(3)`.
    var preserveMetadata = true
    /// Nest the copy inside `<destination>/<nome volume origine>` instead of merging into the root.
    var copyIntoNamedSubfolder = false
    /// Keep going after a file-level failure instead of aborting the whole transfer.
    var continueOnError = true
    /// Number of files copied concurrently. SSDs like 2–4; more rarely helps.
    var parallelWorkers = 3
    /// Read/write chunk size in MiB.
    var bufferSizeMB = 4
    /// Files at least this large (MiB) are copied with `F_NOCACHE` to avoid thrashing the page cache.
    var bypassCacheThresholdMB = 32

    static let workerRange = 1...8
    static let bufferRange = [1, 2, 4, 8, 16]

    var bufferSizeBytes: Int { max(1, bufferSizeMB) * 1024 * 1024 }
    var bypassCacheThresholdBytes: Int64 { Int64(max(0, bypassCacheThresholdMB)) * 1024 * 1024 }

    // MARK: - Persistence

    private static let defaultsKey = "TransferOptions.v1"

    static func load() -> TransferOptions {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(TransferOptions.self, from: data)
        else { return TransferOptions() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

/// Names that are never worth copying between volumes: they are rebuilt by macOS/Windows on demand.
enum ExcludedNames {
    static let system: Set<String> = [
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        ".apdisk",
        ".PKInstallSandboxManager",
        ".PKInstallSandboxManager-SystemSoftware",
        "System Volume Information",
        "$RECYCLE.BIN",
    ]
}
