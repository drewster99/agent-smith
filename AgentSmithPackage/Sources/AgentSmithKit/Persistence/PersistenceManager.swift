import Foundation
import os
import SwiftLLMKit

private let logger = Logger(subsystem: "com.agentsmith", category: "Persistence")

/// Saves and loads channel logs, task lists, attachments, memories, summaries, and usage data.
///
/// There are two flavors:
/// * `init()` — base manager. Channel / task / attachment methods read and write the legacy
///   root paths (`AgentSmith/channel_log.json`, etc.). Used during migration and for shared
///   resources that are never session-scoped.
/// * `init(sessionID:)` — session-scoped manager. Channel / task / attachment / state methods
///   read and write `AgentSmith/sessions/<id>/…`. Shared methods (memories, task summaries,
///   usage records, model overrides, session list) always use the root `AgentSmith/` dir
///   regardless of which flavor was used to construct the manager.
///
/// The `preconditionFailure` in `appSupportURL()` guards against truly exceptional platform
/// breakage (e.g., a sandboxing misconfiguration) where no recovery is possible.
public actor PersistenceManager {
    private let baseDirectory: URL
    private let sessionDirectory: URL
    private let attachmentsDirectory: URL

    public init() {
        let appSupport = Self.appSupportURL()
        baseDirectory = appSupport.appendingPathComponent("AgentSmith", isDirectory: true)
        sessionDirectory = baseDirectory
        attachmentsDirectory = baseDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    public init(sessionID: UUID) {
        let appSupport = Self.appSupportURL()
        baseDirectory = appSupport.appendingPathComponent("AgentSmith", isDirectory: true)
        sessionDirectory = baseDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        attachmentsDirectory = sessionDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    private static func appSupportURL() -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure(
                "Application Support directory unavailable — "
                + "this directory is guaranteed on macOS; check sandbox entitlements"
            )
        }
        return appSupport
    }

    /// Ensures storage directories exist (both base and session, plus the session's attachments/).
    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: attachmentsDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Session List (shared)

    /// Loads the persistent session list. Returns [] if `sessions.json` is missing.
    public func loadSessionList() throws -> [Session] {
        let url = baseDirectory.appendingPathComponent("sessions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Session].self, from: data)
    }

    /// Saves the session list to disk.
    public func saveSessionList(_ sessions: [Session]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(sessions)
        let url = baseDirectory.appendingPathComponent("sessions.json")
        try data.write(to: url, options: .atomic)
    }

    /// Deletes this session's subdirectory (channel_log, tasks, attachments, state).
    /// No-op if the directory doesn't exist. Only valid on a session-scoped manager.
    public func deleteSessionData() throws {
        guard FileManager.default.fileExists(atPath: sessionDirectory.path) else { return }
        try FileManager.default.removeItem(at: sessionDirectory)
    }

    // MARK: - Session State (per-session)

    /// Saves per-session settings (assignments, tunings, tool flags, auto-run).
    public func saveSessionState(_ state: SessionState) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(state)
        let url = sessionDirectory.appendingPathComponent("state.json")
        try data.write(to: url, options: .atomic)
    }

    /// Loads per-session settings. Returns nil if the file doesn't exist yet.
    public func loadSessionState() throws -> SessionState? {
        let url = sessionDirectory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionState.self, from: data)
    }

    // MARK: - Channel Log (per-session)

    public func saveChannelLog(_ messages: [ChannelMessage]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(messages)
        let url = sessionDirectory.appendingPathComponent("channel_log.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadChannelLog() throws -> [ChannelMessage] {
        let url = sessionDirectory.appendingPathComponent("channel_log.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ChannelMessage].self, from: data)
    }

    // MARK: - Tasks (per-session)

    public func saveTasks(_ tasks: [AgentTask]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(tasks)
        let url = sessionDirectory.appendingPathComponent("tasks.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadTasks() throws -> [AgentTask] {
        let url = sessionDirectory.appendingPathComponent("tasks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([AgentTask].self, from: data)
    }

    // MARK: - Memories (shared)

    public func saveMemories(_ memories: [MemoryEntry]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(memories)
        let url = baseDirectory.appendingPathComponent("memories.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadMemories() throws -> [MemoryEntry] {
        let url = baseDirectory.appendingPathComponent("memories.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([MemoryEntry].self, from: data)
    }

    // MARK: - Task Summaries (shared)

    public func saveTaskSummaries(_ summaries: [TaskSummaryEntry]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(summaries)
        let url = baseDirectory.appendingPathComponent("task_summaries.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadTaskSummaries() throws -> [TaskSummaryEntry] {
        let url = baseDirectory.appendingPathComponent("task_summaries.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TaskSummaryEntry].self, from: data)
    }

    // MARK: - Usage Records (shared)

    public func saveUsageRecords(_ records: [UsageRecord]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        let url = baseDirectory.appendingPathComponent("usage_records.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadUsageRecords() throws -> [UsageRecord] {
        let url = baseDirectory.appendingPathComponent("usage_records.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([UsageRecord].self, from: data)
    }

    // MARK: - User Model Overrides (shared)

    public func saveUserModelOverrides(_ overrides: [String: ModelMetadataOverride]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(overrides)
        let url = baseDirectory.appendingPathComponent("model_overrides.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadUserModelOverrides() throws -> [String: ModelMetadataOverride] {
        let url = baseDirectory.appendingPathComponent("model_overrides.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: ModelMetadataOverride].self, from: data)
    }

    // MARK: - Attachments (per-session)

    public func saveAttachment(_ attachment: Attachment) throws {
        guard let fileData = attachment.data else { return }
        try ensureDirectories()
        let safeName = Self.sanitizeFilename(attachment.filename)
        let url = attachmentsDirectory.appendingPathComponent(
            "\(attachment.id.uuidString)_\(safeName)"
        )
        try fileData.write(to: url, options: .atomic)
    }

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

    // MARK: - Legacy Migration

    /// One-shot migration: if the root directory still contains single-session data
    /// (channel_log.json, tasks.json, attachments/) AND the target session directory
    /// doesn't already have that data, move it into the session directory.
    ///
    /// Memories, task summaries, usage records, and model overrides stay at the root
    /// (they're shared). `sessions.json` is written by the caller after migration.
    ///
    /// Returns `true` if any legacy data was migrated, `false` otherwise. Callers use
    /// this return to decide whether to report a user-visible migration message.
    public func migrateLegacyDataIntoSession() throws -> Bool {
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let fm = FileManager.default
        var migratedSomething = false

        // Move channel_log.json
        let legacyChannel = baseDirectory.appendingPathComponent("channel_log.json")
        let newChannel = sessionDirectory.appendingPathComponent("channel_log.json")
        if fm.fileExists(atPath: legacyChannel.path), !fm.fileExists(atPath: newChannel.path) {
            try fm.moveItem(at: legacyChannel, to: newChannel)
            migratedSomething = true
        }

        // Move tasks.json
        let legacyTasks = baseDirectory.appendingPathComponent("tasks.json")
        let newTasks = sessionDirectory.appendingPathComponent("tasks.json")
        if fm.fileExists(atPath: legacyTasks.path), !fm.fileExists(atPath: newTasks.path) {
            try fm.moveItem(at: legacyTasks, to: newTasks)
            migratedSomething = true
        }

        // Move attachments/
        let legacyAttachments = baseDirectory.appendingPathComponent("attachments", isDirectory: true)
        let newAttachments = sessionDirectory.appendingPathComponent("attachments", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: legacyAttachments.path, isDirectory: &isDir), isDir.boolValue,
           !fm.fileExists(atPath: newAttachments.path) {
            try fm.moveItem(at: legacyAttachments, to: newAttachments)
            migratedSomething = true
        }

        return migratedSomething
    }

    /// Strips path components from a filename to prevent directory traversal.
    static func sanitizeFilename(_ filename: String) -> String {
        let stripped = (filename as NSString).lastPathComponent
        return stripped.isEmpty ? "unnamed" : stripped
    }
}
