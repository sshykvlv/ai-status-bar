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
        let procs = [p(12, 1), p(13, 12), p(20, 1), p(21, 20)]
        XCTAssertEqual(ProcessKiller.forcePlan(c, procs: procs, ownPid: 99, ownUid: 501),
                       [13, 21, 12, 20])
    }
}
