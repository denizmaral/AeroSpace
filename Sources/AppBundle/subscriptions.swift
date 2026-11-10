import Common
import Foundation
import Network

/// A client of `aerospace subscribe`
@MainActor
final class Subscriber {
    /// The events that the client didn't take yet. A client that stopped reading (e.g. a suspended process) is dropped
    /// when it's that far behind
    static let maxPendingEvents = 256

    private let events: Set<ServerEventType>
    /// Sends the event. The completion is called when the event is on its way to the client, with true if it failed
    private let send: (ServerEvent, _ completion: @escaping @Sendable (_ failed: Bool) -> Void) -> Void
    private let cancel: () -> Void
    private var pendingEvents = 0

    init(
        events: Set<ServerEventType>,
        send: @escaping (ServerEvent, _ completion: @escaping @Sendable (_ failed: Bool) -> Void) -> Void,
        cancel: @escaping () -> Void,
    ) {
        self.events = events
        self.send = send
        self.cancel = cancel
    }

    /// The events of a subscriber are sent in their order, and nobody waits for a subscriber: one that doesn't read its
    /// events doesn't hold up the others
    fileprivate func deliver(_ event: ServerEvent, id: UniqueToken) {
        guard events.contains(event.eventType) else { return }
        guard pendingEvents < Self.maxPendingEvents else {
            subscribers[id] = nil
            cancel()
            return
        }
        pendingEvents += 1
        send(event) { failed in
            Task.startUnstructured { @MainActor in
                self.pendingEvents -= 1
                if failed { subscribers[id] = nil }
            }
        }
    }
}

@MainActor private var subscribers: [UniqueToken: Subscriber] = [:]

@MainActor
@discardableResult
func addSubscriber(_ subscriber: Subscriber) -> UniqueToken {
    let id = UniqueToken()
    subscribers[id] = subscriber
    return id
}

@MainActor
func removeSubscriber(_ id: UniqueToken) {
    subscribers[id] = nil
}

@MainActor
func handleSubscribeAndWaitTillError(_ connection: NWConnection, _ args: SubscribeCmdArgs) async {
    let id = addSubscriber(Subscriber(
        events: args.events,
        send: { event, completion in connection.sendAtomic(event, jsonEncoder) { completion($0 != nil) } },
        cancel: { connection.cancel() },
    ))
    defer { removeSubscriber(id) }
    if args.sendInitial {
        let f = globalFocus
        for eventType in args.events {
            let event: ServerEvent
            switch eventType {
                case .focusChanged:
                    event = .focusChanged(windowId: f.windowOrNil?.windowId, workspace: f.workspace.name)
                case .workspaceChanged:
                    event = .workspaceChanged(workspace: f.workspace.name, prevWorkspace: f.workspace.name)
                case .modeChanged:
                    event = .modeChanged(mode: activeMode)
                case .focusedMonitorChanged:
                    event = .focusedMonitorChanged(
                        workspace: f.workspace.name,
                        monitorId_oneBased: f.workspace.workspaceMonitorInfo.monitorId_oneBased ?? 0,
                    )
                case .windowDetected, .bindingTriggered: continue
            }
            if await connection.writeAtomic(event, jsonEncoder).error != nil {
                return
            }
        }
    }

    // Keep connection alive - wait for client to disconnect
    await connection.readTillError()
}

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return e
}()

func broadcastEvent(_ event: ServerEvent) {
    Task.startUnstructured { @MainActor in deliverToSubscribers(event) }
}

@MainActor
func deliverToSubscribers(_ event: ServerEvent) {
    for (id, subscriber) in subscribers {
        subscriber.deliver(event, id: id)
    }
}
