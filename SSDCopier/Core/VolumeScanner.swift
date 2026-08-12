import Foundation
import AppKit

struct VolumeInfo: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let isRemovable: Bool
    let isEjectable: Bool
    let isInternal: Bool
    let isReadOnly: Bool
    let isRoot: Bool

    var id: URL { url }

    /// External = anything the user could physically unplug.
    var isExternal: Bool { !isInternal || isRemovable || isEjectable }

    var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return min(max(Double(usedCapacity) / Double(totalCapacity), 0), 1)
    }

    var capacityDescription: String {
        guard totalCapacity > 0 else { return L("volume.unknownCapacity") }
        return L("volume.capacity", Fmt.bytes(availableCapacity), Fmt.bytes(totalCapacity))
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum VolumeScanner {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeLocalizedNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeIsInternalKey,
        .volumeIsReadOnlyKey,
        .volumeIsRootFileSystemKey,
        .volumeIsBrowsableKey,
    ]

    /// Mounted, user-browsable volumes. Enumerating volumes needs no entitlement; reading their
    /// contents does, which is why the UI still routes every choice through an open panel.
    static func scan() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        let volumes = urls.compactMap { info(for: $0) }
        return volumes.sorted { lhs, rhs in
            if lhs.isExternal != rhs.isExternal { return lhs.isExternal }
            if lhs.isRoot != rhs.isRoot { return rhs.isRoot }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func info(for url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        guard values.volumeIsBrowsable != false else { return nil }

        let name = values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent
        // `…ForImportantUsage` accounts for purgeable space and is the honest number for a big
        // copy — but it is an APFS/HFS+ notion. On exFAT, NTFS and FAT it comes back as *0*
        // rather than nil, which made every non-Apple drive look completely full: no free space
        // in the card, and a bogus "not enough space" warning on every transfer.
        let importantUsage = values.volumeAvailableCapacityForImportantUsage ?? 0
        let plainAvailable = Int64(values.volumeAvailableCapacity ?? 0)
        let available = importantUsage > 0 ? importantUsage : plainAvailable

        return VolumeInfo(
            url: url,
            name: name,
            totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
            availableCapacity: available,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isInternal: values.volumeIsInternal ?? true,
            isReadOnly: values.volumeIsReadOnly ?? false,
            isRoot: values.volumeIsRootFileSystem ?? false
        )
    }

    /// The volume a given path lives on, used to label an arbitrary folder selection.
    static func volume(containing url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let volumeURL = values.volume
        else { return nil }
        return info(for: volumeURL)
    }
}
