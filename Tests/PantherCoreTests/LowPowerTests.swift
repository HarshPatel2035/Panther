import Foundation
import Testing
@testable import PantherCore

@MainActor
@Suite("Low Power Mode")
struct LowPowerTests {
    @Test("Closing the lid on battery during a session turns it on, journaled first")
    func lidClosedOnBattery() throws {
        let w = World()
        w.controller.update(World.open)
        _ = try w.controller.start(.timed(duration: 3_600, label: "t"))
        #expect(w.lowPower.isLowPowerOn() == false)
        w.controller.update(World.headlessClosed)
        #expect(w.lowPower.isLowPowerOn() == true)
        let entries = w.log.all
        let flagged = entries.lastIndex { $0.hasPrefix("journal") }
        let switched = entries.firstIndex(of: "lowpower=1")
        #expect(flagged != nil && switched != nil && flagged! < switched!)
        #expect(w.store.current?.lowPowerSetByPanther == true)
    }

    @Test("Opening the lid or plugging in turns it back off")
    func backOff() throws {
        let w = World()
        w.controller.update(World.headlessClosed)
        _ = try w.controller.start(.timed(duration: 3_600, label: "t"))
        #expect(w.lowPower.isLowPowerOn() == true)       // started with the lid already closed
        w.controller.update(World.open)
        #expect(w.lowPower.isLowPowerOn() == false)
        w.controller.update(World.headlessClosed)
        w.controller.update(World.headlessClosed.with(power: PowerSnapshot(onBattery: false, percent: 80)))
        #expect(w.lowPower.isLowPowerOn() == false)
        #expect(w.store.current?.lowPowerSetByPanther == false)
    }

    @Test("Ending the session turns it off before the Mac is put to sleep")
    func offBeforeSleepNow() throws {
        let w = World()
        w.controller.update(World.headlessClosed)
        _ = try w.controller.start(.timed(duration: 600, label: "t"))
        try w.controller.end(id: nil)
        let entries = w.log.all
        #expect(w.lowPower.isLowPowerOn() == false)
        #expect(entries.firstIndex(of: "lowpower=0")! < entries.firstIndex(of: "sleepNow")!)
    }

    @Test("Low battery turns it on even with the lid open")
    func lowBatteryLidOpen() throws {
        let w = World()
        w.controller.update(World.open.with(power: PowerSnapshot(onBattery: true, percent: 25)))
        _ = try w.controller.start(.timed(duration: 600, label: "t"))
        #expect(w.lowPower.isLowPowerOn() == true)
    }

    @Test("Never outside a session, and never at a desk with an external display")
    func notWhenUnneeded() throws {
        let w = World()
        w.controller.update(World.headlessClosed)
        #expect(w.lowPower.isLowPowerOn() == false)
        w.controller.update(World.deskClosed.with(power: PowerSnapshot(onBattery: true, percent: 80)))
        _ = try w.controller.start(.timed(duration: 600, label: "t"))
        #expect(w.lowPower.isLowPowerOn() == false)
    }

    @Test("Your own Low Power Mode is left alone, before and after")
    func respectsUserSetting() throws {
        let w = World()
        w.lowPower.userSet(true)
        w.controller.update(World.headlessClosed)
        _ = try w.controller.start(.timed(duration: 600, label: "t"))
        try w.controller.end(id: nil)
        #expect(w.lowPower.isLowPowerOn() == true)
        #expect(!w.log.all.contains { $0.hasPrefix("lowpower=") })
    }

    @Test("After a crash, Low Power Mode that Panther turned on is turned off")
    func reconcileTurnsOff() {
        let w = World(journal: Journal(bootSessionUUID: World.boot, sleepDisabledByPanther: false, holds: [],
                                       lowPowerSetByPanther: true))
        w.lowPower.userSet(true)
        w.controller.reconcile()
        #expect(w.lowPower.isLowPowerOn() == false)
        #expect(w.controller.lowPowerByUs == false)
    }

    @Test("A failed switch-off is retried on the next tick")
    func retry() throws {
        let w = World()
        w.controller.update(World.headlessClosed)
        _ = try w.controller.start(.timed(duration: 3_600, label: "t"))
        w.lowPower.failSets = true
        w.controller.update(World.open)
        #expect(w.controller.lowPowerByUs)
        w.lowPower.failSets = false
        w.controller.tick()
        #expect(w.lowPower.isLowPowerOn() == false)
    }

    @Test("Journals from before Low Power support still load")
    func oldJournal() throws {
        let json = #"{"version":1,"bootSessionUUID":"b","sleepDisabledByPanther":false,"holds":[]}"#
        let journal = try JSONDecoder().decode(Journal.self, from: Data(json.utf8))
        #expect(journal.lowPowerSetByPanther == nil)
    }
}
