import Foundation

// MARK: - Stats snapshot

struct WindowView {
    var label: String; var used: Double; var resetsAt: Double; var windowMin: Int
    var stale: Bool                 // window already reset since last sample
    var forecast: String            // human-readable pace forecast
    var level: Int                  // 0 ok, 1 warn, 2 danger
}

struct Stats {
    var ready = false
    var c5hUSD = 0.0, c5hTok = 0, cTodayUSD = 0.0, cTodayTok = 0, c7dUSD = 0.0
    var cBurnPerHour = 0.0, cCachePct = 0.0, cTopModel = ""
    var cUnpriced: Set<String> = []
    var xTodayTok = 0, x5hTok = 0
    var c24hTok = 0, c24hUSD = 0.0, x24hTok = 0
    var hourly: [(Int, Int)] = Array(repeating: (0, 0), count: 24)   // (claude work, codex work), oldest first
    var daily: [(Double, Int, Int)] = []                              // (dayStart, claude work, codex work)
    var projects: [(String, Double, Int)] = []                        // (name, claude $, total work tokens) today
    var streak = 0
    var updated: Double = 0
}

func buildStats(_ s: Scanner, _ pricing: Pricing) -> Stats {
    var st = Stats(); st.ready = true
    let now = Date().timeIntervalSince1970; st.updated = now
    let today = startOfDay(now), h5 = now - 5 * 3600, h1 = now - 3600
    let hourStart = floor(now / 3600) * 3600 - 23 * 3600
    var days: [Double: (Int, Int)] = [:]
    var proj: [String: (Double, Int)] = [:]
    var models: [String: Double] = [:]
    var crToday = 0, inToday = 0

    for e in s.claude.values {
        guard e.ts >= now - 7 * 86400 else { continue }
        let c = pricing.cost(e)
        if c == nil { st.cUnpriced.insert(e.model) }
        let usd = c ?? 0
        st.c7dUSD += usd
        let d = startOfDay(e.ts); days[d, default: (0, 0)].0 += e.work
        if e.ts >= today {
            st.cTodayUSD += usd; st.cTodayTok += e.all
            crToday += e.cr; inToday += e.inp + e.cw5 + e.cw1 + e.cr
            proj[e.project, default: (0, 0)].0 += usd; proj[e.project, default: (0, 0)].1 += e.work
            models[e.model, default: 0] += usd
        }
        if e.ts >= h5 { st.c5hUSD += usd; st.c5hTok += e.all }
        if e.ts >= now - 86400 { st.c24hUSD += usd; st.c24hTok += e.all }
        if e.ts >= h1 { st.cBurnPerHour += usd }
        let hi = Int((e.ts - hourStart) / 3600)
        if hi >= 0 && hi < 24 { st.hourly[hi].0 += e.work }
    }
    st.cCachePct = inToday > 0 ? Double(crToday) / Double(inToday) * 100 : 0
    st.cTopModel = models.max { $0.value < $1.value }?.key ?? ""

    for e in s.codex where e.ts >= now - 7 * 86400 {
        let d = startOfDay(e.ts); days[d, default: (0, 0)].1 += e.work
        if e.ts >= today { st.xTodayTok += e.work; proj[e.project, default: (0, 0)].1 += e.work }
        if e.ts >= h5 { st.x5hTok += e.work }
        if e.ts >= now - 86400 { st.x24hTok += e.work }
        let hi = Int((e.ts - hourStart) / 3600)
        if hi >= 0 && hi < 24 { st.hourly[hi].1 += e.work }
    }
    for i in 0..<7 {
        let d = startOfDay(now - Double(6 - i) * 86400)
        st.daily.append((d, days[d]?.0 ?? 0, days[d]?.1 ?? 0))
    }
    st.projects = proj.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.2 > $1.2 }.prefix(4).map { $0 }

    // streak: consecutive days with any activity, ending today (or yesterday if nothing yet today)
    var day = today
    if !s.activeDays.contains(day) { day = startOfDay(day - 43200) }
    while s.activeDays.contains(day) { st.streak += 1; day = startOfDay(day - 43200) }
    return st
}

