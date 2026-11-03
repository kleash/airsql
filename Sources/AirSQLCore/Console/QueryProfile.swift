import Foundation

/// Query ▸ Profile (plan §2.6): where the server spent a statement's time. MySQL 8 and later deprecate SHOW PROFILE, so
/// there performance_schema answers when it is on and the login can read it: the statement's stages
/// (events_stages_history_long), else the statement's own figures (events_statements_history). SHOW PROFILE answers
/// elsewhere. The statements around the person's are AirSQL's own, so the agents' gate doesn't ask about them.
public struct QueryProfile {
    /// The session's thread in performance_schema; nil: SHOW PROFILE answers.
    let thread: UInt64?
    /// Why performance_schema doesn't answer on MySQL 8 or later, as the end of a sentence.
    let why: String?

    /// Before the statement: finds out which answers, and turns SHOW PROFILE's switch on when it is that.
    public static func start(on session: DBConnection) async -> QueryProfile {
        await AgentGate.$agent.withValue(nil) {
            var why: String?
            if let server = session.server, server.flavor == .mysql, server.atLeast(8) {
                if (try? await session.query("SELECT @@performance_schema").first?.rows?.string(0, 0)) != "1" {
                    why = "performance_schema is off on this server"
                } else {
                    do {
                        let rows = try await session.query("SELECT THREAD_ID FROM performance_schema.threads WHERE "
                                                           + "PROCESSLIST_ID = CONNECTION_ID()").first?.rows
                        if let thread = rows?.string(0, 0).flatMap(UInt64.init) { return QueryProfile(thread: thread, why: nil) }
                        why = "performance_schema doesn't follow this session"
                    } catch {
                        why = "this login can't read performance_schema"
                    }
                }
            }
            _ = try? await session.query("SET profiling = 1")
            return QueryProfile(thread: nil, why: why)
        }
    }

    /// After the statement: its profile, if the server kept one, and a note to show with it or in its place.
    public func read(on session: DBConnection) async -> (rows: ResultStore?, note: String?) {
        await AgentGate.$agent.withValue(nil) {
            guard let thread else { return await showProfile(on: session) }
            // The person's statement: the last at the top level (not in a procedure) that isn't AirSQL's SHOW WARNINGS.
            let history = "performance_schema.events_statements_history WHERE THREAD_ID = \(thread)"
            let list = try? await session.query("SELECT EVENT_ID, SQL_TEXT FROM \(history) AND (NESTING_EVENT_TYPE IS NULL "
                                                + "OR NESTING_EVENT_TYPE <> 'STATEMENT') ORDER BY EVENT_ID DESC").first?.rows
            guard let list, let event = (0..<list.rowCount).first(where: { !(list.string($0, 1) ?? "").contains("SHOW WARNINGS") })
                .flatMap({ list.string($0, 0) }).flatMap(UInt64.init) else {
                return (nil, "performance_schema kept no record of the statement (its events_statements_history consumer is "
                        + "off), so there is no profile.")
            }
            let stages = try? await session.query("SELECT SUBSTRING_INDEX(EVENT_NAME, '/', -1) AS Status, "
                                                  + "ROUND(TIMER_WAIT / 1000000000000, 6) AS Duration FROM "
                                                  + "performance_schema.events_stages_history_long WHERE THREAD_ID = \(thread) "
                                                  + "AND NESTING_EVENT_ID = \(event) ORDER BY EVENT_ID").first?.rows
            if let stages, stages.rowCount > 0 { return (stages, nil) }
            let figures = try? await session.query(
                "SELECT ROUND(TIMER_WAIT / 1000000000000, 6) AS `Duration (s)`, ROUND(LOCK_TIME / 1000000000000, 6) AS "
                    + "`Lock time (s)`, ROWS_EXAMINED AS `Rows examined`, ROWS_SENT AS `Rows sent`, ROWS_AFFECTED AS "
                    + "`Rows affected`, CREATED_TMP_TABLES AS `Temporary tables`, CREATED_TMP_DISK_TABLES AS `On disk`, "
                    + "SORT_ROWS AS `Rows sorted`, SELECT_SCAN AS `Full scans`, NO_INDEX_USED AS `No index used` FROM "
                    + "\(history) AND EVENT_ID = \(event)").first?.rows
            return (figures, "performance_schema records no stages here (its events_stages_history_long consumer is off), "
                    + "so these are the statement's own figures.")
        }
    }

    /// SHOW PROFILE: the last statement profiled that isn't AirSQL's SHOW WARNINGS after it; then the switch goes off.
    private func showProfile(on session: DBConnection) async -> (rows: ResultStore?, note: String?) {
        let list = try? await session.query("SHOW PROFILES").first?.rows
        let id = list.flatMap { rows in
            (0..<rows.rowCount).last { !(rows.string($0, 2) ?? "").contains("SHOW WARNINGS") }.flatMap { rows.string($0, 0) }
        }.flatMap { Int($0) }
        var rows: ResultStore?
        if let id { rows = try? await session.query("SHOW PROFILE FOR QUERY \(id)").first?.rows }
        _ = try? await session.query("SET profiling = 0")
        guard let rows else {
            return (nil, "This server keeps no profile of the statement: " + (why.map { $0 + ", and " } ?? "")
                    + "SHOW PROFILE isn't available.")
        }
        return (rows, why.map { "This profile comes from SHOW PROFILE, which MySQL has deprecated: " + $0 + "." })
    }
}
