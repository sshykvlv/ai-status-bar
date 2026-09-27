import AppKit

enum IconRenderer {
    struct BarLevel: Equatable {
        let used: Double?        // 0…1, доля израсходованного; nil = нет данных
    }

    /// Один бар на аккаунт. Высота точно показывает worstUtilization, а цвет всего
    /// заполнения плавно проходит через зелёный, жёлтый, оранжевый и красный.
    static func barLevels(_ states: [AccountState]) -> [BarLevel] {
        states.map { state in
            switch state {
            case .ok(let u, _), .stale(let u, _, _):
                let used = min(max(u.worstUtilization / 100, 0), 1)
                return BarLevel(used: used)
            case .failed, .pending:
                return BarLevel(used: nil)
            }
        }
    }

    static let barWidth: CGFloat = 3
    static let barHeight: CGFloat = 15

    /// Непрерывная высота заливки для точного процента. 1pt-пол оставляет видимым
    /// ненулевой расход, а значения вне диапазона безопасно зажимаются в 0…100%.
    static func fillHeight(used: Double) -> CGFloat {
        guard used.isFinite, used > 0 else { return 0 }
        let clamped = min(max(used, 0), 1)
        return max(1, barHeight * clamped)
    }

    static func image(levels rawLevels: [BarLevel]) -> NSImage {
        // Столбик на аккаунт: одна непрерывная полоса с точной высотой расхода.
        // Цвет всей заливки непрерывно меняется по мере роста расхода.
        // levels.isEmpty (нет ни одного настроенного аккаунта, не просто "данные ещё не
        // пришли") раньше рендерило буквально пустой канвас — ни одного трека не рисовалось,
        // потому что цикл ниже идёт по levels. Значок в менюбаре становился невидимым (owner
        // repro: удалил все аккаунты во время миграции на .claudeOAuth → иконка пропала,
        // нечем было кликнуть "Add Account…"). Подставляем один пустой трек-плейсхолдер,
        // как для .pending — та же визуальная лексика "данных нет", но остаётся видимым и
        // кликабельным.
        let levels = rawLevels.isEmpty ? [BarLevel(used: nil)] : rawLevels
        let barW = barWidth, gap: CGFloat = 2, barH = barHeight, canvasH: CGFloat = 18
        let count = max(levels.count, 1)
        let width = CGFloat(count) * barW + CGFloat(count - 1) * gap + 2
        // Template оставляем только когда данных нет вовсе (пустой значок).
        let hasData = levels.contains { $0.used != nil }
        let img = NSImage(size: NSSize(width: width, height: canvasH), flipped: false) { _ in
            let y = (canvasH - barH) / 2
            for (i, level) in levels.enumerated() {
                let x = 1 + CGFloat(i) * (barW + gap)
                let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: barH),
                                         xRadius: barW / 2, yRadius: barW / 2)
                NSColor.labelColor.withAlphaComponent(0.35).setFill()
                track.fill()
                if let used = level.used {
                    let height = fillHeight(used: used)
                    if height > 0 {
                        let fill = NSBezierPath(
                            roundedRect: NSRect(x: x, y: y, width: barW, height: height),
                            xRadius: barW / 2, yRadius: barW / 2)
                        fillColor(used: used).setFill()
                        fill.fill()
                    }
                }
            }
            return true
        }
        img.isTemplate = !hasData
        return img
    }

    /// Continuous traffic-light palette. Fixed device-RGB anchors keep interpolation
    /// stable instead of blending dynamic system colors from different appearances.
    static func fillColor(used: Double) -> NSColor {
        typealias Stop = (position: Double, red: CGFloat, green: CGFloat, blue: CGFloat)
        let stops: [Stop] = [
            (0, 0.204, 0.780, 0.349),       // system green
            (1.0 / 3.0, 1, 0.839, 0.039), // system yellow
            (2.0 / 3.0, 1, 0.584, 0),     // system orange
            (1, 1, 0.231, 0.188),         // system red
        ]
        let value = used.isFinite ? min(max(used, 0), 1) : 0
        guard let upperIndex = stops.firstIndex(where: { value <= $0.position }) else {
            let last = stops[stops.count - 1]
            return NSColor(deviceRed: last.red, green: last.green, blue: last.blue, alpha: 1)
        }
        let upper = stops[upperIndex]
        guard upperIndex > 0 else {
            return NSColor(deviceRed: upper.red, green: upper.green, blue: upper.blue, alpha: 1)
        }
        let lower = stops[upperIndex - 1]
        let progress = CGFloat((value - lower.position) / (upper.position - lower.position))
        func blend(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * progress }
        return NSColor(deviceRed: blend(lower.red, upper.red),
                       green: blend(lower.green, upper.green),
                       blue: blend(lower.blue, upper.blue), alpha: 1)
    }
}
