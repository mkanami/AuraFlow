import AuraWallpaperCore
import Foundation

/// Owns the native bridge's JSON-lines input/output without touching AppKit.
/// Input is serialized by the actor; decoded requests are delivered through a
/// Sendable callback so the application layer can choose its execution actor.
actor NativeBridgeTransport {
    private static let maxInputBufferSize = 64 * 1024

    private let input: FileHandle
    private let output: FileHandle
    private var inputBuffer = Data()
    private var onRequest: (@Sendable (NativeLockScreenBridgeRequest) -> Void)?
    private var onClosed: (@Sendable () -> Void)?

    init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.input = input
        self.output = output
    }

    func start(
        onRequest: @escaping @Sendable (NativeLockScreenBridgeRequest) -> Void,
        onClosed: @escaping @Sendable () -> Void
    ) {
        self.onRequest = onRequest
        self.onClosed = onClosed
        input.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.receive(data)
            }
        }
    }

    func stop() {
        input.readabilityHandler = nil
        onRequest = nil
        onClosed = nil
        inputBuffer.removeAll(keepingCapacity: false)
    }

    func send(_ response: NativeLockScreenBridgeResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        try? output.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            onClosed?()
            return
        }

        guard data.count <= Self.maxInputBufferSize,
              inputBuffer.count <= Self.maxInputBufferSize - data.count
        else {
            // A command must be newline-delimited. Terminate rather than
            // allowing malformed input without a newline to grow forever.
            inputBuffer.removeAll(keepingCapacity: false)
            onClosed?()
            return
        }

        inputBuffer.append(data)
        while let newline = inputBuffer.firstIndex(of: 0x0A) {
            let line = inputBuffer.prefix(upTo: newline)
            inputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let request = try? JSONDecoder().decode(
                      NativeLockScreenBridgeRequest.self,
                      from: line
                  )
            else {
                continue
            }
            onRequest?(request)
        }
    }
}
