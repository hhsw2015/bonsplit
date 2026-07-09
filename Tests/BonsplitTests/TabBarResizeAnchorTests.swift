import AppKit
@testable import Bonsplit
import SwiftUI
import XCTest

@MainActor
final class TabBarResizeAnchorTests: XCTestCase {
    func testViewportResizeKeepsLeadingAnchoredWhenTabStripWasLeadingAligned() throws {
        let harness = try makeTabBarHarness(
            initialSize: NSSize(width: 900, height: TabBarMetrics.barHeight),
            tabCount: 8,
            selectedIndex: 2
        )
        defer { harness.window.orderOut(nil) }

        let scrollView = try tabBarScrollView(in: harness.hostingView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, 0, accuracy: 0.5)

        harness.window.setContentSize(NSSize(width: 240, height: TabBarMetrics.barHeight))
        harness.hostingView.frame = harness.window.contentView?.bounds ?? harness.hostingView.frame
        settleLayout(in: harness.window, hostingView: harness.hostingView) {
            abs(scrollView.contentView.bounds.origin.x) <= 0.5
        }

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.x,
            0,
            accuracy: 0.5,
            "A pure pane/window resize must preserve the leading tab-strip anchor instead of recentering the selected tab and shifting icons."
        )
    }

    func testViewportResizeClampsExistingOverflowOffsetToNewRange() throws {
        let harness = try makeTabBarHarness(
            initialSize: NSSize(width: 240, height: TabBarMetrics.barHeight),
            tabCount: 8,
            selectedIndex: 7
        )
        defer { harness.window.orderOut(nil) }

        let scrollView = try tabBarScrollView(in: harness.hostingView)
        let initialMaxOffset = maxHorizontalOffset(in: scrollView)
        XCTAssertGreaterThan(initialMaxOffset, 0)

        scrollView.contentView.scroll(to: NSPoint(x: initialMaxOffset, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, initialMaxOffset, accuracy: 0.5)

        harness.window.setContentSize(NSSize(width: 360, height: TabBarMetrics.barHeight))
        harness.hostingView.frame = harness.window.contentView?.bounds ?? harness.hostingView.frame
        settleLayout(in: harness.window, hostingView: harness.hostingView) {
            let expectedOffset = maxHorizontalOffset(in: scrollView)
            return expectedOffset > 0
                && abs(scrollView.contentView.bounds.origin.x - expectedOffset) <= 0.5
        }

        let expectedOffset = maxHorizontalOffset(in: scrollView)
        XCTAssertGreaterThan(expectedOffset, 0)
        XCTAssertLessThan(expectedOffset, initialMaxOffset)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.x,
            expectedOffset,
            accuracy: 0.5,
            "A resize that reduces the valid scroll range must clamp the existing offset instead of resetting or recentering the tab strip."
        )
    }

    func testAsyncClampRetryDoesNotUndoLaterValidOffset() async throws {
        let harness = try makeTabBarHarness(
            initialSize: NSSize(width: 240, height: TabBarMetrics.barHeight),
            tabCount: 8,
            selectedIndex: 7
        )
        defer { harness.window.orderOut(nil) }

        let scrollView = try tabBarScrollView(in: harness.hostingView)
        let initialMaxOffset = maxHorizontalOffset(in: scrollView)
        XCTAssertGreaterThan(initialMaxOffset, 0)

        scrollView.contentView.scroll(to: NSPoint(x: initialMaxOffset, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        var laterValidOffset: CGFloat?
        let laterScrollApplied = expectation(description: "later valid scroll applied")
        DispatchQueue.main.async {
            let validOffset = self.maxHorizontalOffset(in: scrollView) / 2
            laterValidOffset = validOffset
            scrollView.contentView.scroll(to: NSPoint(x: validOffset, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            laterScrollApplied.fulfill()
        }

        harness.window.setContentSize(NSSize(width: 360, height: TabBarMetrics.barHeight))
        harness.hostingView.frame = harness.window.contentView?.bounds ?? harness.hostingView.frame
        harness.window.contentView?.layoutSubtreeIfNeeded()
        harness.hostingView.layoutSubtreeIfNeeded()

        let queuedCorrectionsDrained = expectation(description: "queued corrections drained")
        DispatchQueue.main.async {
            queuedCorrectionsDrained.fulfill()
        }
        await fulfillment(of: [laterScrollApplied, queuedCorrectionsDrained], timeout: 1)
        let expectedOffset = try XCTUnwrap(laterValidOffset)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.x,
            expectedOffset,
            accuracy: 0.5,
            "The queued clamp retry must not overwrite a later scroll position that is already inside the resized tab strip's valid range."
        )
    }

    private struct TabBarHarness {
        let window: NSWindow
        let hostingView: NSView
    }

    private func makeTabBarHarness(
        initialSize: NSSize,
        tabCount: Int,
        selectedIndex: Int
    ) throws -> TabBarHarness {
        let controller = BonsplitController(configuration: BonsplitConfiguration(appearance: .default))
        controller.tabShortcutHintsEnabled = false
        let pane = try XCTUnwrap(controller.internalController.rootNode.allPanes.first)

        let tabs = (0..<tabCount).map { index in
            TabItem(title: "Terminal \(index + 1)", icon: "terminal.fill", kind: "terminal")
        }
        pane.tabs = tabs
        pane.selectedTabId = tabs[selectedIndex].id

        let hostingView = NSHostingView(
            rootView: TabBarView(pane: pane, isFocused: true, showSplitButtons: false)
                .environment(controller)
                .environment(controller.internalController)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        let contentView = try XCTUnwrap(window.contentView)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        settleLayout(in: window, hostingView: hostingView) {
            tabBarScrollViews(in: hostingView).count == 1
        }

        return TabBarHarness(window: window, hostingView: hostingView)
    }

    private func settleLayout(
        in window: NSWindow,
        hostingView: NSView,
        until condition: () -> Bool
    ) {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            if condition() {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        window.contentView?.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    private func tabBarScrollView(
        in root: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSScrollView {
        let matches = tabBarScrollViews(in: root)
        XCTAssertEqual(
            matches.count,
            1,
            "The harness should expose exactly one tab-bar-sized scroll view.",
            file: file,
            line: line
        )
        return try XCTUnwrap(matches.first, file: file, line: line)
    }

    private func tabBarScrollViews(in root: NSView) -> [NSScrollView] {
        descendants(ofType: NSScrollView.self, in: root).filter { scrollView in
            let documentHeight = max(
                scrollView.documentView?.frame.height ?? 0,
                scrollView.documentView?.bounds.height ?? 0
            )
            return abs(scrollView.frame.height - TabBarMetrics.barHeight) <= 0.5
                && abs(documentHeight - TabBarMetrics.barHeight) <= 0.5
                && scrollView.frame.width > 0
        }
    }

    private func maxHorizontalOffset(in scrollView: NSScrollView) -> CGFloat {
        let documentWidth = max(
            scrollView.documentView?.frame.width ?? 0,
            scrollView.documentView?.bounds.width ?? 0
        )
        return max(0, documentWidth - scrollView.contentView.bounds.width)
    }

    private func descendants<T: NSView>(ofType type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        if let match = root as? T {
            matches.append(match)
        }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(ofType: type, in: subview))
        }
        return matches
    }
}
