import Foundation
import Testing
@testable import PantherCore

@MainActor
@Suite("Ownership, caps and client-supplied data")
struct AuthorizationTests {
    @Test("A user can end and extend only their own sessions; root can touch any")
    func ownership() throws {
        let w = World()
        let alice = try w.controller.start(.timed(duration: 600, label: "a"), owner: 501)
        _ = try w.controller.start(.timed(duration: 600, label: "b"), owner: 502)

        #expect(throws: PantherError.noSuchHold) { try w.controller.end(id: alice.id, caller: 502) }
        #expect(throws: PantherError.noSuchHold) { try w.controller.extend(id: alice.id, by: 600, caller: 502) }

        try w.controller.end(id: nil, caller: 502)          // ends only 502's session
        #expect(w.controller.holds.map(\.ownerUID) == [501])
        #expect(w.sleep.readSleepDisabled() == true)

        try w.controller.end(id: nil, caller: 0)            // root ends the rest
        #expect(w.controller.holds.isEmpty)
    }

    @Test("Ending with nothing of your own is an error, even if others have sessions")
    func endNothingOwned() throws {
        let w = World()
        _ = try w.controller.start(.timed(duration: 600, label: "a"), owner: 501)
        #expect(throws: PantherError.noSuchHold) { try w.controller.end(id: nil, caller: 777) }
        #expect(w.controller.holds.count == 1)
    }

    @Test("The number of sessions is capped")
    func holdCap() throws {
        let w = World()
        for i in 0..<HoldController.maxHolds { _ = try w.controller.start(.timed(duration: 600, label: "\(i)")) }
        #expect(throws: PantherError.self) { try w.controller.start(.timed(duration: 600, label: "one too many")) }
    }

    @Test("A client's external-display report expires, so a stale 'true' can't disable the bag rule")
    func displayReportExpires() throws {
        let w = World()
        w.controller.update(World.headlessClosed)
        w.controller.reportExternalDisplay(true)
        #expect(w.controller.environment.externalDisplay == true)
        w.clock.advance(HoldController.displayReportLifetime + 1)
        w.controller.tick()
        #expect(w.controller.environment.externalDisplay == nil)
        #expect(w.controller.environment.isHeadlessClosed)
    }

    @Test("Labels are stripped of control characters and bounded", arguments: [
        ("python\nFAKE LOG LINE", "pythonFAKE LOG LINE"),
        ("   ", "session"),
        (String(repeating: "x", count: 500), String(repeating: "x", count: Hold.maxLabelLength)),
        ("make …", "make …"),
    ])
    func labels(raw: String, expected: String) throws {
        let w = World()
        let hold = try w.controller.start(.timed(duration: 600, label: raw))
        #expect(hold.label == expected)
    }

    @Test("Journals without an owner still load; such a session belongs to root")
    func journalCompatibility() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":{"timed":{}},"label":"t","startedAt":0,"endsAt":600}"#
        let hold = try JSONDecoder().decode(Hold.self, from: Data(json.utf8))
        #expect(hold.ownerUID == nil)
        #expect(!hold.isControllable(by: 501))
        #expect(hold.isControllable(by: 0))
    }
}
