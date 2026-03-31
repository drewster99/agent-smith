import Foundation
import os

private let attachmentLogger = Logger(subsystem: "com.agentsmith", category: "Attachment")

/// A file attachment on a channel message. Supports any media type.
/// File data is stored separately on disk; only metadata is persisted in the message JSON.
public struct Attachment: Identifiable, Codable, Sendable {
    public var id: UUID
    public var filename: String
    public var mimeType: String
    public var byteCount: Int

    /// In-memory file data. Excluded from Codable — persisted separately by PersistenceManager.
    public var data: Data?

    private enum CodingKeys: String, CodingKey {
        case id, filename, mimeType, byteCount
    }

    public init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        byteCount: Int,
        data: Data? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.data = data
    }

    /// Whether the LLM can process this as an image.
    public var isImage: Bool {
        mimeType.hasPrefix("image/")
    }

    /// Whether the LLM can process this as a PDF document.
    public var isPDF: Bool {
        mimeType == "application/pdf"
    }

    /// Loads data from Application Support if not already in memory.
    public mutating func loadDataIfNeeded() {
        guard data == nil else { return }
        data = Self.loadPersistedData(id: id, filename: filename)
    }

    /// Loads attachment file data from the persistence directory.
    public static func loadPersistedData(id: UUID, filename: String) -> Data? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let safeName = PersistenceManager.sanitizeFilename(filename)
        let url = appSupport
            .appendingPathComponent("AgentSmith", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("\(id.uuidString)_\(safeName)")

        do {
            return try Data(contentsOf: url)
        } catch {
            attachmentLogger.error("Failed to load persisted data for attachment \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    /// Human-readable file size.
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
