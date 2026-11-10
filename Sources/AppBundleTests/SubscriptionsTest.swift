@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct SubscriptionsTest {
    /// A client of `aerospace subscribe`, and what the server did with it
    private final class Client {
        @MainActor var received: [ServerEvent] = []
        @MainActor var completions: [@Sendable (Bool) -> Void] = []
        @MainActor var isCanceled = false
    }

    private func subscribe(_ client: Client, takesEvents: Bool) -> UniqueToken {
        addSubscriber(Subscriber(
            events: [.modeChanged],
            send: { event, completion in
                client.received.append(event)
                if takesEvents { completion(false) } else { client.completions.append(completion) }
            },
            cancel: { client.isCanceled = true },
        ))
    }

    /// A subscriber that stopped reading (e.g. a suspended process) doesn't hold up the events of the others, and it's
    /// dropped when it's too far behind
    @Test func testAStalledSubscriberDoesntBlockTheOthers() async {
        let stalled = Client()
        let reader = Client()
        let ids = [subscribe(stalled, takesEvents: false), subscribe(reader, takesEvents: true)]
        defer { ids.forEach(removeSubscriber) }

        for index in 0 ..< Subscriber.maxPendingEvents {
            deliverToSubscribers(.modeChanged(mode: String(index)))
            deliverToSubscribers(.focusChanged(windowId: nil, workspace: "not subscribed"))
            await settle()
        }
        assertEquals(reader.received.count, Subscriber.maxPendingEvents)
        assertEquals(stalled.received.count, Subscriber.maxPendingEvents) // Queued for it, in their order
        assertEquals(stalled.isCanceled, false)

        deliverToSubscribers(.modeChanged(mode: "one too many"))
        assertEquals(stalled.isCanceled, true)
        await settle()
        deliverToSubscribers(.modeChanged(mode: "after"))
        assertEquals(stalled.received.count, Subscriber.maxPendingEvents)
        assertEquals(reader.received.count, Subscriber.maxPendingEvents + 2)
        assertEquals(reader.isCanceled, false)
    }

    /// A subscriber that falls behind and catches up again stays subscribed
    @Test func testASlowSubscriberCatchesUp() async {
        let slow = Client()
        let id = subscribe(slow, takesEvents: false)
        defer { removeSubscriber(id) }

        for round in 0 ..< 3 {
            for index in 0 ..< Subscriber.maxPendingEvents { deliverToSubscribers(.modeChanged(mode: "\(round) \(index)")) }
            let completions = slow.completions
            slow.completions = []
            completions.forEach { $0(false) }
            await settle()
        }
        assertEquals(slow.isCanceled, false)
        assertEquals(slow.received.count, 3 * Subscriber.maxPendingEvents)
    }

    /// The completions are counted on the main actor, in tasks: let them run
    private func settle() async {
        for _ in 0 ..< 3 { await Task.yield() }
    }
}
