import Foundation
import SQLite3

private var db: OpaquePointer?
private let dbPath = "/tmp/netcutx_stealth.db"

func dbOpen() -> Bool {
    guard db == nil else { return true }
    guard sqlite3_open(dbPath, &db) == SQLITE_OK else { db = nil; return false }
    for sql in [
        "PRAGMA journal_mode=WAL",
        "CREATE TABLE IF NOT EXISTS devices(ip TEXT PRIMARY KEY,mac TEXT,hostname TEXT,vendor TEXT,os TEXT,os_conf REAL,first_seen TEXT,last_seen TEXT,open_ports TEXT,services TEXT,notes TEXT)",
        "CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT,ts TEXT,device_ip TEXT,event_type TEXT,detail TEXT)",
        "CREATE TABLE IF NOT EXISTS credentials(id INTEGER PRIMARY KEY AUTOINCREMENT,device_ip TEXT,service TEXT,username TEXT,password TEXT,success INTEGER)",
        "CREATE TABLE IF NOT EXISTS config(key TEXT PRIMARY KEY,value TEXT)",
    ] { sqlite3_exec(db, sql, nil, nil, nil) }
    return true
}

func dbClose() { if let d = db { sqlite3_close(d); db = nil } }

@discardableResult
func dbExec(_ sql: String) -> Bool {
    guard let d = db else { return false }
    var err: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(d, sql, nil, nil, &err)
    if rc != SQLITE_OK, let e = err { fputs("DB: \(String(cString: e))\n", stderr); sqlite3_free(err) }
    return rc == SQLITE_OK
}

func dbQuery(_ sql: String) -> [[String: String]] {
    guard let d = db else { return [] }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(d, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
    defer { sqlite3_finalize(s) }
    var rows: [[String: String]] = []
    while sqlite3_step(s) == SQLITE_ROW {
        var row: [String: String] = [:]
        for i in 0..<sqlite3_column_count(s) {
            let name = String(cString: sqlite3_column_name(s, i))
            row[name] = sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
        }
        rows.append(row)
    }
    return rows
}

func dbUpsertDevice(ip: String, mac: String, hostname: String = "", vendor: String = "",
                     os: String = "", osConf: Float = 0, ports: [Int] = [], services: String = "") {
    let portsJson = (try? JSONSerialization.data(withJSONObject: ports)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    let now = ISO8601DateFormatter().string(from: Date())
    dbExec("""
        INSERT INTO devices(ip,mac,hostname,vendor,os,os_conf,first_seen,last_seen,open_ports,services)
        VALUES('\(esc(ip))','\(esc(mac))','\(esc(hostname))','\(esc(vendor))','\(esc(os))',\(osConf),'\(now)','\(now)','\(esc(portsJson))','\(esc(services))')
        ON CONFLICT(ip)DO UPDATE SET
        mac=excluded.mac,hostname=excluded.hostname,vendor=excluded.vendor,os=excluded.os,
        os_conf=excluded.os_conf,last_seen='\(now)',open_ports=excluded.open_ports,services=excluded.services
    """)
}

func dbInsertEvent(_ ip: String, _ type: String, _ detail: String = "") {
    let now = ISO8601DateFormatter().string(from: Date())
    dbExec("INSERT INTO events(ts,device_ip,event_type,detail)VALUES('\(now)','\(esc(ip))','\(esc(type))','\(esc(detail))')")
}

func dbInsertCred(_ ip: String, _ service: String, _ user: String, _ pass: String, _ ok: Int) {
    dbExec("INSERT INTO credentials(device_ip,service,username,password,success)VALUES('\(esc(ip))','\(esc(service))','\(esc(user))','\(esc(pass))',\(ok))")
}

private func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }
