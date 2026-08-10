import Foundation

/// Security-scoped bookmarks so the source/destination survive a relaunch without asking the user
/// to re-pick the drives. Requires `com.apple.security.files.bookmarks.app-scope` in the sandbox.
enum BookmarkStore {
    enum Slot: String {
        case source = "Bookmark.source"
        case destination = "Bookmark.destination"
    }

    /// URLs whose security scope we opened. Kept for the app's lifetime and released on quit.
    private static var accessed: [URL] = []
    private static let lock = NSLock()

    static func save(_ url: URL, to slot: Slot) {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: slot.rawValue)
        } catch {
            // Not fatal: the selection still works for this session, it just won't be restored.
            NSLog("SSDCopier: impossibile creare il bookmark per \(url.path): \(error.localizedDescription)")
        }
    }

    /// Resolves a stored bookmark and opens its security scope. Returns nil if the drive is
    /// unplugged or the bookmark no longer resolves.
    static func restore(_ slot: Slot) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: slot.rawValue) else { return nil }

        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else {
            UserDefaults.standard.removeObject(forKey: slot.rawValue)
            return nil
        }

        guard url.startAccessingSecurityScopedResource() else { return nil }

        // The volume may have been unmounted since the bookmark was written.
        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }

        lock.lock()
        accessed.append(url)
        lock.unlock()

        if stale { save(url, to: slot) }
        return url
    }

    static func clear(_ slot: Slot) {
        UserDefaults.standard.removeObject(forKey: slot.rawValue)
    }

    static func releaseAll() {
        lock.lock()
        let urls = accessed
        accessed.removeAll()
        lock.unlock()
        for url in urls { url.stopAccessingSecurityScopedResource() }
    }
}
