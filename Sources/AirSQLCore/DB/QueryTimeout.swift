import Foundation

extension DBConnection {
    /// `query`, stopped when it runs longer than `seconds` (0: no limit): a connection's query timeout
    /// (`SavedConnection.queryTimeout`), through Cancel's own safe KILL QUERY. A stopped statement throws, even one the
    /// server ends quietly (a lone SLEEP returns 1).
    public func query(_ sql: String, rowCap: Int = 100_000, timeout seconds: Int) async throws -> [StatementResult] {
        guard seconds > 0 else { return try await query(sql, rowCap: rowCap) }
        let watchdog = Task { [weak self] () -> Bool in
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            return (try? await self?.cancel()) == .cancelled
        }
        var results: [StatementResult] = [], failure: Error?
        do {
            results = try await query(sql, rowCap: rowCap)
        } catch {
            failure = error
        }
        watchdog.cancel()
        guard (try? await watchdog.value) == true else {
            if let failure { throw failure }
            return results
        }
        var error = failure as? AirSQLError ?? AirSQLError(.cancelled, "")
        error.kind = .cancelled
        error.message = "The statement ran longer than \(seconds) s, this connection's query timeout, and was stopped."
        throw error
    }
}
