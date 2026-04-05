import Foundation
import os

/// Shared process execution logic for BashTool.
///
/// Handles incremental output reading, process group management, and timeouts correctly —
/// including commands that spawn backgrounded child processes (e.g., `cmd &`).
enum ProcessRunner {
    struct Result: Sendable {
        let output: String
        let exitCode: Int32
        let timedOut: Bool
    }

    /// Runs a command and returns its output.
    ///
    /// - Uses `readabilityHandler` for incremental output collection (avoids pipe buffer deadlock).
    /// - Creates a process group so the timeout can kill all children, including backgrounded ones.
    /// - Ties "done reading" to the shell process exiting, not to the pipe closing — so backgrounded
    ///   children that inherit the pipe don't block us indefinitely.
    static func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        timeout: TimeInterval
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
            
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe

                if let workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
                }

                // Serial queue to serialize all pipe reads (FileHandle is not thread-safe).
                let readQueue = DispatchQueue(label: "process-runner-read")
                var buffer = Data()
                var pipeIsClosed = false

                let done = DispatchSemaphore(value: 0)
                let didTimeout = OSAllocatedUnfairLock(initialState: false)

                // Read output incrementally as it arrives. This prevents the pipe buffer
                // (~64KB) from filling up and blocking the process on write.
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    readQueue.sync {
                        guard !pipeIsClosed else { return }
                        let chunk = handle.availableData
                        if !chunk.isEmpty {
                            buffer.append(chunk)
                        }
                    }
                }

                // When the shell exits, drain remaining output and close the pipe.
                // Closing our read end causes backgrounded children to get SIGPIPE on
                // their next write — they won't hold us open.
                process.terminationHandler = { _ in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    readQueue.sync {
                        guard !pipeIsClosed else { return }
                        let remaining = pipe.fileHandleForReading.availableData
                        if !remaining.isEmpty {
                            buffer.append(remaining)
                        }
                        pipeIsClosed = true
                        // close() can throw if the fd is already closed (e.g., process never started).
                        // This is expected and safe to ignore — we're done with the pipe.
                        do { try pipe.fileHandleForReading.close() } catch { /* fd already closed */ }
                    }
                    done.signal()
                }

                // Prevent interactive prompts from hanging the process indefinitely.
                // Without this, SSH/git may wait for a passphrase on stdin that will never arrive.
                process.standardInput = FileHandle.nullDevice
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"  // git: don't prompt for credentials
                env["SSH_ASKPASS"] = ""            // SSH: don't invoke GUI askpass program
                process.environment = env

                do {
                    try process.run()

                    // Put the process in its own group so the timeout can kill all children.
                    let pgidResult = setpgid(process.processIdentifier, process.processIdentifier)
                    if pgidResult == -1 {
                        let logger = Logger(subsystem: "AgentSmith", category: "ProcessRunner")
                        logger.debug("setpgid failed for pid \(process.processIdentifier): \(String(cString: strerror(errno)))")
                    }

                    // Schedule timeout — kills the entire process group.
                    let pid = process.processIdentifier
                    let timeoutItem = DispatchWorkItem {
                        didTimeout.withLock { $0 = true }
                        kill(-pid, SIGTERM)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            kill(-pid, SIGKILL)
                        }
                    }
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + timeout,
                        execute: timeoutItem
                    )

                    // Wait for shell to exit (normal completion or timeout kill).
                    done.wait()
                    timeoutItem.cancel()

                    let data = readQueue.sync { buffer }
                    let output = String(data: data, encoding: .utf8)
                        ?? "Error: output could not be decoded as UTF-8 (\(data.count) bytes)"
                    let status = process.terminationStatus

                    let timedOut = didTimeout.withLock { $0 }
                    continuation.resume(returning: Result(
                        output: output,
                        exitCode: status,
                        timedOut: timedOut
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
