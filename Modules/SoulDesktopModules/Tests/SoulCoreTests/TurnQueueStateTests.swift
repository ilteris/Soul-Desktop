import Testing
@testable import SoulCore

@Suite("TurnQueueState")
struct TurnQueueStateTests {
    @Test
    func idlePromptClaimsActiveTurn() {
        var state = TurnQueueState()

        #expect(state.acceptPrompt() == .dispatchNow)
        #expect(state.isWorking)
        #expect(state.queuedCount == 0)
    }

    @Test
    func workingPromptQueuesBehindActiveTurn() {
        var state = TurnQueueState(isWorking: true)

        #expect(state.acceptPrompt() == .queued)
        #expect(state.isWorking)
        #expect(state.queuedCount == 1)
    }

    @Test
    func claimQueuedPromptKeepsWorkerActiveAndDrainsOne() {
        var state = TurnQueueState(isWorking: true, queuedCount: 2)

        let firstClaim = state.claimQueuedPromptForDispatch()
        #expect(firstClaim)
        #expect(state.isWorking)
        #expect(state.queuedCount == 1)
        let secondClaim = state.claimQueuedPromptForDispatch()
        #expect(secondClaim)
        #expect(state.queuedCount == 0)
        let emptyClaim = state.claimQueuedPromptForDispatch()
        #expect(!emptyClaim)
    }

    @Test
    func completeActiveTurnReportsWhetherQueueCanDrain() {
        var withQueue = TurnQueueState(isWorking: true, queuedCount: 1)
        var withoutQueue = TurnQueueState(isWorking: true, queuedCount: 0)

        let queuedDrainAvailable = withQueue.completeActiveTurn()
        #expect(queuedDrainAvailable)
        #expect(!withQueue.isWorking)
        let queuedDrainUnavailable = withoutQueue.completeActiveTurn()
        #expect(!queuedDrainUnavailable)
        #expect(!withoutQueue.isWorking)
    }

    @Test
    func steerRequiresActiveTurnAndQueuedPrompt() {
        var ready = TurnQueueState(isWorking: true, queuedCount: 1)
        var idle = TurnQueueState(isWorking: false, queuedCount: 1)
        var empty = TurnQueueState(isWorking: true, queuedCount: 0)

        let readySteer = ready.requestSteerToNextQueuedPrompt()
        #expect(readySteer)
        #expect(ready.steerPending)
        let consumedSteer = ready.consumeSteerPending()
        #expect(consumedSteer)
        #expect(!ready.steerPending)
        let idleSteer = idle.requestSteerToNextQueuedPrompt()
        let emptySteer = empty.requestSteerToNextQueuedPrompt()
        #expect(!idleSteer)
        #expect(!emptySteer)
    }

    @Test
    func steerRequestIsNotReentrantWhileProviderCancelIsPending() {
        var state = TurnQueueState(isWorking: true, queuedCount: 2)

        let firstRequest = state.requestSteerToNextQueuedPrompt()
        #expect(firstRequest)
        #expect(state.steerPending)
        let secondRequest = state.requestSteerToNextQueuedPrompt()
        #expect(!secondRequest)
        #expect(state.steerPending)
        #expect(state.queuedCount == 2)
    }

    @Test
    func clearAndCancelResetQueueState() {
        var clearing = TurnQueueState(isWorking: true, queuedCount: 3, steerPending: true)
        clearing.clearQueuedPrompts()
        #expect(clearing.isWorking)
        #expect(clearing.queuedCount == 0)
        #expect(!clearing.steerPending)

        var cancelling = TurnQueueState(isWorking: true, queuedCount: 2, steerPending: true)
        cancelling.cancelActiveTurnAndClearQueue()
        #expect(!cancelling.isWorking)
        #expect(cancelling.queuedCount == 0)
        #expect(!cancelling.steerPending)
    }
}
