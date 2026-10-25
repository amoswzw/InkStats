import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Per-minute averages of every series, kept in SQLite so long ranges survive restarts.
final class HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "inkstats.history")
    let url: URL

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InkStats", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("history.sqlite")
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { db = nil; return }
        exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS samples (
                series TEXT NOT NULL,
                minute INTEGER NOT NULL,
                value REAL NOT NULL,
                PRIMARY KEY (series, minute)
            ) WITHOUT ROWID;
            """)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func insert(minute: Int64, values: [Series: Double]) {
        queue.async { [self] in
            guard let db else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO samples (series, minute, value) VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            exec("BEGIN")
            for (series, value) in values where value.isFinite {
                sqlite3_bind_text(statement, 1, series.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(statement, 2, minute)
                sqlite3_bind_double(statement, 3, value)
                sqlite3_step(statement)
                sqlite3_reset(statement)
            }
            exec("COMMIT")
        }
    }

    /// Averages over `buckets` equal slices ending now. A slice with no data is nil.
    func averages(_ series: Series, minutes: Int64, buckets: Int) -> [Double?] {
        let now = Int64(Date().timeIntervalSince1970 / 60)
        let start = now - minutes
        let width = max(1, minutes / Int64(buckets))
        var result = [Double?](repeating: nil, count: buckets)
        queue.sync {
            guard let db else { return }
            var statement: OpaquePointer?
            let sql = "SELECT (minute - ?) / ? AS bucket, AVG(value) FROM samples WHERE series = ? AND minute >= ? GROUP BY bucket"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, start)
            sqlite3_bind_int64(statement, 2, width)
            sqlite3_bind_text(statement, 3, series.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 4, start)
            while sqlite3_step(statement) == SQLITE_ROW {
                let bucket = Int(sqlite3_column_int64(statement, 0))
                if bucket >= 0, bucket < buckets { result[bucket] = sqlite3_column_double(statement, 1) }
            }
        }
        return result
    }

    func prune(keepingDays days: Int) {
        let cutoff = Int64(Date().timeIntervalSince1970 / 60) - Int64(days) * 24 * 60
        queue.async { [self] in exec("DELETE FROM samples WHERE minute < \(cutoff)") }
    }

    func clear() {
        queue.async { [self] in exec("DELETE FROM samples; VACUUM;") }
    }

    func waitForPendingWrites() {
        queue.sync {}
    }

    func sizeOnDisk() -> Int64 {
        let paths = [url.path, url.path + "-wal"]
        return paths.reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }
}

/// Collects one minute of samples and writes their averages when the minute rolls over.
final class MinuteAggregator {
    private var minute: Int64 = 0
    private var sums: [Series: (total: Double, count: Int)] = [:]

    func add(_ values: [Series: Double]) {
        let now = Int64(Date().timeIntervalSince1970 / 60)
        if now != minute { flush(); minute = now }
        for (series, value) in values {
            let entry = sums[series] ?? (0, 0)
            sums[series] = (entry.total + value, entry.count + 1)
        }
    }

    func flush() {
        guard minute != 0, !sums.isEmpty else { return }
        HistoryStore.shared.insert(minute: minute, values: sums.mapValues { $0.total / Double($0.count) })
        sums.removeAll()
    }
}

enum GraphRange: String, CaseIterable {
    case live, hour, day, week

    var title: String {
        switch self {
        case .live: return "2m"
        case .hour: return "1h"
        case .day: return "24h"
        case .week: return "7d"
        }
    }
}

/// Where a panel's graph reads its points from.
protocol SeriesSource {
    func series(_ series: Series) -> [Double?]
}

struct StoredSeries: SeriesSource {
    let range: GraphRange

    func series(_ series: Series) -> [Double?] {
        let (minutes, buckets): (Int64, Int)
        switch range {
        case .live: return []
        case .hour: (minutes, buckets) = (60, 60)
        case .day: (minutes, buckets) = (24 * 60, 96)
        case .week: (minutes, buckets) = (7 * 24 * 60, 84)
        }
        let own = HistoryStore.shared.averages(series, minutes: minutes, buckets: buckets)
        // The system power log reaches back before InkStats was installed; prefer our own
        // per-minute data where both exist.
        guard series == .battery, let system = PowerLog.batteryAverages(minutes: minutes, buckets: buckets) else { return own }
        return zip(own, system).map { $0 ?? $1 }
    }
}
