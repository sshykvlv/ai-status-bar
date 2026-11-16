import AppKit
import Darwin

/// Закрытие процессов из блока «Mac». Сигналы уходят только процессам
/// текущего пользователя и никогда — pid 0/1, самому приложению и его
/// предкам (приложение может быть запущено из сессии агента, которую гасят).
enum ProcessKiller {
    static func targets(_ pids: [Int32], procs: [ProcSample],
                        ownPid: Int32 = getpid(), ownUid: uid_t = getuid()) -> [Int32] {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var protected: Set<Int32> = [0, 1, ownPid]
        var cursor = byPid[ownPid]?.ppid
        while let pid = cursor, protected.insert(pid).inserted { cursor = byPid[pid]?.ppid }
        return pids.filter { pid in
            !protected.contains(pid) && byPid[pid]?.uid == ownUid
        }
    }

    /// Force Quit: сначала помощники, потом корни — иначе убитый корень
    /// оставит детей сиротами, и они всплывут в Leftovers.
    static func forcePlan(_ c: Consumer, procs: [ProcSample],
                          ownPid: Int32 = getpid(), ownUid: uid_t = getuid()) -> [Int32] {
        let roots = Set(c.rootPids)
        let helpers = c.allPids.filter { !roots.contains($0) }
        return targets(helpers + c.rootPids, procs: procs, ownPid: ownPid, ownUid: ownUid)
    }

    static func quit(_ c: Consumer, procs: [ProcSample]) {
        switch c.kind {
        case .app:
            // Приложение получает шанс сохранить состояние (как Quit в Dock).
            for pid in targets(c.rootPids, procs: procs) {
                if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() }
                else { kill(pid, SIGTERM) }
            }
        case .agent, .process:
            // Корни сами гасят своих помощников (MCP-серверы и т.п.).
            targets(c.rootPids, procs: procs).forEach { kill($0, SIGTERM) }
        case .leftovers:
            targets(c.allPids, procs: procs).forEach { kill($0, SIGTERM) }
        }
    }

    static func forceQuit(_ c: Consumer, procs: [ProcSample]) {
        if case .app = c.kind {
            for pid in targets(c.rootPids, procs: procs) {
                if let app = NSRunningApplication(processIdentifier: pid) { app.forceTerminate() }
                else { kill(pid, SIGKILL) }
            }
            return
        }
        forcePlan(c, procs: procs).forEach { kill($0, SIGKILL) }
    }

    static func quit(_ l: Leftover, procs: [ProcSample]) {
        targets(l.treePids, procs: procs).forEach { kill($0, SIGTERM) }
    }
}
