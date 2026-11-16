import XCTest
@testable import AIStatusBar

/// Интеграционный дымовой тест: читает настоящее ядро этой машины.
final class SystemSamplerTests: XCTestCase {
    func testSampleSeesOwnProcess() throws {
        let procs = SystemSampler.readProcs()
        let me = try XCTUnwrap(procs.first { $0.pid == getpid() })
        XCTAssertEqual(me.uid, getuid())
        XCTAssertGreaterThan(me.footprint, 0)
        XCTAssertGreaterThan(procs.count, 20)

        let sampler = SystemSampler()
        _ = sampler.sample()
        let s = sampler.sample(now: Date().addingTimeInterval(0.5))
        XCTAssertEqual(s.memTotal, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(s.memUsed, 0)
        XCTAssertLessThanOrEqual(s.memUsed, s.memTotal)
        XCTAssertFalse(s.consumers.isEmpty)
        XCTAssertGreaterThanOrEqual(s.cpuPercent, 0)
        XCTAssertLessThanOrEqual(s.cpuPercent, 100)
    }

    func testReadArgsOfSelf() {
        let args = SystemSampler.readArgs(getpid())
        XCTAssertFalse(args.isEmpty)
    }
}
