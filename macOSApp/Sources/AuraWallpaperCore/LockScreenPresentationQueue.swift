import Foundation

/// Serializes opaque system presentation calls, which may finish even after
/// cancellation. The last committed surface stays retained until a complete,
/// current replacement is ready; failures and stale completions never clear it.
@MainActor
public final class LockScreenPresentationQueue<Surface> {
    public struct Request: Equatable, Sendable {
        public let id: UInt64
        public let locked: Bool
        public let routeRevision: UInt64
        public let reloadRoute: Bool
    }

    public private(set) var surface: Surface?
    public var onApplied: ((Request) -> Void)?
    public var onFailure: ((Request, Error) -> Void)?
    private let prepare: @MainActor (Request, Surface?) async throws -> Surface
    private var generation: UInt64 = 0
    private var routeRevision: UInt64 = 0
    private var preparedRouteRevision: UInt64 = 0
    private var pending: Request?
    private var task: Task<Void, Never>?
    private var workerID: UInt64 = 0

    public init(prepare: @escaping @MainActor (Request, Surface?) async throws -> Surface) {
        self.prepare = prepare
    }

    @discardableResult
    public func request(locked: Bool, reloadRoute: Bool = false) -> UInt64 {
        if reloadRoute { routeRevision &+= 1 }
        generation &+= 1
        pending = Request(id: generation, locked: locked, routeRevision: routeRevision,
                          reloadRoute: reloadRoute || preparedRouteRevision != routeRevision)
        guard task == nil else { return generation }
        workerID &+= 1
        let worker = workerID
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.workerID == worker, let request = self.pending {
                self.pending = nil
                do {
                    let next = try await self.prepare(request, self.surface)
                    guard !Task.isCancelled, self.workerID == worker else { return }
                    guard self.isCurrent(request.id) else { continue }
                    self.surface = next
                    self.preparedRouteRevision = request.routeRevision
                    self.onApplied?(request)
                } catch {
                    guard !Task.isCancelled, self.workerID == worker else { return }
                    guard self.isCurrent(request.id) else { continue }
                    self.onFailure?(request, error)
                }
            }
            if self.workerID == worker { self.task = nil }
        }
        return generation
    }

    public func isCurrent(_ requestID: UInt64) -> Bool { generation == requestID }

    public func stop() {
        generation &+= 1
        workerID &+= 1
        task?.cancel()
        task = nil
        pending = nil
        surface = nil
        preparedRouteRevision = routeRevision
    }
}
