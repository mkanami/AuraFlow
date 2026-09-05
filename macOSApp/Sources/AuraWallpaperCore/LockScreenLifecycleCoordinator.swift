import Foundation

/// Events that can affect the secure Lock Screen surface.  They are folded
/// into one serial stream so duplicate shield/session notifications cannot
/// start competing provider operations.
public enum LockScreenLifecycleEvent: Equatable, Sendable {
    case shieldRaised
    case sessionLocked
    case sessionUnlocked
    case wake
    case activeSpaceChanged
    case healthCheck
}

public struct LockScreenLifecycleOperation: Equatable, Sendable {
    public let operationID: UInt64
    public let event: LockScreenLifecycleEvent
    public let expectedLocked: Bool

    public init(
        operationID: UInt64,
        event: LockScreenLifecycleEvent,
        expectedLocked: Bool
    ) {
        self.operationID = operationID
        self.event = event
        self.expectedLocked = expectedLocked
    }
}

/// Small, deterministic state holder used by the agent's main-thread
/// reconciler.  The actual provider work remains outside this type; this
/// object only guarantees monotonic operation IDs, latest-event coalescing,
/// and stale-completion rejection.
public struct LockScreenLifecycleCoordinator: Equatable, Sendable {
    public private(set) var nextOperationID: UInt64 = 0
    public private(set) var inFlightOperationID: UInt64?
    private var inFlightExpectedLocked: Bool?
    public private(set) var desiredLocked = false
    public private(set) var pendingEvent: LockScreenLifecycleEvent?

    public init() {}

    public mutating func enqueue(
        _ event: LockScreenLifecycleEvent
    ) -> LockScreenLifecycleOperation? {
        let previousDesiredLocked = desiredLocked
        let eventRequestsLocked: Bool?
        switch event {
        case .shieldRaised, .sessionLocked:
            eventRequestsLocked = true
        case .sessionUnlocked:
            eventRequestsLocked = false
        case .wake, .activeSpaceChanged, .healthCheck:
            eventRequestsLocked = nil
        }

        if let eventRequestsLocked {
            desiredLocked = eventRequestsLocked
        }

        if let inFlightExpectedLocked {
            if let eventRequestsLocked,
               eventRequestsLocked == inFlightExpectedLocked {
                // A newer request for the state already being applied makes
                // any older pending opposite-state request obsolete.
                pendingEvent = nil
                return nil
            }
            if eventRequestsLocked == nil, pendingEvent != nil {
                // Health/wake notifications do not outrank an explicit mode
                // request that is already queued.
                return nil
            }
            pendingEvent = event
            return nil
        }
        if eventRequestsLocked == nil, pendingEvent != nil {
            return nil
        }
        if let eventRequestsLocked,
           previousDesiredLocked == eventRequestsLocked,
           pendingEvent == nil,
           inFlightOperationID == nil {
            return nil
        }
        return makeOperation(for: event)
    }

    /// Finishes only the currently active operation.  A completion from an
    /// older generation is ignored and cannot clear a newer operation.
    public mutating func finish(
        operationID: UInt64
    ) -> LockScreenLifecycleOperation? {
        guard inFlightOperationID == operationID else {
            return nil
        }
        inFlightOperationID = nil
        inFlightExpectedLocked = nil
        guard let pendingEvent else { return nil }
        self.pendingEvent = nil
        return makeOperation(for: pendingEvent)
    }

    public mutating func invalidate() {
        nextOperationID &+= 1
        inFlightOperationID = nil
        inFlightExpectedLocked = nil
        pendingEvent = nil
    }

    /// Clears a lock intent when an out-of-band notification arrived while
    /// the session is actually active. Without this reset, a later wake or
    /// shield notification could inherit `desiredLocked == true` and repeat
    /// a lock transition that was never confirmed by CGSession.
    public mutating func markSessionUnlocked() {
        desiredLocked = false
        if inFlightExpectedLocked == true {
            pendingEvent = .sessionUnlocked
        } else {
            pendingEvent = nil
        }
    }

    private mutating func makeOperation(
        for event: LockScreenLifecycleEvent
    ) -> LockScreenLifecycleOperation {
        nextOperationID &+= 1
        inFlightOperationID = nextOperationID
        inFlightExpectedLocked = desiredLocked
        return LockScreenLifecycleOperation(
            operationID: nextOperationID,
            event: event,
            expectedLocked: desiredLocked
        )
    }
}
