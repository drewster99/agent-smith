import Foundation
import os

private let logger = Logger(subsystem: "com.agentsmith", category: "Persistence")

/// Saves and loads channel logs, task lists, and attachment files in Application Support.
///
/// The initializer resolves `~/Library/Application Support`, which is guaranteed to exist
/// on macOS. The `preconditionFailure` guards against truly exceptional platform breakage
/// (e.g., a sandboxing misconfiguration) where no recovery is possible.
public actor PersistenceManager {
    private let baseDirectory: URL
    private let attachmentsDirectory: URL

    public init() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure(
                "Application Support directory unavailable — "
                + "this directory is guaranteed on macOS; check sandbox entitlements"
            )
        }
        baseDirectory = appSupport.appendingPathComponent("AgentSmith", isDirectory: true)
        attachmentsDirectory = baseDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    /// Ensures storage directories exist.
    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: attachmentsDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Channel Log

    /// Saves channel messages to disk.
    public func saveChannelLog(_ messages: [ChannelMessage]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(messages)
        let url = baseDirectory.appendingPathComponent("channel_log.json")
        try data.write(to: url, options: .atomic)
    }

    /// Loads channel messages from disk.
    public func loadChannelLog() throws -> [ChannelMessage] {
        let url = baseDirectory.appendingPathComponent("channel_log.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ChannelMessage].self, from: data)
    }

    // MARK: - Tasks

    /// Saves tasks to disk.
    public func saveTasks(_ tasks: [AgentTask]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(tasks)
        let url = baseDirectory.appendingPathComponent("tasks.json")
        try data.write(to: url, options: .atomic)
    }

    /// Loads tasks from disk.
    public func loadTasks() throws -> [AgentTask] {
        let url = baseDirectory.appendingPathComponent("tasks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([AgentTask].self, from: data)
    }

    // MARK: - Memories

    /// Saves semantic memories to disk.
    public func saveMemories(_ memories: [MemoryEntry]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(memories)
        let url = baseDirectory.appendingPathComponent("memories.json")
        try data.write(to: url, options: .atomic)
    }

    /// Loads semantic memories from disk.
    public func loadMemories() throws -> [MemoryEntry] {
        let url = baseDirectory.appendingPathComponent("memories.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([MemoryEntry].self, from: data)
    }

    /// Saves task summary embeddings to disk.
    public func saveTaskSummaries(_ summaries: [TaskSummaryEntry]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(summaries)
        let url = baseDirectory.appendingPathComponent("task_summaries.json")
        try data.write(to: url, options: .atomic)
    }

    /// Loads task summary embeddings from disk.
    public func loadTaskSummaries() throws -> [TaskSummaryEntry] {
        let url = baseDirectory.appendingPathComponent("task_summaries.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TaskSummaryEntry].self, from: data)
    }

    // MARK: - Usage Records

    /// Saves usage records to disk.
    public func saveUsageRecords(_ records: [UsageRecord]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(records)
        let url = baseDirectory.appendingPathComponent("usage_records.json")
        try data.write(to: url, options: .atomic)
    }

    /// Loads usage records from disk.
    public func loadUsageRecords() throws -> [UsageRecord] {
        let url = baseDirectory.appendingPathComponent("usage_records.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([UsageRecord].self, from: data)
    }

    // MARK: - Attachments

    /// Saves attachment file data to disk. Call this when the user adds an attachment.
    public func saveAttachment(_ attachment: Attachment) throws {
        guard let fileData = attachment.data else { return }
        try ensureDirectories()
        let safeName = Self.sanitizeFilename(attachment.filename)
        let url = attachmentsDirectory.appendingPathComponent(
            "\(attachment.id.uuidString)_\(safeName)"
        )
        try fileData.write(to: url, options: .atomic)
    }

    /// Loads attachment file data from disk.
    public func loadAttachmentData(id: UUID, filename: String) -> Data? {
        let safeName = Self.sanitizeFilename(filename)
        let url = attachmentsDirectory.appendingPathComponent(
            "\(id.uuidString)_\(safeName)"
        )
        do {
            return try Data(contentsOf: url)
        } catch {
            logger.error("Failed to load attachment \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    /// Strips path components from a filename to prevent directory traversal.
    static func sanitizeFilename(_ filename: String) -> String {
        let stripped = (filename as NSString).lastPathComponent
        return stripped.isEmpty ? "unnamed" : stripped
    }
}
