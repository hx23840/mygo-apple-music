import CryptoKit
import Foundation
import ImageIO
import MusicKit
import UniformTypeIdentifiers

actor ArtworkCache {
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.mygo.applemusic", isDirectory: true)
        .appendingPathComponent("artwork", isDirectory: true)
    private var tasks: [String: Task<String?, Never>] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func imageURL(_ artwork: Artwork?, key: String) async -> String? {
        guard let source = artwork?.url(width: 600, height: 600) else { return nil }
        let digest = SHA256.hash(data: Data(("600:" + key).utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent(digest + ".jpg")
        if let values = try? destination.resourceValues(forKeys: [.contentModificationDateKey]),
           let modified = values.contentModificationDate, Date().timeIntervalSince(modified) < 7 * 86400 {
            return destination.absoluteString
        }
        if let task = tasks[digest] { return await task.value }
        let directory = self.directory
        let task = Task {
            await acquire()
            let result = await Task.detached(priority: .utility) {
                Self.writeImage(from: source, to: destination, directory: directory)
            }.value
            release()
            return result
        }
        tasks[digest] = task
        let result = await task.value
        tasks[digest] = nil
        trim(keeping: Set(tasks.keys).union([digest]))
        return result
    }

    private func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }

    private static func writeImage(from source: URL, to destination: URL, directory: URL) -> String? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try Data(contentsOf: source)
            guard data.count <= 20 * 1024 * 1024,
                  let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600
                  ] as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(encoder, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(encoder) else { return nil }
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
            defer { try? manager.removeItem(at: temporary) }
            guard manager.createFile(atPath: temporary.path, contents: output as Data, attributes: [.posixPermissions: 0o600]) else { return nil }
            if rename(temporary.path, destination.path) != 0 { return nil }
            return destination.absoluteString
        } catch {
            return manager.fileExists(atPath: destination.path) ? destination.absoluteString : nil
        }
    }

    private func trim(keeping digests: Set<String>) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.filter { $0.pathExtension == "jpg" }.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var size = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where size > 64 * 1024 * 1024 && !digests.contains(entry.0.deletingPathExtension().lastPathComponent) {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { size -= entry.1 }
        }
    }
}
