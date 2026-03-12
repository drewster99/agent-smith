import Testing
import Foundation
@testable import AgentSmithKit

/// Thread-safe container for collecting strings in tests.
private final class MessageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    var messages: [String] {
        lock.withLock { _messages }
    }

    func append(_ value: String) {
        lock.withLock { _messages.append(value) }
    }
}

@Suite("MessageChannel Tests")
struct ChannelTests {
    @Test("Messages are stored in order")
    func messageOrdering() async {
        let channel = MessageChannel()

        await channel.post(ChannelMessage(sender: .user, content: "First"))
        await channel.post(ChannelMessage(sender: .system, content: "Second"))
        await channel.post(ChannelMessage(sender: .agent(.smith), content: "Third"))

        let messages = await channel.allMessages()
        #expect(messages.count == 3)
        #expect(messages[0].content == "First")
        #expect(messages[1].content == "Second")
        #expect(messages[2].content == "Third")
    }

    @Test("Subscribers receive new messages")
    func subscriberNotification() async {
        let channel = MessageChannel()
        let collector = MessageCollector()

        await channel.subscribe { message in
            collector.append(message.content)
        }

        await channel.post(ChannelMessage(sender: .user, content: "Hello"))
        #expect(collector.messages == ["Hello"])
    }

    @Test("Unsubscribed handlers stop receiving")
    func unsubscribe() async {
        let channel = MessageChannel()
        let collector = MessageCollector()

        let subID = await channel.subscribe { message in
            collector.append(message.content)
        }

        await channel.post(ChannelMessage(sender: .user, content: "Before"))
        await channel.unsubscribe(subID)
        await channel.post(ChannelMessage(sender: .user, content: "After"))

        #expect(collector.messages == ["Before"])
    }

    @Test("Messages since index returns correct slice")
    func messagesSinceIndex() async {
        let channel = MessageChannel()

        await channel.post(ChannelMessage(sender: .user, content: "A"))
        await channel.post(ChannelMessage(sender: .user, content: "B"))
        await channel.post(ChannelMessage(sender: .user, content: "C"))

        let since1 = await channel.messages(since: 1)
        #expect(since1.count == 2)
        #expect(since1[0].content == "B")
        #expect(since1[1].content == "C")
    }
}
