import Foundation
import SQLite3
import WinnowCore

/// SQLite cache in ~/Library/Application Support/Winnow/winnow.sqlite (PLAN.md Phase 2).
/// Analysis rows are dropped automatically when `AnalysisService.version` changes.
/// Uses the system libsqlite3, so there are no package dependencies.
///
/// Also holds review state that must survive relaunch (Phase 5): the pending
/// deletion bin and the IDs of confirmed groups.
actor AnalysisCache {
    struct Entry: Sendable {
        var modified: Date
        var vector: FeatureVector
        var signals: QualitySignals
    }

    private var db: OpaquePointer?

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Winnow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("winnow.sqlite")
    }

    init(url: URL = AnalysisCache.defaultURL) {
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) != SQLITE_OK {
            Log.scan.error("sqlite open failed at \(url.path)")
        }
        db = handle
        Self.exec(handle, """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS asset(
                id TEXT PRIMARY KEY, mod_date REAL NOT NULL, feature_print BLOB NOT NULL,
                aesthetics REAL NOT NULL, is_utility INTEGER NOT NULL,
                sharpness REAL NOT NULL, face_quality REAL);
            CREATE TABLE IF NOT EXISTS confirmed_group(group_id TEXT PRIMARY KEY, confirmed_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS pending(id TEXT PRIMARY KEY, seq INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS reviewed_asset(id TEXT PRIMARY KEY, tolerance REAL NOT NULL, at REAL NOT NULL);
            """)
        // Analysis made with different settings isn't comparable: drop it.
        // (Review state — bin and confirmed groups — is kept.)
        var stored: String?
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT value FROM meta WHERE key = 'analysis_version'", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            stored = String(cString: sqlite3_column_text(stmt, 0))
        }
        sqlite3_finalize(stmt)
        if stored != AnalysisService.version {
            Log.scan.notice("analysis cache version \(stored ?? "none") -> \(AnalysisService.version): clearing")
            Self.exec(handle, """
                DELETE FROM asset;
                INSERT OR REPLACE INTO meta VALUES ('analysis_version', '\(AnalysisService.version)');
                """)
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Analysis entries

    /// Entries for the given IDs, skipping any whose cached mod date is stale.
    func entries(for wanted: [AssetID: Date]) -> [AssetID: Entry] {
        var out: [AssetID: Entry] = [:]
        out.reserveCapacity(wanted.count)
        let sql = "SELECT id, mod_date, feature_print, aesthetics, is_utility, sharpness, face_quality FROM asset"
        query(sql) { stmt in
            let id = AssetID(String(cString: sqlite3_column_text(stmt, 0)))
            guard let want = wanted[id] else { return }
            let modified = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            guard abs(modified.timeIntervalSince(want)) < 0.001 else { return }
            let bytes = sqlite3_column_blob(stmt, 2)
            let length = Int(sqlite3_column_bytes(stmt, 2))
            let data = bytes.map { Data(bytes: $0, count: length) } ?? Data()
            let face = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6)
            out[id] = Entry(modified: modified, vector: FeatureVector(data: data),
                            signals: QualitySignals(aesthetics: sqlite3_column_double(stmt, 3),
                                                    sharpness: sqlite3_column_double(stmt, 5),
                                                    faceQuality: face,
                                                    isUtility: sqlite3_column_int(stmt, 4) != 0))
        }
        return out
    }

    func save(_ entries: [(AssetID, Entry)]) {
        guard !entries.isEmpty else { return }
        transaction {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO asset VALUES (?,?,?,?,?,?,?)", -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            for (id, e) in entries {
                sqlite3_reset(stmt)
                bindText(stmt, 1, id.rawValue)
                sqlite3_bind_double(stmt, 2, e.modified.timeIntervalSinceReferenceDate)
                let data = e.vector.data
                _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
                sqlite3_bind_double(stmt, 4, e.signals.aesthetics)
                sqlite3_bind_int(stmt, 5, e.signals.isUtility ? 1 : 0)
                sqlite3_bind_double(stmt, 6, e.signals.sharpness)
                if let f = e.signals.faceQuality { sqlite3_bind_double(stmt, 7, f) } else { sqlite3_bind_null(stmt, 7) }
                sqlite3_step(stmt)
            }
        }
    }

    // MARK: - Review state

    func confirmedGroups() -> Set<String> {
        var out = Set<String>()
        query("SELECT group_id FROM confirmed_group") { out.insert(String(cString: sqlite3_column_text($0, 0))) }
        return out
    }

    func setConfirmed(add: Set<String>, remove: Set<String>) {
        transaction {
            for id in add { run("INSERT OR REPLACE INTO confirmed_group VALUES (?, ?)", id, Date().timeIntervalSinceReferenceDate) }
            for id in remove { run("DELETE FROM confirmed_group WHERE group_id = ?", id) }
        }
    }

    /// Photos kept in a confirmed group, with the tolerance of that pass (0 = duplicates pass).
    func reviewedAssets() -> [AssetID: Float] {
        var out: [AssetID: Float] = [:]
        query("SELECT id, tolerance FROM reviewed_asset") {
            out[AssetID(String(cString: sqlite3_column_text($0, 0)))] = Float(sqlite3_column_double($0, 1))
        }
        return out
    }

    func setReviewed(add: [AssetID: Float], remove: Set<AssetID>) {
        transaction {
            for id in remove { run("DELETE FROM reviewed_asset WHERE id = ?", id.rawValue) }
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO reviewed_asset VALUES (?, ?, ?)", -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            for (id, tolerance) in add {
                sqlite3_reset(stmt)
                bindText(stmt, 1, id.rawValue)
                sqlite3_bind_double(stmt, 2, Double(tolerance))
                sqlite3_bind_double(stmt, 3, Date().timeIntervalSinceReferenceDate)
                sqlite3_step(stmt)
            }
        }
    }

    func pending() -> [AssetID] {
        var out: [AssetID] = []
        query("SELECT id FROM pending ORDER BY seq") { out.append(AssetID(String(cString: sqlite3_column_text($0, 0)))) }
        return out
    }

    func setPending(_ ids: [AssetID]) {
        transaction {
            Self.exec(db, "DELETE FROM pending")
            for (i, id) in ids.enumerated() { run("INSERT INTO pending VALUES (?, ?)", id.rawValue, Double(i)) }
        }
    }

    // MARK: - SQLite helpers

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            Log.scan.error("sqlite: \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    private func transaction(_ body: () -> Void) {
        Self.exec(db, "BEGIN")
        body()
        Self.exec(db, "COMMIT")
    }

    private func query(_ sql: String, row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    /// One-shot statement with a text first parameter and optional double second.
    private func run(_ sql: String, _ text: String, _ number: Double? = nil) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, text)
        if let number { sqlite3_bind_double(stmt, 2, number) }
        sqlite3_step(stmt)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
