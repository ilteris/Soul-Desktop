import Foundation

/// UI-free state machine for Soul Desktop's single-active-turn queue.
///
/// The app target still owns prompt payloads, rendering, provider RPC, and
/// ledger writes. This type only defines the state transitions that decide
/// whether a prompt dispatches now, waits in the queue, is skipped ahead, or
/// is dropped during cancellation.
public struct TurnQueueState: Equatable, Sendable {
    public enum Acceptance: Equatable, Sendable {
        case dispatchNow
        case queued
    }

    public private(set) var isWorking: Bool
    public private(set) var queuedCount: Int
    public private(set) var steerPending: Bool

    public init(isWorking: Bool = false, queuedCount: Int = 0, steerPending: Bool = false) {
        self.isWorking = isWorking
        self.queuedCount = max(0, queuedCount)
        self.steerPending = steerPending
    }

    public var hasQueuedPrompt: Bool {
        queuedCount > 0
    }

    public var canSkipAhead: Bool {
        hasQueuedPrompt
    }

    public mutating func acceptPrompt() -> Acceptance {
        if isWorking {
            queuedCount += 1
            return .queued
        }

        isWorking = true
        return .dispatchNow
    }

    @discardableResult
    public mutating func claimQueuedPromptForDispatch() -> Bool {
        guard queuedCount > 0 else { return false }
        queuedCount -= 1
        isWorking = true
        return true
    }

    @discardableResult
    public mutating func completeActiveTurn() -> Bool {
        isWorking = false
        return hasQueuedPrompt
    }

    @discardableResult
    public mutating func requestSteerToNextQueuedPrompt() -> Bool {
        guard isWorking, hasQueuedPrompt else { return false }
        steerPending = true
        return true
    }

    @discardableResult
    public mutating func consumeSteerPending() -> Bool {
        let wasPending = steerPending
        steerPending = false
        return wasPending
    }

    public mutating func clearQueuedPrompts() {
        queuedCount = 0
        steerPending = false
    }

    public mutating func cancelActiveTurnAndClearQueue() {
        isWorking = false
        clearQueuedPrompts()
    }
}
