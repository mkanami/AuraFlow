import AppKit
import Combine
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
@MainActor
struct TerminalWallpaperSectionInteractionTests {
    @Test(arguments: ["Add a custom command", "Appearance & performance", "Behavior", "Runtime & troubleshooting"])
    func entireCardHeaderTogglesButExpandedControlsDoNot(title: String) async throws {
        let state = SectionState()
        let size = NSSize(width: 540, height: 240)
        let hosting = NSHostingView(rootView: SectionFixture(state: state, title: title))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 30_000_000)

        // The left, middle and far right of the 64-point header all respond.
        for (index, x) in [25.0, 270.0, 515.0].enumerated() {
            let expected = !state.isExpanded
            try click(at: NSPoint(x: x, y: size.height - 44), in: window, eventNumber: index * 2)
            for _ in 0..<20 where state.isExpanded != expected {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(state.isExpanded == expected)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        // The first content control sits below the header, divider and inset.
        try click(at: NSPoint(x: 270, y: size.height - 108), in: window, eventNumber: 10)
        for _ in 0..<20 where state.controlClicks == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(state.controlClicks == 1)
        #expect(state.isExpanded)
    }

    private func click(at point: NSPoint, in window: NSWindow, eventNumber: Int) throws {
        for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber + offset,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
}

@MainActor
private final class SectionState: ObservableObject {
    @Published var isExpanded = false
    @Published var controlClicks = 0
}

private struct SectionFixture: View {
    @ObservedObject var state: SectionState
    let title: String

    var body: some View {
        VStack {
            DisclosureGroup(isExpanded: $state.isExpanded) {
                Button { state.controlClicks += 1 } label: {
                    Text("Content control")
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if title != "Add a custom command" {
                        Text("Section options").font(.caption)
                    }
                }
            }
            .disclosureGroupStyle(TerminalWallpaperDisclosureStyle())
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}
