import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Loads photo thumbnails from the phone, cached in memory and on disk.
///
/// JPEGs usually carry an embedded EXIF preview in their first few KB, so we read just
/// the head of the file. Other images fall back to copying the whole file when it's small.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let memory = NSCache<NSString, NSImage>()
    private let diskDir: URL
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 3
    private let maxFullDownload: Int64 = 20 * 1024 * 1024
    private let maxFullDownloadOverUSB: Int64 = 4 * 1024 * 1024

    init() {
        diskDir = Caches.thumbnails
        memory.countLimit = 600
    }

    func clearMemory() { memory.removeAllObjects() }

    func thumbnail(for file: RemoteFile, serial: String) async -> NSImage? {
        let key = "\(file.path)|\(file.size)|\(Int(file.modified.timeIntervalSince1970))"
        if let image = memory.object(forKey: key as NSString) { return image }
        let diskURL = diskDir.appendingPathComponent(Self.hash(key) + ".jpg")
        if let image = NSImage(contentsOf: diskURL) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }

        var cgImage: CGImage?
        let path = file.path
        if let fs = Phones.mtp(serial) {
            // File-transfer mode: Android serves ready-made thumbnails for photos and videos.
            if let data = try? await onBackground({ try fs.thumbnail(path) }) {
                cgImage = Self.makeThumbnail(from: data, embeddedOnly: false)
            }
            // Only small photos are copied whole: file transfer has one USB connection, and big copies made
            // just for previews would hold up browsing and real transfers.
            if cgImage == nil, file.isImage, file.size <= maxFullDownloadOverUSB, !Task.isCancelled,
               let data = try? await onBackground({ try fs.readAll(path) }) {
                cgImage = Self.makeThumbnail(from: data, embeddedOnly: false)
            }
        } else {
            if ["jpg", "jpeg"].contains(file.fileExtension),
               let head = try? await ADB.readPrefix(serial: serial, path: path, count: 128 * 1024) {
                cgImage = Self.makeThumbnail(from: head, embeddedOnly: true)
            }
            if cgImage == nil, file.isImage, file.size <= maxFullDownload, !Task.isCancelled,
               let data = try? await ADB.readFile(serial: serial, path: path) {
                cgImage = Self.makeThumbnail(from: data, embeddedOnly: false)
            }
        }
        guard let cgImage else { return nil }

        Self.writeJPEG(cgImage, to: diskURL)
        let image = NSImage(cgImage: cgImage, size: .zero)
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    private func acquire() async {
        if running < maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }

    private static func makeThumbnail(from data: Data, embeddedOnly: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        if embeddedOnly {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = false
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) {
        // The folder may have been cleared from Settings since launch.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
