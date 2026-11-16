import XCTest
@testable import AIStatusBar

final class ProcessKillerTests: XCTestCase {
    private func p(_ pid: Int32, _ ppid: Int32, uid: uid_t = 501) -> ProcSample {
        ProcSample(pid: pid, ppid: ppid, pgid: pid, uid: uid, name: "x", path: "",
                   footprint: 0, cpuTime: 0, startedAt: .distantPast)
    }

    func testKillTargetsExcludeSelfAndAncestors() {
        // Приложение запущено из сессии Claude: claude 12 → zsh 30 → AIStatusBar 31.
        let procs = [p(12, 1), p(30, 12), p(31, 30), p(13, 12), p(50, 1, uid: 0)]
        let t = ProcessKiller.targets([0, 1, 12, 30, 31, 50, 13, 777], procs: procs,
                                      ownPid: 31, ownUid: 501)
        XCTAssertEqual(t, [13])
    }

    func testForceOrderKillsHelpersBeforeRoots() {
        let c = Consumer(key: "agent:Claude Code", title: "Claude Code", kind: .agent,
                         rootPids: [12, 20], allPids: [12, 13, 20, 21], footprint: 0,
                         cpuPercent: 0, helpers: 2)
        let procs = [p(12, 1), p(13, 12), p(20, 1), p(21, 20), p(99, 1)]
        XCTAssertEqual(ProcessKiller.forcePlan(c, old: procs, fresh: procs, ownPid: 99, ownUid: 501),
                       [13, 21, 12, 20])
    }

    func testAncestryUsesFullFreshListAndFailsClosed() {
        // claude 12 → zsh 30 → app 31. Shell 30 не было в старом снимке (родился
        // позже) — защита предка 12 всё равно должна сработать по свежему списку.
        let fresh = [p(12, 1), p(30, 12), p(31, 30), p(13, 12)]
        let old = [p(12, 1), p(31, 30), p(13, 12)]
        XCTAssertEqual(ProcessKiller.liveTargets([12, 13], old: old, fresh: fresh,
                                                 ownPid: 31, ownUid: 501), [13])
        // Цепочка своего процесса рвётся (родителя 30 нет в списке) — не трогаем никого.
        let broken = [p(12, 1), p(31, 30), p(13, 12)]
        XCTAssertEqual(ProcessKiller.liveTargets([13], old: broken, fresh: broken,
                                                 ownPid: 31, ownUid: 501), [])
    }

    func testRecycledPidIsDropped() {
        var old = p(40, 1); old.startedAt = Date(timeIntervalSince1970: 100)
        var reborn = p(40, 1); reborn.startedAt = Date(timeIntervalSince1970: 200)
        var same = p(41, 1); same.startedAt = Date(timeIntervalSince1970: 100)
        let live = ProcessKiller.stillSame(old: [old, same], fresh: [reborn, same])
        XCTAssertEqual(live.map(\.pid), [41])
    }
}
