import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DeviceState: String {
    case device, unauthorized, offline, recovery, sideload, noPermissions, unknown
    // File-transfer (MTP) states
    case connecting, locked, unavailable
    /// USB debugging on an Android version too old for Cablehop's browsing commands (before 6.0).
    case unsupported
    /// Unmount: closing the connection so the cable can be pulled safely; then unmounted until unplugged.
    case unmounting, unmounted

    init(raw: String) {
        switch raw {
        case "device": self = .device
        case "unauthorized": self = .unauthorized
        case "offline": self = .offline
        case "recovery": self = .recovery
        case "sideload": self = .sideload
        case "no": self = .noPermissions
        default: self = .unknown
        }
    }
}

enum Transport: Hashable {
    /// USB debugging / wireless debugging: everything works.
    case adb
    /// Plain "File transfer" USB mode: browsing and copying files only.
    case mtp
}

struct Device: Identifiable, Hashable {
    let serial: String
    var state: DeviceState
    var listedModel: String
    var transport: Transport = .adb

    var id: String { serial }
    var isMTP: Bool { transport == .mtp }
    var isWireless: Bool { !isMTP && (serial.contains(":") || serial.contains("._adb-tls-connect.")) }
    /// Search, sync, on-phone copy/paste, screenshots, app installs and Wi-Fi need USB debugging.
    var hasFullAccess: Bool { transport == .adb }
    /// Plugged in with a cable (Wi-Fi phones are disconnected instead of unmounted).
    var isWired: Bool { !isWireless }
    /// A wired phone Cablehop is using or trying to use, which can be unmounted before unplugging.
    var canUnmount: Bool { isWired && ![.unmounting, .unmounted].contains(state) }
}

struct DeviceInfo: Equatable {
    var manufacturer = ""
    var model = ""
    var androidVersion = ""
    /// Android API level (23 = Android 6.0), 0 if unknown.
    var sdk = 0
    var battery: Int?
    var wifiIP: String?
    var storageTotal: Int64 = 0
    var storageFree: Int64 = 0
}

struct MDNSService: Hashable {
    let name: String
    let type: String
    let address: String

    var host: String { address.split(separator: ":").dropLast().joined(separator: ":") }
    var isPairing: Bool { type.contains("pairing") }
    var isConnect: Bool { type.contains("tls-connect") || type.hasPrefix("_adb._tcp") }
}

struct RemoteFile: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var utType: UTType { isDirectory ? .folder : (UTType(filenameExtension: fileExtension) ?? .data) }
    var kind: String { isDirectory ? "Folder" : (utType.localizedDescription ?? "Document") }
    var isImage: Bool { !isDirectory && utType.conforms(to: .image) }
    var isVideo: Bool { !isDirectory && utType.conforms(to: .movie) }
    var parentPath: String { RemotePath.parent(path) }
}

enum ViewMode: String { case list, grid }

enum SearchScope: Hashable { case folder, everywhere }

enum SyncDirection: String, Codable, CaseIterable, Identifiable {
    case phoneToMac, macToPhone
    var id: String { rawValue }
    var label: String { self == .phoneToMac ? "Phone → Mac" : "Mac → Phone" }
}

struct SyncJob: Codable, Identifiable, Hashable {
    var id = UUID()
    var remotePath: String
    var localPath: String
    var direction: SyncDirection
    var lastRun: Date?

    var title: String {
        let remote = remotePath.split(separator: "/").last.map(String.init) ?? remotePath
        let local = (localPath as NSString).lastPathComponent
        return direction == .phoneToMac ? "\(remote) → \(local)" : "\(local) → \(remote)"
    }
}

enum RemotePath {
    /// Absolute, no "." or ".." components, no control characters.
    static func isSafe(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return false }
        return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    /// A single file name a person typed: not empty, no slashes, not "." or "..".
    static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ADBError.failed("The name can't be empty.") }
        guard !trimmed.contains("/") else { throw ADBError.failed("Names can't contain “/”.") }
        guard trimmed != "." && trimmed != ".." else { throw ADBError.failed("That name isn't allowed.") }
        guard trimmed.utf8.count <= 255 else { throw ADBError.failed("That name is too long.") }
        guard !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw ADBError.failed("That name contains invalid characters.")
        }
        return trimmed
    }

    /// Paths it would be catastrophic to delete by accident.
    static let protected: Set<String> = ["/", "/sdcard", "/storage", "/storage/emulated", "/storage/emulated/0",
                                         "/sdcard/DCIM", "/sdcard/Android", "/data", "/system"]

    static func isWithin(_ path: String, _ dir: String) -> Bool {
        path == dir || path.hasPrefix(dir == "/" ? "/" : dir + "/")
    }

    static func normalize(_ path: String) -> String {
        var p = path
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        return p
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    static func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

struct QuickLocation: Identifiable {
    let name: String
    let path: String
    let icon: String
    var id: String { path }

    static let all: [QuickLocation] = [
        .init(name: "Internal Storage", path: "/sdcard", icon: "internaldrive"),
        .init(name: "Camera", path: "/sdcard/DCIM/Camera", icon: "camera"),
        .init(name: "Screenshots", path: "/sdcard/Pictures/Screenshots", icon: "camera.viewfinder"),
        .init(name: "Downloads", path: "/sdcard/Download", icon: "arrow.down.circle"),
        .init(name: "Documents", path: "/sdcard/Documents", icon: "doc"),
        .init(name: "Pictures", path: "/sdcard/Pictures", icon: "photo"),
        .init(name: "Movies", path: "/sdcard/Movies", icon: "film"),
        .init(name: "Music", path: "/sdcard/Music", icon: "music.note"),
        .init(name: "WhatsApp Media", path: "/sdcard/Android/media/com.whatsapp/WhatsApp/Media", icon: "message"),
        .init(name: "Phone Root", path: "/", icon: "externaldrive"),
    ]

    /// Finder-style ⇧⌘ shortcuts for the Go menu (I = storage, L = downloads, O = documents).
    static func shortcut(at index: Int) -> KeyEquivalent? {
        switch all[index].path {
        case "/sdcard": return "i"
        case "/sdcard/Download": return "l"
        case "/sdcard/Documents": return "o"
        case "/sdcard/DCIM/Camera": return "c"
        default: return nil
        }
    }
}

enum Prefs {
    static let downloadFolderKey = "downloadFolder"

    static var defaultDownloadFolder: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    }

    static var downloadFolder: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: downloadFolderKey) ?? defaultDownloadFolder,
            isDirectory: true)
    }
}

enum Caches {
    static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cablehop", isDirectory: true)
    /// Copies of phone files opened, previewed, or dragged out.
    static let temp = root.appendingPathComponent("Temp", isDirectory: true)
    static let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)

    /// Deletes temp copies older than a day (anything opened in another app is long done by then)
    /// and trims the thumbnail cache if it has grown large.
    static func prune() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for url in (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: url) }
        }
        // Older builds put temp folders straight in the root.
        for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where UUID(uuidString: url.lastPathComponent) != nil {
            try? fm.removeItem(at: url)
        }
        if size(of: thumbnails) > 500 * 1024 * 1024 { try? fm.removeItem(at: thumbnails) }
    }

    static func size(of dir: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        while let url = e?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.removeItem(at: thumbnails)
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for file: RemoteFile) -> NSImage {
        let key = file.isDirectory ? "/folder" : file.fileExtension
        if let icon = cache[key] { return icon }
        let icon = NSWorkspace.shared.icon(for: file.utType)
        cache[key] = icon
        return icon
    }
}

func randomAlphanumeric(_ length: Int) -> String {
    let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    return String((0..<length).map { _ in chars.randomElement()! })
}
