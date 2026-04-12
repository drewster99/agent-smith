import Testing
import Foundation
@testable import AgentSmithKit

@Suite("Tool Tests")
struct AgentActorTests {
    private func makeContext(
        channel: MessageChannel = MessageChannel(),
        taskStore: TaskStore = TaskStore(),
        role: AgentRole = .brown
    ) throws -> ToolContext {
        ToolContext(
            agentID: UUID(),
            agentRole: role,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in nil },
            memoryStore: MemoryStore(engine: SemanticSearchEngine())
        )
    }

    // MARK: - BashTool

    @Test("BashTool allows safe commands")
    func shellAllowsSafeCommands() async throws {
        let tool = BashTool()
        let result = try await tool.execute(
            arguments: ["command": .string("echo hello")],
            context: makeContext()
        )
        #expect(result.contains("hello"))
    }

    @Test("BashTool allows ls")
    func shellAllowsLs() async throws {
        let tool = BashTool()
        let result = try await tool.execute(
            arguments: ["command": .string("ls /tmp")],
            context: makeContext()
        )
        #expect(result.contains("BLOCKED") == false)
    }

    // MARK: - CreateTaskTool

    @Test("CreateTaskTool adds task to store")
    func createTaskAddsToStore() async throws {
        let taskStore = TaskStore()
        let context = try makeContext(taskStore: taskStore, role: .smith)
        let tool = CreateTaskTool()

        let result = try await tool.execute(
            arguments: [
                "title": .string("Test task"),
                "description": .string("A test")
            ],
            context: context
        )

        #expect(result.contains("Task created"))
        let tasks = await taskStore.allTasks()
        #expect(tasks.count == 1)
        #expect(tasks[0].title == "Test task")
    }

    // MARK: - MessageUserTool

    @Test("MessageUserTool posts to channel")
    func messageUserPostsToChannel() async throws {
        let channel = MessageChannel()
        let context = try makeContext(channel: channel, role: .smith)
        let tool = MessageUserTool()

        _ = try await tool.execute(
            arguments: ["message": .string("Hello world")],
            context: context
        )

        let messages = await channel.allMessages()
        #expect(messages.count == 1)
        #expect(messages[0].content == "Hello world")
    }

    // MARK: - ListTasksTool

    @Test("ListTasksTool returns all tasks")
    func listTasksReturnsAll() async throws {
        let taskStore = TaskStore()
        await taskStore.addTask(title: "Task A", description: "First")
        await taskStore.addTask(title: "Task B", description: "Second")

        let tool = ListTasksTool()
        let result = try await tool.execute(
            arguments: [:],
            context: makeContext(taskStore: taskStore)
        )

        #expect(result.contains("2 task(s)"))
        #expect(result.contains("Task A"))
        #expect(result.contains("Task B"))
    }

    @Test("ListTasksTool filters by status")
    func listTasksFiltersByStatus() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "Done task", description: "Completed")
        await taskStore.updateStatus(id: task.id, status: .completed)
        await taskStore.addTask(title: "Pending task", description: "Waiting")

        let tool = ListTasksTool()
        let result = try await tool.execute(
            arguments: ["status_filter": .string("completed")],
            context: makeContext(taskStore: taskStore)
        )

        #expect(result.contains("1 task(s)"))
        #expect(result.contains("Done task"))
        #expect(!result.contains("Pending task"))
    }

    @Test("ListTasksTool returns empty message when no tasks")
    func listTasksEmpty() async throws {
        let tool = ListTasksTool()
        let result = try await tool.execute(
            arguments: [:],
            context: makeContext()
        )
        #expect(result == "No tasks found.")
    }

    // MARK: - ChannelMessage Codable

    @Test("ChannelMessage decodes old JSON without attachments field")
    func channelMessageBackwardCompat() throws {
        let json = """
        {
            "id": "550E8400-E29B-41D4-A716-446655440000",
            "timestamp": 0,
            "sender": {"user": {}},
            "content": "Hello"
        }
        """
        let data = Data(json.utf8)
        let message = try JSONDecoder().decode(ChannelMessage.self, from: data)
        #expect(message.content == "Hello")
        #expect(message.attachments.isEmpty)
    }

    @Test("ChannelMessage round-trips with attachments")
    func channelMessageRoundTrip() throws {
        let original = ChannelMessage(
            sender: .user,
            content: "With file",
            attachments: [
                Attachment(filename: "test.txt", mimeType: "text/plain", byteCount: 42)
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChannelMessage.self, from: data)
        #expect(decoded.content == "With file")
        #expect(decoded.attachments.count == 1)
        #expect(decoded.attachments[0].filename == "test.txt")
    }

    // MARK: - Filename Sanitization

    @Test("PersistenceManager sanitizes path traversal in filenames")
    func sanitizeFilename() {
        #expect(PersistenceManager.sanitizeFilename("../../../etc/passwd") == "passwd")
        #expect(PersistenceManager.sanitizeFilename("normal.txt") == "normal.txt")
        #expect(PersistenceManager.sanitizeFilename("/absolute/path/file.pdf") == "file.pdf")
        #expect(PersistenceManager.sanitizeFilename("") == "unnamed")
    }

    // MARK: - UpdateTaskTool

    @Test("UpdateTaskTool rejects invalid status")
    func updateTaskRejectsInvalidStatus() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "Test", description: "desc")

        let tool = UpdateTaskTool()
        let result = try await tool.execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "status": .string("bogus")
            ],
            context: makeContext(taskStore: taskStore)
        )

        #expect(result.contains("Invalid status"))
        let stored = await taskStore.task(id: task.id)
        #expect(stored?.status == .pending)
    }

    // MARK: - MockLLMProvider

    @Test("MockLLMProvider returns canned responses in order")
    func mockProviderReturnsCannedResponses() async throws {
        let provider = MockLLMProvider(responses: [
            LLMResponse(text: "Response 1"),
            LLMResponse(text: "Response 2")
        ])

        let r1 = try await provider.send(messages: [], tools: [])
        let r2 = try await provider.send(messages: [], tools: [])

        #expect(r1.text == "Response 1")
        #expect(r2.text == "Response 2")
        #expect(provider.callCount == 2)
    }
}
