import Darwin
import Foundation

/// Читает состояние Мака прямо из ядра (libproc, mach, sysctl) — без `ps`/`top`
/// и без сети. Хранит прошлый замер, чтобы считать CPU как дельту; первый
/// вызов отдаёт CPU 0. Не потокобезопасен: вызывать с одной очереди.
final class SystemSampler {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastCPUTime: [Int32: Double] = [:]
    private var lastAt: Date?
    private let ownUid = getuid()
    /// Процессы последнего замера — по ним гасятся строки снимка.
    private(set) var lastProcs: [ProcSample] = []

    func sample(now: Date = .now) -> SystemSnapshot {
        let procs = Self.readProcs()
        lastProcs = procs
        let wall = lastAt.map { now.timeIntervalSince($0) } ?? 0
        var perPid: [Int32: Double] = [:]
        if wall > 0 {
            // В процентах всей машины (как общий CPU), а не одного ядра:
            // иначе строка «400%» спорит с вердиктом «CPU 40%».
            let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
            for p in procs {
                if let prev = lastCPUTime[p.pid], p.cpuTime >= prev {
                    perPid[p.pid] = (p.cpuTime - prev) / wall / cores * 100
                }
            }
        }
        lastCPUTime = Dictionary(procs.map { ($0.pid, $0.cpuTime) }, uniquingKeysWith: { a, _ in a })
        lastAt = now

        let mem = Self.memory()
        return SystemModel.snapshot(procs: procs, cpuPercentByPid: perPid, ownUid: ownUid, now: now,
                                    cpuPercent: hostCPUPercent(), memUsed: mem.used,
                                    memTotal: ProcessInfo.processInfo.physicalMemory,
                                    swapUsed: Self.swapUsed(), pressure: Self.pressure())
    }

    // MARK: processes

    /// Приватный, но стабильный символ libsystem — им пользуется Activity
    /// Monitor. Нет символа — группируем только по ppid.
    private typealias ResponsibleFn = @convention(c) (Int32) -> Int32
    private static let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                              "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    private static let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func readProcs() -> [ProcSample] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        guard count > 0 else { return [] }

        var out: [ProcSample] = []
        out.reserveCapacity(count)
        var pathBuf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            // Процесс мог умереть между listallpids и pidinfo — просто пропускаем.
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }

            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            } == 0
            pathBuf[0] = 0
            proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = String(cString: pathBuf)

            var name = cString(info.pbi_name)
            if name.isEmpty { name = cString(info.pbi_comm) }
            // Нативный Claude Code виден как «claude.exe» (и без пути после апдейта).
            if name.hasSuffix(".exe") { name.removeLast(4) }

            var args: [String] = []
            let lower = name.lowercased()
            // Нативный установщик Claude Code: бинарник назван версией
            // (…/claude/versions/2.1.325), имя «claude» остаётся только в argv[0].
            let versionLike = !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." }
            if versionLike {
                args = readArgs(pid)
                if let argv0 = args.first, !argv0.isEmpty {
                    name = (argv0 as NSString).lastPathComponent
                }
            }
            // Аргументы — только где они нужны: кандидаты в сироты (подпись) и
            // node/bun (агентный CLI, запущенный как скрипт). В UI уходит лишь
            // имя скрипта — в командных строках бывают секреты.
            if !versionLike, info.pbi_ppid == 1 || lower == "node" || lower == "bun" {
                args = readArgs(pid)
                if args.count > 1 {
                    let script = (args[1] as NSString).lastPathComponent.lowercased()
                    if SystemModel.agentTitles[script] != nil { name = script }
                }
            }

            let start = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec)
                             + Double(info.pbi_start_tvusec) / 1_000_000)
            out.append(ProcSample(
                pid: pid, ppid: Int32(info.pbi_ppid), pgid: Int32(info.pbi_pgid), uid: info.pbi_uid,
                name: name, path: path,
                footprint: ok ? usage.ri_phys_footprint : 0,
                cpuTime: ok ? Double(usage.ri_user_time + usage.ri_system_time) * timebase / 1e9 : 0,
                startedAt: start, args: args,
                responsiblePid: info.pbi_ppid == 1 ? (responsible?(pid) ?? 0) : 0))
        }
        return out
    }

    /// argv процесса через KERN_PROCARGS2: [argc][exec path\0…][argv\0…].
    static func readArgs(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }          // exec path
        while i < size, buf[i] == 0 { i += 1 }          // паддинг
        var args: [String] = []
        while args.count < argc, i < size {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
    }

    // MARK: host

    /// «Memory Used» как в Activity Monitor: app (active+inactive−purgeable не
    /// различаем) ≈ active + wired + compressed.
    static func memory() -> (used: UInt64, pageSize: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        guard kr == KERN_SUCCESS else { return (0, page) }
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return (pages * page, page)
    }

    static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical.
    static func pressure() -> Level {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4...: return .critical
        case 2...: return .warn
        default: return .normal
        }
    }

    /// Загрузка CPU по всей машине — дельта тиков между замерами.
    private func hostCPUPercent() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = load.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total) * 100
    }
}
