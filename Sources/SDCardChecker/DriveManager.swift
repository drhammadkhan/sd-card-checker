import AppKit
import DiskArbitration

struct CardVolume: Identifiable, Hashable {
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let format: String
    let bsdName: String?
    let wholeDiskBSD: String?
    let mediaSize: Int64?
    let deviceDescription: String?
    let connection: String?
    let isReadOnly: Bool
    let isSDCard: Bool
    let hasLeftoverTestFiles: Bool

    var id: String { url.path }
    var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }
}

/// Discovers mounted removable / external volumes and keeps the list current.
@MainActor
final class DriveManager: ObservableObject {
    @Published private(set) var volumes: [CardVolume] = []
    @Published var errorMessage: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsReadOnlyKey,
            .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let session = DASessionCreate(kCFAllocatorDefault)
        var found: [CardVolume] = []

        for var url in urls {
            guard url.path.hasPrefix("/Volumes/") else { continue }
            url.removeAllCachedResourceValues()
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true else { continue }

            var desc: [String: Any] = [:]
            var wholeDesc: [String: Any] = [:]
            if let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) {
                desc = (DADiskCopyDescription(disk) as? [String: Any]) ?? [:]
                if let whole = DADiskCopyWholeDisk(disk) {
                    wholeDesc = (DADiskCopyDescription(whole) as? [String: Any]) ?? [:]
                }
            }
            func str(_ key: CFString) -> String? {
                (desc[key as String] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            }

            let model = str(kDADiskDescriptionDeviceModelKey)
            let vendor = str(kDADiskDescriptionDeviceVendorKey)
            let proto = str(kDADiskDescriptionDeviceProtocolKey)
            let mediaName = str(kDADiskDescriptionMediaNameKey)
            let internalDevice = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? (v.volumeIsInternal ?? false)
            let removableMedia = desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? (v.volumeIsRemovable ?? false)

            // Skip mounted disk images and fixed internal disks.
            let isVirtual = (model?.localizedCaseInsensitiveContains("disk image") ?? false)
                || proto == "Virtual Interface" || proto == "Disk Image"
            if isVirtual { continue }
            if internalDevice && !removableMedia && v.volumeIsEjectable != true { continue }

            let hay = [vendor, model, mediaName].compactMap { $0 }.joined(separator: " ")
            // Card readers report the inserted card as removable media, even generic "MassStorageClass" ones.
            let isSD = proto == "Secure Digital" || removableMedia || hay.contains("SD") || hay.localizedCaseInsensitiveContains("card")
            let writable = desc[kDADiskDescriptionMediaWritableKey as String] as? Bool ?? true
            let mediaSize = (wholeDesc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value

            found.append(CardVolume(
                url: url,
                name: v.volumeLocalizedName ?? v.volumeName ?? url.lastPathComponent,
                totalCapacity: Int64(v.volumeTotalCapacity ?? 0),
                availableCapacity: Int64(v.volumeAvailableCapacity ?? 0),
                format: v.volumeLocalizedFormatDescription ?? "Unknown",
                bsdName: str(kDADiskDescriptionMediaBSDNameKey),
                wholeDiskBSD: wholeDesc[kDADiskDescriptionMediaBSDNameKey as String] as? String,
                mediaSize: mediaSize,
                deviceDescription: [vendor, model].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
                connection: proto.map { internalDevice ? "\($0) (built-in reader)" : $0 },
                isReadOnly: v.volumeIsReadOnly == true || !writable,
                isSDCard: isSD,
                hasLeftoverTestFiles: FileManager.default.fileExists(
                    atPath: url.appendingPathComponent(TestEngine.testFolderName).path)
            ))
        }

        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if found != volumes { volumes = found }
    }

    func eject(_ volume: CardVolume) {
        let url = volume.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message: String?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch { message = error.localizedDescription }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let message { self?.errorMessage = "Couldn't eject: \(message)" }
                    self?.refresh()
                }
            }
        }
    }

    func removeLeftovers(_ volume: CardVolume) {
        let path = volume.url.appendingPathComponent(TestEngine.testFolderName).path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? FileManager.default.removeItem(atPath: path)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
    }
}
