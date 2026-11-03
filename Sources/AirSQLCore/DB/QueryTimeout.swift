import Foundation

extension DBConnection {
    /// `query`, stopped when it runs longer than `seconds` (0: no limit): a connection's query timeout
    /// (`SavedConnection.queryTimeout`), through Cancel's own safe KILL QUERY.
    public func query(_ sql: String, rowCap: Int = 100_000, timeout seconds: Int) async throws -> [StatementResult] {
        guard seconds > 0 else { return try await query(sql, rowCap: rowCap) }
        let started = Date()
        let watchdog = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            _ = try? await self?.cancel()
        }
        defer { watchdog.cancel() }
        do {
            return try await query(sql, rowCap: rowCap)
        } catch var error as AirSQLError where error.kind == .cancelled && Date().timeIntervalSince(started) >= Double(seconds) {
            error.message = "The statement ran longer than \(seconds) s, this connection's query timeout, and was stopped."
            throw error
        }
    }
}
