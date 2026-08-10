import CryptoKit
import Darwin
import Foundation

enum FileOpError: LocalizedError {
    case cancelled
    case open(path: String, errno: Int32)
    case create(path: String, errno: Int32)
    case read(path: String, errno: Int32)
    case write(path: String, errno: Int32)
    case shortWrite(path: String)
    case metadata(path: String, errno: Int32)
    case symlink(path: String, errno: Int32)
    case link(path: String, errno: Int32)
    case makeDirectory(path: String, errno: Int32)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case digestMismatch(path: String)
    case missingAtDestination(path: String)
    case dateMismatch(path: String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Operazione annullata."
        case let .open(path, code):
            return "Impossibile aprire «\(path)»: \(Self.describe(code))"
        case let .create(path, code):
            return "Impossibile creare «\(path)»: \(Self.describe(code))"
        case let .read(path, code):
            return "Errore di lettura su «\(path)»: \(Self.describe(code))"
        case let .write(path, code):
            return "Errore di scrittura su «\(path)»: \(Self.describe(code))"
        case let .shortWrite(path):
            return "Scrittura incompleta su «\(path)»: spazio esaurito o disco scollegato."
        case let .metadata(path, code):
            return "Metadati non applicati a «\(path)»: \(Self.describe(code))"
        case let .symlink(path, code):
            return "Link simbolico non creato «\(path)»: \(Self.describe(code))"
        case let .link(path, code):
            return "Hard link non creato «\(path)»: \(Self.describe(code))"
        case let .makeDirectory(path, code):
            return "Cartella non creata «\(path)»: \(Self.describe(code))"
        case let .sizeMismatch(path, expected, actual):
            return "Dimensione diversa su «\(path)»: attesi \(Fmt.bytes(expected)), trovati \(Fmt.bytes(actual))."
        case let .digestMismatch(path):
            return "Hash SHA-256 diverso su «\(path)»: la copia non corrisponde all'originale."
        case let .missingAtDestination(path):
            return "File assente nella destinazione: «\(path)»."
        case let .dateMismatch(path):
            return "Data di modifica diversa su «\(path)»."
        }
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Thin POSIX layer. `FileManager.copyItem` gives no progress and no cancellation, so the byte
/// pump is written by hand; metadata is still delegated to `copyfile(3)` which knows about ACLs,
/// extended attributes and resource forks.
enum FileOps {

    // MARK: - Stat

    static func lstat(_ path: String) -> stat? {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { return nil }
        return info
    }

    static func modificationDate(_ info: stat) -> TimeInterval {
        TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    // MARK: - Directories

    static func makeDirectory(at path: String, mode: mode_t = 0o755) throws {
        if mkdir(path, mode) == 0 { return }
        let code = errno
        if code == EEXIST {
            var info = stat()
            // Unqualified on purpose. In Darwin, `stat` names both the struct and
            // the function, and module-qualified lookup resolves to the *type*:
            // `Darwin.stat(path, &info)` becomes `stat.init(path, &info)`, whose
            // init takes no arguments, and the result is a `stat` being compared
            // to 0. Unqualified, the arguments select the function.
            // (`Darwin.lstat` above is fine — no type shares that name, and the
            // qualification is needed there to avoid recursing into FileOps.lstat.)
            if stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR { return }
        }
        throw FileOpError.makeDirectory(path: path, errno: code)
    }

    // MARK: - Symlinks

    static func readSymlink(at path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(path, &buffer, buffer.count - 1)
        guard length >= 0 else { throw FileOpError.read(path: path, errno: errno) }
        buffer[length] = 0
        return String(cString: buffer)
    }

    static func createSymlink(target: String, at path: String) throws {
        unlink(path)
        guard symlink(target, path) == 0 else {
            throw FileOpError.symlink(path: path, errno: errno)
        }
    }

    static func createHardLink(to existing: String, at path: String) throws {
        unlink(path)
        guard link(existing, path) == 0 else {
            throw FileOpError.link(path: path, errno: errno)
        }
    }

    // MARK: - Copy

    /// Streams `source` into `destination`, reporting every chunk and honouring the gate.
    ///
    /// - Parameter bypassCache: sets `F_NOCACHE` so a multi-hundred-gigabyte transfer doesn't evict
    ///   the entire unified buffer cache (and so a later verification really hits the device).
    static func copyData(from source: String,
                         to destination: String,
                         size: Int64,
                         buffer: UnsafeMutableRawBufferPointer,
                         bypassCache: Bool,
                         gate: TransferGate,
                         onChunk: (Int) -> Void) throws {
        let inFD = open(source, O_RDONLY)
        guard inFD >= 0 else { throw FileOpError.open(path: source, errno: errno) }
        defer { close(inFD) }

        let outFD = open(destination, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outFD >= 0 else { throw FileOpError.create(path: destination, errno: errno) }
        var closed = false
        defer { if !closed { close(outFD) } }

        if bypassCache {
            _ = fcntl(inFD, F_NOCACHE, 1)
            _ = fcntl(outFD, F_NOCACHE, 1)
        }
        _ = fcntl(inFD, F_RDAHEAD, 1)
        if size > 0 { preallocate(fd: outFD, size: size) }

        guard let base = buffer.baseAddress else { throw FileOpError.read(path: source, errno: EINVAL) }
        let capacity = buffer.count

        while true {
            guard gate.checkpoint() else { throw FileOpError.cancelled }

            let bytesRead = retrying { read(inFD, base, capacity) }
            if bytesRead < 0 { throw FileOpError.read(path: source, errno: errno) }
            if bytesRead == 0 { break }

            var written = 0
            while written < bytesRead {
                let n = retrying { write(outFD, base.advanced(by: written), bytesRead - written) }
                if n < 0 {
                    if errno == ENOSPC { throw FileOpError.shortWrite(path: destination) }
                    throw FileOpError.write(path: destination, errno: errno)
                }
                if n == 0 { throw FileOpError.shortWrite(path: destination) }
                written += n
            }
            onChunk(bytesRead)
        }

        // Push the data out of the drive's write buffers before we call the file done.
        if fsync(outFD) != 0 && errno != ENOTSUP && errno != EINVAL {
            throw FileOpError.write(path: destination, errno: errno)
        }
        closed = true
        if close(outFD) != 0 {
            throw FileOpError.write(path: destination, errno: errno)
        }
    }

    /// SHA-256 of a file's contents, streamed through the caller's buffer.
    static func digest(of path: String,
                       buffer: UnsafeMutableRawBufferPointer,
                       bypassCache: Bool,
                       gate: TransferGate,
                       onChunk: (Int) -> Void) throws -> String {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw FileOpError.open(path: path, errno: errno) }
        defer { close(fd) }

        // Without F_NOCACHE the "verification" would often just re-read the page cache — i.e. the
        // bytes we wrote, not the bytes the drive actually stored.
        if bypassCache { _ = fcntl(fd, F_NOCACHE, 1) }
        _ = fcntl(fd, F_RDAHEAD, 1)

        guard let base = buffer.baseAddress else { throw FileOpError.read(path: path, errno: EINVAL) }
        var hasher = SHA256()

        while true {
            guard gate.checkpoint() else { throw FileOpError.cancelled }

            let bytesRead = retrying { read(fd, base, buffer.count) }
            if bytesRead < 0 { throw FileOpError.read(path: path, errno: errno) }
            if bytesRead == 0 { break }

            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base, count: bytesRead))
            onChunk(bytesRead)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Metadata

    /// Permissions, ACLs, extended attributes (resource forks included) and timestamps.
    /// Applied *after* the data so the destination's mtime reflects the source, not the copy.
    static func copyMetadata(from source: String, to destination: String) throws {
        let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
        if copyfile(source, destination, nil, flags) == 0 { return }
        let code = errno

        // ExFAT/FAT destinations reject ACLs and xattrs. Fall back to mode + mtime, which every
        // filesystem supports, and let the caller decide whether to surface a warning.
        if applyBasicMetadata(from: source, to: destination) { return }
        throw FileOpError.metadata(path: destination, errno: code)
    }

    @discardableResult
    static func applyBasicMetadata(from source: String, to destination: String) -> Bool {
        guard let info = lstat(source) else { return false }
        var ok = true
        if (info.st_mode & S_IFMT) != S_IFLNK {
            ok = chmod(destination, info.st_mode & 0o7777) == 0 && ok
        }
        var times = [info.st_atimespec, info.st_mtimespec]
        ok = utimensat(AT_FDCWD, destination, &times, AT_SYMLINK_NOFOLLOW) == 0 && ok
        return ok
    }

    // MARK: - Helpers

    /// Hint the filesystem about the final size: fewer extents, less fragmentation, and it fails
    /// early when the destination is full instead of halfway through a 40 GB file.
    private static func preallocate(fd: Int32, size: Int64) {
        var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG),
                             fst_posmode: F_PEOFPOSMODE,
                             fst_offset: 0,
                             fst_length: off_t(size),
                             fst_bytesalloc: 0)
        let contiguous = withUnsafeMutablePointer(to: &store) {
            fcntl(fd, F_PREALLOCATE, UnsafeMutableRawPointer($0))
        }
        if contiguous == -1 {
            // Contiguous space unavailable — settle for any space.
            store.fst_flags = UInt32(F_ALLOCATEALL)
            _ = withUnsafeMutablePointer(to: &store) {
                fcntl(fd, F_PREALLOCATE, UnsafeMutableRawPointer($0))
            }
        }
    }

    /// Retries a syscall interrupted by a signal.
    private static func retrying(_ body: () -> Int) -> Int {
        while true {
            let result = body()
            if result < 0 && errno == EINTR { continue }
            return result
        }
    }
}

extension URL {
    /// Filesystem representation as a `String`, safe for the POSIX calls above.
    var fsPath: String {
        withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return path }
            return String(cString: pointer)
        }
    }
}
