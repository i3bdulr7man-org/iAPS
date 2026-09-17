import Foundation

// MealTimeLearner — Boost V6 anticipatory pre-meal target (upstream
// openAPSBoost/MealTimeLearner.kt, tim2000s/Boost-in-AAPS_3.4 — verbatim port).
//
// Learns a user's habitual meal times from the events V5 itself already calls meals (a fresh
// CONFIRMED commit — no second detector to tune; the histogram learns exactly what V5 treats
// as a meal) and exposes the query the loop uses to fire an anticipatory low target ~45–60
// min before a learned meal.
//
// Clustering: events project to local minute-of-day and group greedily into modes. A mode is
// trusted only with ≥6 events spread over ≥4 distinct days within ±45 min — a one-off late
// dinner can't manufacture a window. The mode centre is the circular mean of its members.
//
// Safety posture: empty/corrupt history → no modes → preMealWindow returns nil → the feature
// never fires. The learner has ZERO dosing impact on its own; the target change is gated
// behind the user's pre-meal toggle (shadow-first) and is LOWER-ONLY.

enum BoostMealTimeLearner {
    static let windowDays = 60.0
    private static let windowMs = windowDays * 24 * 60 * 60 * 1000
    /// A cluster must have at least this many events to be a trusted meal mode.
    static let minSessions = 6
    /// …spread over at least this many distinct days (kills a single binge-day false mode).
    static let minDistinctDays = 4
    /// Circular half-width (min) for grouping events into one mode (~07:50 ± 45 → breakfast).
    static let clusterHalfWidthMin = 45
    /// The pre-meal window always CLOSES this many minutes before the learned meal.
    static let preMealLeadMinFloor = 45
    /// Guaranteed minimum window span (min), so a low lead setting can't yield zero width.
    static let preMealMinSpanMin = 10
    private static let minutesPerDay = 1440

    /// Rolling history of meal-commit timestamps (UTC ms).
    struct History: Equatable {
        var events: [Double] = []

        /// Record a fresh meal-commit; appends and trims to the rolling window.
        mutating func record(tsMs: Double) {
            events.append(tsMs)
            let cutoff = tsMs - BoostMealTimeLearner.windowMs
            events.removeAll { $0 < cutoff }
        }
    }

    /// A learned habitual meal time.
    struct MealMode: Equatable {
        /// Circular-mean clock minute-of-day [0..1439].
        let centreMin: Int
        /// Number of events in the cluster.
        let eventCount: Int
        /// Number of distinct local days contributing (the trust signal).
        let distinctDays: Int
    }

    /// A positive preMealWindow match.
    struct PreMealHit: Equatable {
        let mode: MealMode
        /// How many minutes before the meal centre we currently are.
        let minutesBeforeMeal: Int
    }

    /// Smaller of clockwise/anticlockwise distance between two minute-of-day values.
    static func circularDistance(_ a: Int, _ b: Int) -> Int {
        let d = abs(a - b)
        return min(d, minutesPerDay - d)
    }

    /// Local minute-of-day [0..1439] of a UTC instant under the given local offset (ms).
    static func msToMinOfDay(_ utcMs: Double, _ localOffsetMs: Double) -> Int {
        let msPerDay = 24.0 * 60 * 60 * 1000
        let localMs = utcMs + localOffsetMs
        let msIntoDay = (localMs.truncatingRemainder(dividingBy: msPerDay) + msPerDay)
            .truncatingRemainder(dividingBy: msPerDay)
        return Int(msIntoDay / 60000)
    }

    /// Circular mean of minute-of-day values (midnight-wrap-safe; 23:00+01:00 → ~0, not 12).
    /// nil when empty or the directions cancel exactly.
    static func circularMean(_ minutes: [Int]) -> Int? {
        guard !minutes.isEmpty else { return nil }
        var sx = 0.0
        var sy = 0.0
        for m in minutes {
            let a = Double(m) * 2 * Double.pi / Double(minutesPerDay)
            sx += cos(a)
            sy += sin(a)
        }
        guard abs(sx) > 1E-12 || abs(sy) > 1E-12 else { return nil }
        let mean = atan2(sy, sx) * Double(minutesPerDay) / (2 * Double.pi)
        let normalized = (mean.truncatingRemainder(dividingBy: Double(minutesPerDay)) + Double(minutesPerDay))
            .truncatingRemainder(dividingBy: Double(minutesPerDay))
        return Int(normalized)
    }

    /// Greedily cluster the history's events into trusted meal modes (descending by size).
    /// O(n²) over events, but n is tiny (≤ ~3 meals/day × 60 days).
    static func modes(_ h: History, localOffsetMs: Double) -> [MealMode] {
        if h.events.count < minSessions { return [] }
        struct Point {
            let minOfDay: Int
            let dayIndex: Int
        }
        var pts = h.events.map { ms -> Point in
            Point(
                minOfDay: msToMinOfDay(ms, localOffsetMs),
                dayIndex: Int((ms + localOffsetMs) / (24 * 60 * 60 * 1000))
            )
        }
        var result: [MealMode] = []
        while pts.count >= minSessions {
            // pick the event whose ±half-width neighbourhood holds the most events (first max)
            var bestIdx = 0
            var bestCount = -1
            for (i, c) in pts.enumerated() {
                let cnt = pts.filter { circularDistance($0.minOfDay, c.minOfDay) <= clusterHalfWidthMin }.count
                if cnt > bestCount {
                    bestCount = cnt
                    bestIdx = i
                }
            }
            let centre0 = pts[bestIdx].minOfDay
            let clusterIdx = pts.indices.filter { circularDistance(pts[$0].minOfDay, centre0) <= clusterHalfWidthMin }
            let cluster = clusterIdx.map { pts[$0] }
            let distinctDays = Set(cluster.map(\.dayIndex)).count
            if cluster.count >= minSessions, distinctDays >= minDistinctDays,
               let centre = circularMean(cluster.map(\.minOfDay))
            {
                result.append(MealMode(centreMin: centre, eventCount: cluster.count, distinctDays: distinctDays))
                for i in clusterIdx.sorted(by: >) { pts.remove(at: i) }
            } else {
                // the densest remaining cluster isn't trustworthy → no further modes will be either
                break
            }
        }
        return result
    }

    /// Is `nowMin` (local clock minute-of-day) inside the pre-meal lead window of any learned
    /// mode? The window for a mode centred at `c` is the arc [c − openBefore, c − floor]: it
    /// opens `leadMaxMin` min before the meal and closes 45 min before it (V5's own detection
    /// takes the meal from there). `openBefore` is held at least floor + 10 so a low setting
    /// can't collapse the window to nothing.
    static func preMealWindow(
        _ h: History,
        nowMin: Int,
        localOffsetMs: Double,
        leadMaxMin: Int
    ) -> PreMealHit? {
        let open = max(leadMaxMin, preMealLeadMinFloor + preMealMinSpanMin)
        for mode in modes(h, localOffsetMs: localOffsetMs) {
            // minutes from now forward to the meal centre, on the circle [0..1439]
            let ahead = ((mode.centreMin - nowMin) % minutesPerDay + minutesPerDay) % minutesPerDay
            if ahead >= preMealLeadMinFloor, ahead <= open {
                return PreMealHit(mode: mode, minutesBeforeMeal: ahead)
            }
        }
        return nil
    }
}
