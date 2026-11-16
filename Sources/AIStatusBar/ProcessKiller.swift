import AppKit
import Darwin

/// Закрытие процессов из блока «Mac». Сигналы уходят только процессам
/// текущего пользователя и никогда — pid 0/1, самому приложению и его
/// предкам (приложение может быть запущено из сессии агента, которую гасят).
enum ProcessKiller {
    /// `procs` — ПОЛНЫЙ свежий список: по нему строится цепочка своих предков.
    /// Цепочка не дошла до launchd (кого-то не хватает) — не трогаем никого:
    /// иначе предок за дырой (claude → ? → приложение) остался бы без защиты.
    static func targets(_ pids: [Int32], procs: [ProcSample],
                        ownPid: Int32 = getpid(), ownUid: uid_t = getuid()) -> [Int32] {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var protected: Set<Int32> = [0, 1, ownPid]
        guard var cursor = byPid[ownPid]?.ppid else { return [] }
        while cursor != 1 {
            guard let parent = byPid[cursor], protected.insert(cursor).inserted else { return [] }
            cursor = parent.ppid
        }
        return pids.filter { pid in
            !protected.contains(pid) && byPid[pid]?.uid == ownUid
        }
    }

    /// Цели из снимка `old`, которые всё ещё те же процессы (pid + время старта)
    /// в свежем `fresh`; защита предков — по полному `fresh`.
    static func liveTargets(_ pids: [Int32], old: [ProcSample], fresh: [ProcSample],
                            ownPid: Int32 = getpid(), ownUid: uid_t = getuid()) -> [Int32] {
        let same = Set(stillSame(old: old, fresh: fresh).map(\.pid))
        return targets(pids, procs: fresh, ownPid: ownPid, ownUid: ownUid).filter(same.contains)
    }

    /// Процессы, которые живы и это те же самые процессы, что в снимке: pid
    /// мог освободиться и достаться другому — сверяем время старта.
    static func stillSame(old: [ProcSample], fresh: [ProcSample]) -> [ProcSample] {
        let started = Dictionary(old.map { ($0.pid, $0.startedAt) }, uniquingKeysWith: { a, _ in a })
        return fresh.filter { started[$0.pid] == $0.startedAt }
    }

    /// Force Quit: сначала помощники, потом корни — иначе убитый корень
    /// оставит детей сиротами, и они всплывут в Leftovers.
    static func forcePlan(_ c: Consumer, old: [ProcSample], fresh: [ProcSample],
                          ownPid: Int32 = getpid(), ownUid: uid_t = getuid()) -> [Int32] {
        let roots = Set(c.rootPids)
        let helpers = c.allPids.filter { !roots.contains($0) }
        return liveTargets(helpers + c.rootPids, old: old, fresh: fresh, ownPid: ownPid, ownUid: ownUid)
    }

    /// `old` — процессы снимка, по которому построен пункт меню; `fresh` —
    /// замер в момент клика.
    static func quit(_ c: Consumer, old: [ProcSample], fresh: [ProcSample]) {
        switch c.kind {
        case .app:
            // Приложение получает шанс сохранить состояние (как Quit в Dock).
            for pid in liveTargets(c.rootPids, old: old, fresh: fresh) {
                if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() }
                else { kill(pid, SIGTERM) }
            }
        case .agent, .process:
            // Корни сами гасят своих помощников (MCP-серверы и т.п.).
            liveTargets(c.rootPids, old: old, fresh: fresh).forEach { kill($0, SIGTERM) }
        case .leftovers:
            liveTargets(c.allPids, old: old, fresh: fresh).forEach { kill($0, SIGTERM) }
        }
    }

    static func forceQuit(_ c: Consumer, old: [ProcSample], fresh: [ProcSample]) {
        if case .app = c.kind {
            for pid in liveTargets(c.rootPids, old: old, fresh: fresh) {
                if let app = NSRunningApplication(processIdentifier: pid) { app.forceTerminate() }
                else { kill(pid, SIGKILL) }
            }
            return
        }
        forcePlan(c, old: old, fresh: fresh).forEach { kill($0, SIGKILL) }
    }

    static func quit(_ l: Leftover, old: [ProcSample], fresh: [ProcSample]) {
        liveTargets(l.treePids, old: old, fresh: fresh).forEach { kill($0, SIGTERM) }
    }
}
