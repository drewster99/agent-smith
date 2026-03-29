import AppKit
import ImageIO
import AgentSmithKit

/// Tiered image cache with efficient thumbnail generation via ImageIO.
/// RAM cache for all tiers; disk cache for chip and small thumbnails.
@MainActor
final class ImageCache {
    /// Shared singleton used by all views.
    static let shared = ImageCache()

    /// The maximum pixel dimension for each display tier.
    enum Tier: String, CaseIterable {
        case chip   = "chip"    // 32pt square matte in the input bar
        case small  = "small"   // ~120pt for user-sent message images
        case medium = "medium"  // ~400pt for received message images
        case full   = "full"    // original resolution

        var maxPixelDimension: CGFloat {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            switch self {
            case .chip:   return 32 * scale
            case .small:  return 120 * scale
            case .medium: return 400 * scale
            case .full:   return 0  // no downscaling
            }
        }
    }

    // MARK: - RAM cache

    /// Key: "<attachmentID>-<tier>" -> NSImage
    private let ramCache = NSCache<NSString, NSImage>()

    // MARK: - Disk cache

    private let thumbnailDirectory: URL

    // MARK: - Init

    private init() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            fatalError("Application Support directory unavailable")
        }
        thumbnailDirectory = appSupport
            .appendingPathComponent("AgentSmith", isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: thumbnailDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("[AgentSmith] Failed to create thumbnail cache directory: \(error)")
        }
    }

    // MARK: - Public API

    /// Returns a cached or freshly generated image for the given attachment and tier.
    /// Returns `nil` only when no image data is available.
    func image(for attachment: Attachment, tier: Tier) -> NSImage? {
        let cacheKey = NSString(string: "\(attachment.id.uuidString)-\(tier.rawValue)")

        // 1. RAM cache hit
        if let cached = ramCache.object(forKey: cacheKey) {
            return cached
        }

        // 2. Disk cache hit (chip and small only)
        if tier != .full, tier != .medium {
            if let diskImage = loadFromDisk(attachmentID: attachment.id, tier: tier) {
                ramCache.setObject(diskImage, forKey: cacheKey)
                return diskImage
            }
        }

        // 3. Generate from source data
        guard let sourceData = attachment.data
                ?? Attachment.loadPersistedData(id: attachment.id, filename: attachment.filename)
        else {
            return nil
        }

        let image: NSImage
        if tier == .full {
            guard let nsImage = NSImage(data: sourceData) else { return nil }
            image = nsImage
        } else {
            guard let thumbnail = generateThumbnail(from: sourceData, tier: tier) else { return nil }
            image = thumbnail
        }

        ramCache.setObject(image, forKey: cacheKey)

        // 4. Persist chip and small to disk in the background
        if tier == .chip || tier == .small {
            let diskURL = diskCacheURL(attachmentID: attachment.id, tier: tier)
            Task.detached(priority: .utility) {
                Self.writeToDisk(image: image, url: diskURL)
            }
        }

        return image
    }

    /// Pre-warms the cache for a set of attachments at a given tier.
    /// Call from `.task` on a container view for smooth scrolling.
    func preload(_ attachments: [Attachment], tier: Tier) {
        for attachment in attachments where attachment.isImage {
            _ = image(for: attachment, tier: tier)
        }
    }

    // MARK: - Thumbnail generation via ImageIO

    /// Efficiently generates a downsampled thumbnail without decoding the full image.
    private func generateThumbnail(from data: Data, tier: Tier) -> NSImage? {
        let maxDimension = tier.maxPixelDimension
        guard maxDimension > 0 else { return nil }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    // MARK: - Disk persistence

    private func diskCacheURL(attachmentID: UUID, tier: Tier) -> URL {
        thumbnailDirectory.appendingPathComponent("\(attachmentID.uuidString)-\(tier.rawValue).png")
    }

    private func loadFromDisk(attachmentID: UUID, tier: Tier) -> NSImage? {
        let url = diskCacheURL(attachmentID: attachmentID, tier: tier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private nonisolated static func writeToDisk(image: NSImage, url: URL) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else { return }
        do {
            try pngData.write(to: url, options: .atomic)
        } catch {
            print("[AgentSmith] Failed to write thumbnail to disk: \(error)")
        }
    }
}
