import agtermCore
import GhosttyKit
import XCTest
@testable import agterm

@MainActor
final class GhosttySurfaceViewLinkTests: XCTestCase {
    private var clicks: [GhosttySurfaceView.LinkPathClick] = []

    override func setUp() {
        super.setUp()
        clicks = []
        GhosttySurfaceView.linkPathClicked = { [weak self] in self?.clicks.append($0) }
    }

    override func tearDown() {
        GhosttySurfaceView.linkPathClicked = nil
        super.tearDown()
    }

    func testMainAndSplitPanesReportTheirOwnPaneAndCwd() throws {
        let session = Session(initialCwd: "/tmp/main")
        let main = GhosttySurfaceView(workingDirectory: "/tmp/main")
        let split = GhosttySurfaceView(workingDirectory: "/tmp/main")
        main.session = session
        split.session = session
        split.isSplitPane = true
        session.surface = main
        session.splitSurface = split
        split.applyPwd("/tmp/right")

        main.openLink("src/a.swift:12", fromOSC8: false)
        split.openLink("docs/x.md", fromOSC8: false)

        XCTAssertEqual(clicks.map(\.pane), [.left, .right])
        XCTAssertEqual(clicks.map(\.cwd), ["/tmp/main", "/tmp/right"])
        XCTAssertEqual(clicks.map(\.path), ["src/a.swift", "docs/x.md"])
        XCTAssertEqual(clicks.map(\.line), [12, nil])
        XCTAssertTrue(clicks.allSatisfy { $0.session === session })
    }

    func testTheScratchReportsItsOwnCwdWithoutWritingTheSessions() {
        let session = Session(initialCwd: "/tmp/main")
        let scratch = GhosttySurfaceView(workingDirectory: "/tmp/main")
        scratch.focusSession = session
        session.scratchSurface = scratch

        scratch.applyPwd("/tmp/scratch")
        scratch.openLink("src/a.swift", fromOSC8: false)

        XCTAssertEqual(clicks.map(\.pane), [.scratch])
        XCTAssertEqual(clicks.map(\.cwd), ["/tmp/scratch"])
        XCTAssertNil(session.currentCwd)
    }

    func testTheScratchReportsItsLaunchDirectoryBeforeItsFirstPwdReport() {
        let session = Session(initialCwd: "/remote/work")
        let scratch = GhosttySurfaceView(workingDirectory: "/Users/me")
        scratch.focusSession = session
        session.scratchSurface = scratch

        scratch.openLink("src/a.swift", fromOSC8: false)

        XCTAssertEqual(clicks.map(\.cwd), ["/Users/me"])
    }

    func testAnOSC8TargetAnUnownedSurfaceAndANonPathReportNothing() {
        let session = Session(initialCwd: "/tmp/main")
        let main = GhosttySurfaceView(workingDirectory: "/tmp/main")
        main.session = session
        session.surface = main
        let overlay = GhosttySurfaceView(workingDirectory: "/tmp/main")
        overlay.focusSession = session

        main.openLink("src/a.swift", fromOSC8: true)
        overlay.openLink("src/a.swift", fromOSC8: false)
        main.openLink("README.md", fromOSC8: false)

        XCTAssertTrue(clicks.isEmpty)
    }

    func testARemotePaneKeepsTheTildeAndItsLocalScratchExpandsIt() {
        let session = Session(initialCwd: "/remote/work", remoteHost: "buildbox")
        let main = GhosttySurfaceView(workingDirectory: "/remote/work")
        main.session = session
        session.surface = main
        let scratch = GhosttySurfaceView(workingDirectory: NSHomeDirectory())
        scratch.focusSession = session
        session.scratchSurface = scratch

        main.openLink("~/notes.md", fromOSC8: false)
        scratch.openLink("~/notes.md", fromOSC8: false)

        XCTAssertEqual(clicks.map(\.path), ["~/notes.md", NSHomeDirectory() + "/notes.md"])
    }

    func testOpenURLKeepsTheLengthDelimitedTextAndFlagsOnlyOSC8() {
        let bytes = Array("src/a.swift:12trailing".utf8)
        bytes.withUnsafeBufferPointer { buffer in
            let pointer = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
            let osc8 = GhosttyCallbacks.openURL(ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8,
                                                                          url: pointer, len: 14))
            let text = GhosttyCallbacks.openURL(ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT,
                                                                          url: pointer, len: 14))
            let unknown = GhosttyCallbacks.openURL(ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
                                                                             url: pointer, len: 14))
            XCTAssertEqual(osc8?.link, "src/a.swift:12")
            XCTAssertEqual([osc8?.fromOSC8, text?.fromOSC8, unknown?.fromOSC8], [true, false, false])
        }
        XCTAssertNil(GhosttyCallbacks.openURL(ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT,
                                                                       url: nil, len: 0)))
    }

    func testALeadingTildeIsExpandedToHome() {
        let session = Session(initialCwd: "/tmp/main")
        let main = GhosttySurfaceView(workingDirectory: "/tmp/main")
        main.session = session
        session.surface = main

        main.openLink("~/notes/x.md:3", fromOSC8: false)

        XCTAssertEqual(clicks.map(\.path), [NSHomeDirectory() + "/notes/x.md"])
        XCTAssertEqual(clicks.map(\.line), [3])
    }
}
