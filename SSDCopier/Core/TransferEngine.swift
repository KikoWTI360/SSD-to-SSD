import Foundation

/// Runs the whole job: scan → copy → verify → finalize.
///
/// Everything happens on GCD queues with blocking I/O; the UI only ever reads `snapshot()`.
final class TransferEngine: @unchecked Sendable {

    struct Request: Sendable {
        var source: URL
        var destination: URL
        var options: TransferOptions
    }

    private enum EntryKind {
        case directory
        case file
        case symlink
        case other
    }

    private struct WalkEntry {
        let kind: EntryKind
        let relativePath: String
        let sourcePath: String
        let size: Int64
        let linkCount: Int
    }

    private struct PendingItem {
        let entry: WalkEntry
        let destinationPath: String
    }

    // MARK: - State

    private let request: TransferEngine.Request
    private let gate = TransferGate()
    private let lock = NSLock()
    private var counters = TransferCounters()
    private var issues: [TransferIssue] = []
    private var fatalMessage: String?

    /// Relative paths of every directory created, in discovery order (parents first).
    private var createdDirectories: [String] = []
    /// "dev:ino" → first destination path, so hard-linked files stay linked on the copy.
    private var hardLinkMap: [String: String] = [:]

    private let bufferPool: BufferPool
    private let controlQueue = DispatchQueue(label: "com.ssdcopier.engine.control", qos: .userInitiated)
    private let workerQueue = DispatchQueue(label: "com.ssdcopier.engine.workers",
                                            qos: .userInitiated,
                                            attributes: .concurrent)
    private var activityToken: NSObjectProtocol?
    private var startedAt = Date()

    /// Files handed to the worker pool at a time. Bounded so memory stays flat on huge trees.
    private let batchSize = 256

    private var destinationRoot: URL {
        request.options.copyIntoNamedSubfolder
            ? request.destination.appendingPathComponent(request.source.lastPathComponent)
            : request.destination
    }

    init(request: TransferEngine.Request) {
        self.request = request
        self.bufferPool = BufferPool(size: request.options.bufferSizeBytes)
    }

    // MARK: - Control

    func snapshot() -> TransferCounters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    var isPaused: Bool { gate.isPaused }

    func pause() { gate.pause() }
    func resume() { gate.resume() }
    func cancel() { gate.cancel() }

    func start(completion: @escaping (TransferReport) -> Void) {
        controlQueue.async { [self] in
            let report = execute()
            DispatchQueue.main.async { completion(report) }
        }
    }

    // MARK: - Pipeline

    private func execute() -> TransferReport {
        startedAt = Date()
        // Keep the Mac awake: a 2 TB transfer easily outlives the idle sleep timer.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Copia e verifica tra SSD"
        )
        defer {
            if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) }
            activityToken = nil
            bufferPool.drain()
        }

        setPhase(.preparing)
        do {
            try validate()
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            return finish(with: error.localizedDescription)
        }

        setPhase(.scanning)
        scanSource()
        if gate.isCancelled { return finish(cancelled: true) }
        checkFreeSpace()
        if let fatalMessage { return finish(with: fatalMessage) }

        setPhase(.copying)
        runCopyPass()
        if gate.isCancelled { return finish(cancelled: true) }

        setPhase(.finalizing)
        applyDirectoryMetadata()

        if request.options.verification != .none {
            setPhase(.verifying)
            runVerifyPass()
            if gate.isCancelled { return finish(cancelled: true) }
        }

        return finish()
    }

    // MARK: - Validation

    private func validate() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: request.source.path, isDirectory: &isDir), isDir.boolValue else {
            throw TransferSetupError.message("La cartella di origine non esiste o non è più disponibile.")
        }
        guard fm.fileExists(atPath: request.destination.path, isDirectory: &isDir), isDir.boolValue else {
            throw TransferSetupError.message("La cartella di destinazione non esiste o non è più disponibile.")
        }

        let source = request.source.standardizedFileURL.resolvingSymlinksInPath().path
        let destination = request.destination.standardizedFileURL.resolvingSymlinksInPath().path

        if source == destination {
            throw TransferSetupError.message("Origine e destinazione coincidono.")
        }
        if isSubpath(destination, of: source) {
            throw TransferSetupError.message("La destinazione si trova dentro l'origine: la copia si ripeterebbe all'infinito.")
        }
        if isSubpath(source, of: destination) {
            throw TransferSetupError.message("L'origine si trova dentro la destinazione: la copia sovrascriverebbe i file originali.")
        }
        guard access(request.destination.fsPath, W_OK) == 0 else {
            throw TransferSetupError.message("La destinazione è in sola lettura o non è scrivibile.")
        }
    }

    private func isSubpath(_ candidate: String, of parent: String) -> Bool {
        let normalizedParent = parent.hasSuffix("/") ? parent : parent + "/"
        return candidate.hasPrefix(normalizedParent)
    }

    private func checkFreeSpace() {
        guard let volume = VolumeScanner.volume(containing: request.destination) else { return }
        let needed = snapshot().totalBytes
        guard needed > volume.availableCapacity else { return }

        let message = "Servono \(Fmt.bytes(needed)) ma sulla destinazione sono liberi \(Fmt.bytes(volume.availableCapacity))."
        if request.options.skipIdenticalFiles {
            // Files already present will be skipped, so the copy may still fit.
            record(issue: TransferIssue(path: request.destination.path,
                                        message: message + " Il trasferimento prosegue perché i file già identici verranno saltati.",
                                        severity: .warning))
        } else {
            lock.lock()
            fatalMessage = "Spazio insufficiente. " + message
            lock.unlock()
        }
    }

    // MARK: - Scan pass

    private func scanSource() {
        var files = 0
        var directories = 0
        var symlinks = 0
        var bytes: Int64 = 0
        var seen = 0

        walkSource { entry in
            seen += 1
            switch entry.kind {
            case .directory: directories += 1
            case .file:
                files += 1
                bytes += entry.size
            case .symlink: symlinks += 1
            case .other: break
            }

            // Batch the lock: the scan can visit hundreds of thousands of entries.
            if seen % 128 == 0 {
                self.mutate {
                    $0.scannedEntries = seen
                    $0.totalFiles = files
                    $0.totalDirectories = directories
                    $0.totalSymlinks = symlinks
                    $0.totalBytes = bytes
                    $0.currentItem = entry.relativePath
                }
            }
        }

        mutate {
            $0.scannedEntries = seen
            $0.totalFiles = files
            $0.totalDirectories = directories
            $0.totalSymlinks = symlinks
            $0.totalBytes = bytes
            $0.currentItem = ""
        }
    }

    // MARK: - Copy pass

    private func runCopyPass() {
        let destinationBase = destinationRoot.fsPath
        var batch: [PendingItem] = []
        batch.reserveCapacity(batchSize)

        walkSource { entry in
            guard self.gate.checkpoint() else { return }
            let destinationPath = destinationBase + "/" + entry.relativePath

            switch entry.kind {
            case .directory:
                // Directories are created inline: the enumerator is pre-order, so a parent always
                // exists before its children are queued.
                do {
                    try FileOps.makeDirectory(at: destinationPath)
                    self.lock.lock()
                    self.createdDirectories.append(entry.relativePath)
                    self.lock.unlock()
                } catch {
                    self.handle(error: error, path: entry.relativePath, fatalIfStrict: true)
                }

            case .file, .symlink:
                batch.append(PendingItem(entry: entry, destinationPath: destinationPath))
                if batch.count >= self.batchSize {
                    self.process(batch: batch)
                    batch.removeAll(keepingCapacity: true)
                }

            case .other:
                self.record(issue: TransferIssue(path: entry.relativePath,
                                                 message: "Tipo di file non supportato (socket, fifo o device): ignorato.",
                                                 severity: .warning))
            }
        }

        if !batch.isEmpty && !gate.isCancelled {
            process(batch: batch)
        }
    }

    private func process(batch: [PendingItem]) {
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: max(1, request.options.parallelWorkers))

        for item in batch {
            guard gate.checkpoint() else { break }
            semaphore.wait()
            workerQueue.async(group: group) { [self] in
                defer { semaphore.signal() }
                guard !gate.isCancelled else { return }
                copy(item)
            }
        }
        group.wait()
    }

    private func copy(_ item: PendingItem) {
        let entry = item.entry
        mutate { $0.currentItem = entry.relativePath }
        // Bytes already added to `processedBytes` for this file, so a failure halfway through can
        // top up the remainder exactly once instead of double counting.
        var accountedBytes: Int64 = 0

        do {
            switch entry.kind {
            case .symlink:
                let target = try FileOps.readSymlink(at: entry.sourcePath)
                try FileOps.createSymlink(target: target, at: item.destinationPath)
                if request.options.preserveMetadata {
                    FileOps.applyBasicMetadata(from: entry.sourcePath, to: item.destinationPath)
                }

            case .file:
                if request.options.skipIdenticalFiles, isIdentical(entry: entry, destination: item.destinationPath) {
                    mutate {
                        $0.skippedFiles += 1
                        $0.skippedBytes += entry.size
                        $0.processedFiles += 1
                        $0.processedBytes += entry.size
                    }
                    return
                }

                if entry.linkCount > 1, let key = hardLinkKey(for: entry.sourcePath) {
                    lock.lock()
                    let existing = hardLinkMap[key]
                    if existing == nil { hardLinkMap[key] = item.destinationPath }
                    lock.unlock()

                    if let existing {
                        try FileOps.createHardLink(to: existing, at: item.destinationPath)
                        accountedBytes = entry.size
                        mutate {
                            $0.copiedFiles += 1
                            $0.processedFiles += 1
                            $0.processedBytes += entry.size
                        }
                        return
                    }
                }

                let bypassCache = entry.size >= request.options.bypassCacheThresholdBytes
                try bufferPool.withBuffer { buffer in
                    try FileOps.copyData(from: entry.sourcePath,
                                         to: item.destinationPath,
                                         size: entry.size,
                                         buffer: buffer,
                                         bypassCache: bypassCache,
                                         gate: gate) { chunk in
                        accountedBytes += Int64(chunk)
                        self.mutate {
                            $0.copiedBytes += Int64(chunk)
                            $0.processedBytes += Int64(chunk)
                        }
                    }
                }

                if request.options.preserveMetadata {
                    do {
                        try FileOps.copyMetadata(from: entry.sourcePath, to: item.destinationPath)
                    } catch {
                        // Non-fatal: the data is there, only the attributes are degraded.
                        record(issue: TransferIssue(path: entry.relativePath,
                                                    message: error.localizedDescription,
                                                    severity: .warning))
                    }
                }

                mutate {
                    $0.copiedFiles += 1
                    $0.processedFiles += 1
                }

            case .directory, .other:
                break
            }
        } catch {
            if case FileOpError.cancelled = error { return }
            mutate {
                $0.failedFiles += 1
                $0.processedFiles += 1
                // Account for the bytes we will never copy so the bar can still reach 100 %.
                $0.processedBytes += max(0, entry.size - accountedBytes)
            }
            handle(error: error, path: entry.relativePath, fatalIfStrict: true)
        }
    }

    private func isIdentical(entry: WalkEntry, destination: String) -> Bool {
        guard let destinationInfo = FileOps.fileInfo(destination),
              FileOps.isType(destinationInfo, S_IFREG),
              Int64(destinationInfo.st_size) == entry.size,
              let sourceInfo = FileOps.fileInfo(entry.sourcePath)
        else { return false }

        // One second of tolerance: FAT/ExFAT store timestamps at 2 s granularity.
        return abs(FileOps.modificationDate(sourceInfo) - FileOps.modificationDate(destinationInfo)) <= 1.0
    }

    private func hardLinkKey(for path: String) -> String? {
        guard let info = FileOps.fileInfo(path) else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    // MARK: - Directory metadata

    /// Applied last and deepest-first: writing a child rewrites its parent's modification date.
    private func applyDirectoryMetadata() {
        guard request.options.preserveMetadata else { return }

        lock.lock()
        let directories = createdDirectories
        lock.unlock()

        let sourceBase = request.source.fsPath
        let destinationBase = destinationRoot.fsPath

        for relative in directories.reversed() {
            guard gate.checkpoint() else { return }
            let source = sourceBase + "/" + relative
            let destination = destinationBase + "/" + relative
            do {
                try FileOps.copyMetadata(from: source, to: destination)
            } catch {
                record(issue: TransferIssue(path: relative,
                                            message: error.localizedDescription,
                                            severity: .warning))
            }
        }
    }

    // MARK: - Verify pass

    private func runVerifyPass() {
        let destinationBase = destinationRoot.fsPath
        var batch: [PendingItem] = []
        batch.reserveCapacity(batchSize)

        walkSource { entry in
            guard self.gate.checkpoint() else { return }
            guard entry.kind == .file else { return }

            batch.append(PendingItem(entry: entry, destinationPath: destinationBase + "/" + entry.relativePath))
            if batch.count >= self.batchSize {
                self.processVerify(batch: batch)
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty && !gate.isCancelled {
            processVerify(batch: batch)
        }
    }

    private func processVerify(batch: [PendingItem]) {
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: max(1, request.options.parallelWorkers))

        for item in batch {
            guard gate.checkpoint() else { break }
            semaphore.wait()
            workerQueue.async(group: group) { [self] in
                defer { semaphore.signal() }
                guard !gate.isCancelled else { return }
                verify(item)
            }
        }
        group.wait()
    }

    private func verify(_ item: PendingItem) {
        let entry = item.entry
        mutate { $0.currentItem = entry.relativePath }

        do {
            guard let destinationInfo = FileOps.fileInfo(item.destinationPath) else {
                throw FileOpError.missingAtDestination(path: entry.relativePath)
            }
            let destinationSize = Int64(destinationInfo.st_size)
            guard destinationSize == entry.size else {
                throw FileOpError.sizeMismatch(path: entry.relativePath,
                                               expected: entry.size,
                                               actual: destinationSize)
            }

            switch request.options.verification {
            case .none:
                break

            case .quick:
                if request.options.preserveMetadata, let sourceInfo = FileOps.fileInfo(entry.sourcePath) {
                    let delta = abs(FileOps.modificationDate(sourceInfo) - FileOps.modificationDate(destinationInfo))
                    if delta > 2.0 {
                        throw FileOpError.dateMismatch(path: entry.relativePath)
                    }
                }

            case .checksum:
                // Both sides are re-read from the devices; nothing from the copy pass is trusted.
                let sourceDigest = try bufferPool.withBuffer { buffer in
                    try FileOps.digest(of: entry.sourcePath,
                                       buffer: buffer,
                                       bypassCache: true,
                                       gate: gate) { chunk in
                        self.mutate { $0.verifiedBytes += Int64(chunk) }
                    }
                }
                let destinationDigest = try bufferPool.withBuffer { buffer in
                    try FileOps.digest(of: item.destinationPath,
                                       buffer: buffer,
                                       bypassCache: true,
                                       gate: gate) { _ in }
                }
                guard sourceDigest == destinationDigest else {
                    throw FileOpError.digestMismatch(path: entry.relativePath)
                }
            }

            mutate { $0.verifiedFiles += 1 }
        } catch {
            if case FileOpError.cancelled = error { return }
            mutate {
                $0.mismatchedFiles += 1
                $0.verifiedFiles += 1
            }
            handle(error: error, path: entry.relativePath, fatalIfStrict: false)
        }
    }

    // MARK: - Walking

    /// Depth-first walk of the source tree, applying the exclusion rules.
    private func walkSource(_ visit: (WalkEntry) -> Void) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .linkCountKey,
            .nameKey,
            .volumeIdentifierKey,
        ]

        let rootVolume = try? request.source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier

        guard let enumerator = FileManager.default.enumerator(
            at: request.source,
            includingPropertiesForKeys: keys,
            options: [.producesRelativePathURLs],
            errorHandler: { [weak self] url, error in
                self?.record(issue: TransferIssue(path: url.path,
                                                  message: "Voce non leggibile: \(error.localizedDescription)",
                                                  severity: .warning))
                return true // Skip this entry, keep walking.
            }
        ) else {
            record(issue: TransferIssue(path: request.source.path,
                                        message: "Impossibile leggere il contenuto dell'origine.",
                                        severity: .error))
            return
        }

        for case let url as URL in enumerator {
            guard gate.checkpoint() else { return }

            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                record(issue: TransferIssue(path: url.relativePath,
                                            message: "Attributi non leggibili: voce ignorata.",
                                            severity: .warning))
                continue
            }

            let isDirectory = values.isDirectory ?? false

            if shouldExclude(name: name) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            // Never cross into another mounted volume (disk images, nested mounts).
            if let rootVolume, let volume = values.volumeIdentifier, !volume.isEqual(rootVolume) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            let kind: EntryKind = if values.isSymbolicLink ?? false {
                .symlink
            } else if isDirectory {
                .directory
            } else if values.isRegularFile ?? false {
                .file
            } else {
                .other
            }

            visit(WalkEntry(kind: kind,
                            relativePath: url.relativePath,
                            sourcePath: url.fsPath,
                            size: Int64(values.fileSize ?? 0),
                            linkCount: values.linkCount ?? 1))
        }
    }

    private func shouldExclude(name: String) -> Bool {
        if request.options.excludeSystemFiles, ExcludedNames.system.contains(name) { return true }
        if request.options.excludeDSStore, name == ".DS_Store" { return true }
        return false
    }

    // MARK: - Bookkeeping

    private func mutate(_ body: (inout TransferCounters) -> Void) {
        lock.lock()
        body(&counters)
        lock.unlock()
    }

    private func setPhase(_ phase: TransferPhase) {
        mutate { $0.phase = phase }
    }

    private func record(issue: TransferIssue) {
        lock.lock()
        // Keep the list bounded: a broken drive can produce an error per file.
        if issues.count < 2000 { issues.append(issue) }
        counters.issueCount += 1
        lock.unlock()
    }

    private func handle(error: Error, path: String, fatalIfStrict: Bool) {
        record(issue: TransferIssue(path: path,
                                    message: error.localizedDescription,
                                    severity: .error))
        guard fatalIfStrict, !request.options.continueOnError else { return }
        lock.lock()
        if fatalMessage == nil {
            fatalMessage = "Interrotto al primo errore: \(error.localizedDescription)"
        }
        lock.unlock()
        gate.cancel()
    }

    private func finish(cancelled: Bool = false, with message: String? = nil) -> TransferReport {
        lock.lock()
        let recordedIssues = issues
        let storedFatal = fatalMessage
        var finalCounters = counters
        lock.unlock()

        let fatal = message ?? storedFatal

        let outcome: TransferReport.Outcome
        if let fatal, !fatal.isEmpty {
            outcome = .failed
            finalCounters.phase = .failed
        } else if cancelled {
            outcome = .cancelled
            finalCounters.phase = .cancelled
        } else if finalCounters.failedFiles > 0 || finalCounters.mismatchedFiles > 0 {
            outcome = .failed
            finalCounters.phase = .failed
        } else if recordedIssues.isEmpty {
            outcome = .completed
            finalCounters.phase = .completed
        } else {
            outcome = .completedWithIssues
            finalCounters.phase = .completed
        }
        finalCounters.currentItem = ""

        let resolvedPhase = finalCounters.phase
        mutate {
            $0.phase = resolvedPhase
            $0.currentItem = ""
        }

        var report = TransferReport()
        report.outcome = outcome
        report.counters = finalCounters
        report.issues = recordedIssues
        report.startedAt = startedAt
        report.finishedAt = Date()
        report.sourcePath = request.source.path
        report.destinationPath = destinationRoot.path
        report.verification = request.options.verification
        report.fatalMessage = fatal
        return report
    }
}

enum TransferSetupError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): return text
        }
    }
}
