struct Bezier {
    static let x1 = 0.42
    static let x2 = 0.58
    static let y2 = 1.0
    var y1: Double

    init(slope: Double) {
        y1 = Self.x1 * slope
    }

    private func bx(_ t: Double) -> Double {
        let m = 1 - t
        return 3 * m * m * t * Self.x1 + 3 * m * t * t * Self.x2 + t * t * t
    }

    private func by(_ t: Double) -> Double {
        let m = 1 - t
        return 3 * m * m * t * y1 + 3 * m * t * t * Self.y2 + t * t * t
    }

    private func dx(_ t: Double) -> Double {
        let m = 1 - t
        return 3 * m * m * Self.x1 + 6 * m * t * (Self.x2 - Self.x1) + 3 * t * t * (1 - Self.x2)
    }

    private func dy(_ t: Double) -> Double {
        let m = 1 - t
        return 3 * m * m * y1 + 6 * m * t * (Self.y2 - y1) + 3 * t * t * (1 - Self.y2)
    }

    private func solve(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let e = bx(t) - x
            if abs(e) < 1e-7 { return t }
            let d = dx(t)
            if abs(d) < 1e-6 { break }
            t -= e / d
        }
        var lo = 0.0
        var hi = 1.0
        t = x
        for _ in 0..<30 {
            let e = bx(t) - x
            if abs(e) < 1e-7 { break }
            if e > 0 { hi = t } else { lo = t }
            t = (lo + hi) / 2
        }
        return t
    }

    func value(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return by(solve(x))
    }

    func slope(_ x: Double) -> Double {
        let t = solve(min(max(x, 0), 1))
        let d = dx(t)
        return abs(d) < 1e-6 ? 0 : dy(t) / d
    }
}
