import Foundation

// Чистая модель блока «Mac»: на вход — снимок процессов, на выход — кто ест
// машину, какие процессы осиротели и какой вердикт показать. Без системных
// вызовов, чтобы всё правило было покрыто тестами (SystemModelTests).
// Дизайн и почему так: docs/superpowers/specs/2026-11-16-mac-stats-design.md.

/// Один процесс в снимке. `footprint` — physical footprint (как в Activity
/// Monitor), не RSS; `cpuTime` — накопленное user+system время в секундах.
struct ProcSample: Equatable {
    var pid: Int32
    var ppid: Int32
    var pgid: Int32
    var uid: uid_t
    var name: String
    var path: String
    var footprint: UInt64
    var cpuTime: Double
    var startedAt: Date
    var args: [String] = []
}

enum Level: Int, Comparable {
    case normal, warn, critical
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

enum ConsumerKind: Equatable {
    /// Сессии агентного CLI со всеми их помощниками (MCP-серверы, node, uv…).
    case agent
    /// Приложение: закрывается через NSRunningApplication, а не сигналом.
    case app(bundlePath: String)
    case process
    /// Сводная строка осиротевших помощников агентов.
    case leftovers
}

struct Consumer: Equatable {
    var key: String
    var title: String
    var kind: ConsumerKind
    /// Корни группы — процессы, чей родитель не в группе (11 сессий claude).
    var rootPids: [Int32]
    var allPids: [Int32]
    var footprint: UInt64
    /// Сумма по процессам, в процентах одного ядра (как в Activity Monitor).
    var cpuPercent: Double
    var helpers: Int
}

/// Помощник агента, чья сессия умерла. Снаружи неотличим от сервера, который
/// агент отвязал намеренно, поэтому только показываем — гасит пользователь.
struct Leftover: Equatable {
    var pid: Int32
    var label: String
    var tool: String
    var age: TimeInterval
    var footprint: UInt64
    /// Сам процесс и его потомки (uv → python): гасятся вместе.
    var treePids: [Int32]
}

struct SystemSnapshot {
    var cpuPercent: Double
    var memUsed: UInt64
    var memTotal: UInt64
    var swapUsed: UInt64
    var pressure: Level
    var consumers: [Consumer]
    var leftovers: [Leftover]
    var takenAt: Date
}

/// Один чип сводки называет узкое место. Тревога памяти — только по
/// memory pressure ядра: macOS держит RAM занятой и в покое, а занятый своп —
/// история (16.11: 9 GB свопа при нормальном давлении). CPU побеждает только
/// при строго большей тревоге — тогда и список сортируется по CPU.
struct Verdict: Equatable {
    var text: String
    var level: Level
    var byCPU: Bool

    init(text: String, level: Level, byCPU: Bool) {
        self.text = text; self.level = level; self.byCPU = byCPU
    }

    init(_ s: SystemSnapshot) {
        let cpu: Level = s.cpuPercent >= 90 ? .critical : s.cpuPercent >= 70 ? .warn : .normal
        if cpu > s.pressure {
            self.init(text: "CPU \(Int(s.cpuPercent.rounded()))%", level: cpu, byCPU: true)
            return
        }
        let swapGB = Double(s.swapUsed) / ByteText.gib
        let text = s.pressure != .normal && swapGB >= 1
            ? String(format: "Swap %.0f GB", swapGB)
            : String(format: "RAM %.0f/%.0f GB", Double(s.memUsed) / ByteText.gib,
                     Double(s.memTotal) / ByteText.gib)
        self.init(text: text, level: s.pressure, byCPU: false)
    }
}

enum ByteText {
    static let gib = 1_073_741_824.0
    static func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / gib
        return g >= 1 ? String(format: "%.1f GB", g) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

enum SystemModel {
    /// Агентные CLI → человеческое имя. Сравнение по имени исполняемого файла.
    static let agentTitles: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI",
        "opencode": "OpenCode", "aider": "Aider", "cursor-agent": "Cursor Agent", "amp": "Amp",
    ]
    static let leftoverMinAge: TimeInterval = 60
    private static let toolNames: Set<String> = ["node", "bun", "deno", "uv", "uvx", "npx", "npm", "pnpm", "tsx"]
    private static let scriptSuffixes = [".py", ".js", ".mjs", ".cjs", ".ts"]

    static func isAgentTooling(_ name: String) -> Bool {
        let n = name.lowercased()
        return toolNames.contains(n) || n.hasPrefix("python") || n.contains("mcp")
    }

    /// Внешний `.app` в пути: хелперы Chrome живут в бандле внутри бандла,
    /// поэтому берём ПЕРВОЕ вхождение — это само приложение.
    static func outerBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// Группировка по дереву владения: внешний агентный CLI среди предков →
    /// агент; иначе свой `.app`; иначе имя процесса. Отсортировано по памяти.
    static func group(_ procs: [ProcSample], cpuPercentByPid: [Int32: Double],
                      ownUid: uid_t) -> [Consumer] {
        let mine = procs.filter { $0.uid == ownUid }
        let byPid = Dictionary(mine.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        var keyOf: [Int32: (key: String, title: String, kind: ConsumerKind)] = [:]
        for p in mine {
            var agent: String?
            var cursor: ProcSample? = p
            var seen = Set<Int32>()
            while let c = cursor, seen.insert(c.pid).inserted {
                if let t = agentTitles[c.name.lowercased()] { agent = t }   // последний = внешний
                cursor = byPid[c.ppid]
            }
            if let agent {
                keyOf[p.pid] = ("agent:" + agent, agent, .agent)
            } else if let bundle = outerBundle(p.path) {
                let title = (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                keyOf[p.pid] = ("app:" + bundle, title, .app(bundlePath: bundle))
            } else {
                keyOf[p.pid] = ("proc:" + p.name, p.name, .process)
            }
        }

        var groups: [String: Consumer] = [:]
        var order: [String] = []
        for p in mine {
            guard let k = keyOf[p.pid] else { continue }
            let isRoot = keyOf[p.ppid]?.key != k.key || p.ppid == p.pid
            if groups[k.key] == nil {
                order.append(k.key)
                groups[k.key] = Consumer(key: k.key, title: k.title, kind: k.kind, rootPids: [],
                                         allPids: [], footprint: 0, cpuPercent: 0, helpers: 0)
            }
            groups[k.key]!.allPids.append(p.pid)
            if isRoot { groups[k.key]!.rootPids.append(p.pid) }
            groups[k.key]!.footprint += p.footprint
            groups[k.key]!.cpuPercent += cpuPercentByPid[p.pid] ?? 0
        }
        // Цикл ppid (5↔6) не даёт корней — тогда корнями считаем всех.
        return order.compactMap { key -> Consumer? in
            guard var g = groups[key] else { return nil }
            if g.rootPids.isEmpty { g.rootPids = g.allPids }
            g.helpers = g.allPids.count - g.rootPids.count
            return g
        }.sorted { $0.footprint > $1.footprint }
    }

    /// Осиротевшие помощники агентов. Правило и замер — в спеке, раздел
    /// «Leftover rule»: launchd-джобы сами лидеры своей группы и не проходят.
    static func leftovers(_ procs: [ProcSample], ownUid: uid_t, now: Date) -> [Leftover] {
        let alive = Set(procs.map(\.pid))
        var children: [Int32: [Int32]] = [:]
        for p in procs { children[p.ppid, default: []].append(p.pid) }
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        return procs.compactMap { p -> Leftover? in
            guard p.uid == ownUid, p.ppid == 1, p.pgid != p.pid, !alive.contains(p.pgid),
                  outerBundle(p.path) == nil,
                  !p.path.hasPrefix("/System/"), !p.path.hasPrefix("/usr/libexec/"),
                  isAgentTooling(p.name),
                  now.timeIntervalSince(p.startedAt) >= leftoverMinAge else { return nil }
            var tree: [Int32] = []
            var queue = [p.pid]
            var seen = Set<Int32>()
            while !queue.isEmpty {
                let pid = queue.removeFirst()
                guard seen.insert(pid).inserted else { continue }
                tree.append(pid)
                queue += children[pid] ?? []
            }
            return Leftover(pid: p.pid, label: label(for: p), tool: p.name,
                            age: now.timeIntervalSince(p.startedAt),
                            footprint: tree.reduce(0) { $0 + (byPid[$1]?.footprint ?? 0) },
                            treePids: tree)
        }.sorted { $0.footprint > $1.footprint }
    }

    /// «relay.py» понятнее, чем «uv»: первый аргумент-скрипт или MCP-сервер.
    static func label(for p: ProcSample) -> String {
        for arg in p.args.dropFirst() where !arg.hasPrefix("-") {
            let base = (arg as NSString).lastPathComponent
            if scriptSuffixes.contains(where: { base.hasSuffix($0) }) || base.lowercased().contains("mcp") {
                return base
            }
        }
        return p.name
    }

    /// Видимые строки блока (≤3). Сироты конкурируют одной сводной строкой:
    /// мелкие не лезут наверх, но всегда есть в сабменю «Mac».
    static let visibleConsumers = 3
    static func top(_ s: SystemSnapshot, verdict: Verdict) -> [Consumer] {
        var all = s.consumers
        if !s.leftovers.isEmpty {
            all.append(Consumer(key: "leftovers", title: "Leftovers", kind: .leftovers,
                                rootPids: s.leftovers.map(\.pid),
                                allPids: s.leftovers.flatMap(\.treePids),
                                footprint: s.leftovers.reduce(0) { $0 + $1.footprint },
                                cpuPercent: 0, helpers: 0))
        }
        let sorted = verdict.byCPU ? all.sorted { $0.cpuPercent > $1.cpuPercent }
                                   : all.sorted { $0.footprint > $1.footprint }
        return Array(sorted.prefix(visibleConsumers))
    }

    /// Сборка снимка из процессов: сироты вычитаются из групп, чтобы их память
    /// не считалась дважды (строка «uv» и строка «Leftovers»).
    static func snapshot(procs: [ProcSample], cpuPercentByPid: [Int32: Double], ownUid: uid_t,
                         now: Date, cpuPercent: Double, memUsed: UInt64, memTotal: UInt64,
                         swapUsed: UInt64, pressure: Level) -> SystemSnapshot {
        let left = leftovers(procs, ownUid: ownUid, now: now)
        let orphaned = Set(left.flatMap(\.treePids))
        let groups = group(procs.filter { !orphaned.contains($0.pid) },
                           cpuPercentByPid: cpuPercentByPid, ownUid: ownUid)
        return SystemSnapshot(cpuPercent: cpuPercent, memUsed: memUsed, memTotal: memTotal,
                              swapUsed: swapUsed, pressure: pressure, consumers: groups,
                              leftovers: left, takenAt: now)
    }
}
