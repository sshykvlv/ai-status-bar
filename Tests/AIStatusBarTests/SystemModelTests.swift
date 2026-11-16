import XCTest
@testable import AIStatusBar

final class SystemModelTests: XCTestCase {
    let me: uid_t = 501
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func p(_ pid: Int32, _ ppid: Int32, pgid: Int32? = nil, name: String,
                   path: String? = nil, mb: UInt64 = 10, uid: uid_t = 501,
                   age: TimeInterval = 7200, args: [String] = []) -> ProcSample {
        ProcSample(pid: pid, ppid: ppid, pgid: pgid ?? pid, uid: uid, name: name,
                   path: path ?? "/usr/local/bin/\(name)", footprint: mb * 1_048_576,
                   cpuTime: 0, startedAt: now.addingTimeInterval(-age), args: args)
    }

    func testAgentAbsorbsHelpers() {
        let procs = [
            p(10, 1, name: "Orca", path: "/Applications/Orca.app/Contents/MacOS/Orca", mb: 300),
            p(11, 10, name: "zsh", path: "/bin/zsh", mb: 5),
            p(12, 11, name: "claude", mb: 400),
            p(13, 12, name: "node", mb: 80, args: ["node", "mcp-server.js"]),
            p(20, 11, name: "claude", mb: 300),
            p(21, 20, name: "uv", mb: 5),
            p(22, 21, name: "python3.15", mb: 40),
        ]
        let groups = SystemModel.group(procs, cpuPercentByPid: [:], ownUid: me)
        let claude = groups.first { $0.title == "Claude Code" }
        XCTAssertEqual(claude?.kind, .agent)
        XCTAssertEqual(claude?.rootPids.sorted(), [12, 20])
        XCTAssertEqual(claude?.helpers, 3)
        XCTAssertEqual(claude?.footprint, (400 + 80 + 300 + 5 + 40) * 1_048_576)
        let orca = groups.first { $0.title == "Orca" }
        XCTAssertEqual(orca?.allPids, [10])
        XCTAssertEqual(groups.first { $0.title == "zsh" }?.allPids, [11])
        // Сортировка — по памяти.
        XCTAssertEqual(groups.first?.title, "Claude Code")
    }

    func testAppBundleOutermost() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let groups = SystemModel.group([
            p(40, 1, name: "Google Chrome", path: chrome, mb: 500),
            p(41, 40, name: "Google Chrome Helper (Renderer)", path: helper, mb: 700),
        ], cpuPercentByPid: [:], ownUid: me)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "Google Chrome")
        XCTAssertEqual(groups[0].kind, .app(bundlePath: "/Applications/Google Chrome.app"))
        XCTAssertEqual(groups[0].rootPids, [40])
        XCTAssertEqual(groups[0].helpers, 1)
    }

    func testResponsibleProcessAdoptsLaunchdChildren() {
        // XPC-сервисы висят на launchd (ppid 1); владельца знает «responsible pid».
        var web = p(1728, 1, name: "com.apple.WebKit.WebContent",
                    path: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", mb: 900)
        web.responsiblePid = 31127
        let mail = p(31127, 1, name: "Mail", path: "/System/Applications/Mail.app/Contents/MacOS/Mail", mb: 200)
        let groups = SystemModel.group([mail, web], cpuPercentByPid: [:], ownUid: me)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "Mail")
        XCTAssertEqual(groups[0].rootPids, [31127])
        XCTAssertEqual(groups[0].helpers, 1)
    }

    func testFrameworkNestedAppIsNotAnApp() {
        let py = "/opt/homebrew/Cellar/python@3.15/3.15.2/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python"
        XCTAssertNil(SystemModel.outerBundle(py))
        let left = SystemModel.leftovers([p(900, 1, pgid: 899, name: "Python", path: py)], ownUid: me, now: now)
        XCTAssertEqual(left.count, 1)
    }

    func testOtherUsersIgnored() {
        let groups = SystemModel.group([p(5, 1, name: "WindowServer", mb: 900, uid: 88)],
                                       cpuPercentByPid: [:], ownUid: me)
        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupingToleratesMissingParent() {
        let groups = SystemModel.group([p(30, 999, name: "node")], cpuPercentByPid: [:], ownUid: me)
        XCTAssertEqual(groups.first?.rootPids, [30])
    }

    func testGroupingSurvivesCycle() {
        let groups = SystemModel.group([p(5, 6, name: "node"), p(6, 5, name: "node")],
                                       cpuPercentByPid: [:], ownUid: me)
        XCTAssertEqual(groups.flatMap(\.allPids).sorted(), [5, 6])
    }

    func testCPUSummedPerGroup() {
        let groups = SystemModel.group([p(12, 1, name: "claude"), p(13, 12, name: "node")],
                                       cpuPercentByPid: [12: 30, 13: 25.5], ownUid: me)
        XCTAssertEqual(groups.first?.cpuPercent, 55.5)
    }

    func testLeftoverMatchesDeadSessionTool() {
        let procs = [
            p(7245, 1, pgid: 7244, name: "uv", mb: 5,
              args: ["uv", "run", "--quiet", "--with", "websockets>=13", "python3",
                     "/Users/x/dev/tool/relay.py", "serve"]),
            p(7247, 7245, pgid: 7244, name: "python3", mb: 4),
        ]
        let left = SystemModel.leftovers(procs, ownUid: me, now: now)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.label, "relay.py")
        XCTAssertEqual(left.first?.tool, "uv")
        XCTAssertEqual(left.first?.treePids, [7245, 7247])
        XCTAssertEqual(left.first?.footprint, 9 * 1_048_576)
    }

    func testLeftoverRejectsGroupLeaderAndAppBundle() {
        let leader = p(100, 1, name: "node")                          // pgid == pid (launchd job)
        let liveGroup = [p(200, 1, pgid: 199, name: "node"), p(199, 1, name: "zsh")]
        let app = p(300, 1, pgid: 299, name: "node", path: "/Applications/X.app/Contents/MacOS/node")
        let sys = p(400, 1, pgid: 399, name: "python3", path: "/usr/libexec/python3")
        let foreign = p(500, 1, pgid: 499, name: "node", uid: 0)
        let young = p(600, 1, pgid: 599, name: "node", age: 30)
        let notTool = p(700, 1, pgid: 699, name: "tail")
        let all = [leader, app, sys, foreign, young, notTool] + liveGroup
        XCTAssertTrue(SystemModel.leftovers(all, ownUid: me, now: now).isEmpty)
    }

    func testLeftoverCarriesTreeCPU() {
        let procs = [p(7245, 1, pgid: 7244, name: "node"), p(7247, 7245, pgid: 7244, name: "node")]
        let left = SystemModel.leftovers(procs, ownUid: me, now: now,
                                         cpuPercentByPid: [7245: 10, 7247: 30])
        XCTAssertEqual(left.first?.cpuPercent, 40)
        let s = SystemModel.snapshot(procs: procs, cpuPercentByPid: [7245: 10, 7247: 30], ownUid: me,
                                     now: now, cpuPercent: 95, memUsed: 1, memTotal: 2, swapUsed: 0,
                                     pressure: .normal)
        XCTAssertEqual(SystemModel.top(s, verdict: Verdict(s)).first?.cpuPercent, 40)
    }

    func testLeftoverMCPByName() {
        let left = SystemModel.leftovers([p(800, 1, pgid: 799, name: "mcp-server-ableton")],
                                         ownUid: me, now: now)
        XCTAssertEqual(left.first?.label, "mcp-server-ableton")
    }

    private func snap(cpu: Double = 20, pressure: Level = .normal, used: Double = 18,
                      swap: Double = 0, consumers: [Consumer] = [], leftovers: [Leftover] = [])
        -> SystemSnapshot {
        let gb: (Double) -> UInt64 = { UInt64($0 * 1_073_741_824) }
        return SystemSnapshot(cpuPercent: cpu, memUsed: gb(used), memTotal: gb(24),
                              swapUsed: gb(swap), pressure: pressure,
                              consumers: consumers, leftovers: leftovers, takenAt: now)
    }

    func testVerdict() {
        XCTAssertEqual(Verdict(snap(pressure: .critical, swap: 16.2)),
                       Verdict(text: "Swap 16 GB", level: .critical, byCPU: false))
        XCTAssertEqual(Verdict(snap(cpu: 95)), Verdict(text: "CPU 95%", level: .critical, byCPU: true))
        XCTAssertEqual(Verdict(snap(cpu: 75, pressure: .warn, swap: 3)),
                       Verdict(text: "Swap 3 GB", level: .warn, byCPU: false))
        XCTAssertEqual(Verdict(snap(cpu: 95, pressure: .warn, swap: 3)),
                       Verdict(text: "CPU 95%", level: .critical, byCPU: true))
        XCTAssertEqual(Verdict(snap()), Verdict(text: "RAM 18/24 GB", level: .normal, byCPU: false))
        XCTAssertEqual(Verdict(snap(pressure: .warn, swap: 0.4)),
                       Verdict(text: "RAM 18/24 GB", level: .warn, byCPU: false))
    }

    private func c(_ title: String, gb: Double, cpu: Double = 0) -> Consumer {
        Consumer(key: title, title: title, kind: .process, rootPids: [1], allPids: [1],
                 footprint: UInt64(gb * 1_073_741_824), cpuPercent: cpu, helpers: 0)
    }

    func testTopConsumersPadsWhenFew() {
        let few = snap(consumers: [c("a", gb: 2), c("b", gb: 1)])
        XCTAssertEqual(SystemModel.top(few, verdict: Verdict(few)).map(\.title), ["a", "b"])

        let small = Leftover(pid: 9, label: "relay.py", tool: "uv", age: 60, footprint: 9 * 1_048_576, treePids: [9])
        let withSmall = snap(consumers: [c("a", gb: 3), c("b", gb: 2), c("c", gb: 1)], leftovers: [small])
        XCTAssertEqual(SystemModel.top(withSmall, verdict: Verdict(withSmall)).map(\.title), ["a", "b", "c"])

        let big = Leftover(pid: 9, label: "x", tool: "node", age: 60, footprint: 3 * 1_073_741_824, treePids: [9])
        let withBig = snap(consumers: [c("a", gb: 4), c("b", gb: 2), c("c", gb: 1)], leftovers: [big])
        let top = SystemModel.top(withBig, verdict: Verdict(withBig))
        XCTAssertEqual(top.map(\.title), ["a", "Leftovers", "b"])
        XCTAssertEqual(top[1].kind, .leftovers)
    }

    func testTopSortsByCPUWhenCPUIsTheBottleneck() {
        let s = snap(cpu: 95, consumers: [c("fat", gb: 8, cpu: 2), c("hot", gb: 1, cpu: 400)])
        XCTAssertEqual(SystemModel.top(s, verdict: Verdict(s)).first?.title, "hot")
    }

    func testByteText() {
        XCTAssertEqual(ByteText.gb(7_945_000_000), "7.4 GB")
        XCTAssertEqual(ByteText.gb(9 * 1_048_576), "9 MB")
    }
}
