import Foundation
import Testing
@testable import AirSQLCore

/// Liquibase against the lab (AIRSQL_LAB=1): the fixture schema (every column type, foreign keys, views, routines,
/// triggers, events, hostile names) written as a changelog with its rows, applied to an empty database statement by
/// statement as Liquibase splits them, and compared with the source. With a liquibase program on PATH the changelog is
/// also applied by Liquibase itself. Writes only in databases named lane_l8b_*.
@Suite(.serialized, .enabled(if: Lab.enabled, "AIRSQL_LAB=1 runs the lab tests"))
struct LiquibaseLabTests {
    static var settings: LiquibaseSettings {
        var settings = LiquibaseSettings()
        settings.author = "lab"
        return settings
    }

    /// Runs every changeset's statements in order, as Liquibase would.
    static func apply(_ text: String, on session: DBConnection) async throws -> Int {
        var count = 0
        for changeset in try LiquibaseChangelog(text).changesets {
            for statement in changeset.statements {
                _ = try await session.query(statement)
                count += 1
            }
        }
        return count
    }

    /// The fixture without the million rows of `big` (its structure still comes along).
    static func changelog(_ server: Lab.Server, layout: LiquibaseSettings.Layout = .oneFile) async throws -> (URL, LiquibaseOutcome) {
        let source = try await ReconLabTests.session(server)
        defer { Task { await source.close() } }
        let schema = try await LiquibaseSchema.read("fixture", from: source)
        let rows = Set(schema.objects.filter { $0.kind == .table && $0.name != "big" }.map(\.name))
        var settings = Self.settings
        settings.layout = layout
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-liquibase-lab-\(getpid())-\(server.name)")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = layout == .oneFile ? folder.appendingPathComponent("fixture.sql") : folder.appendingPathComponent("changelog")
        let outcome = try await schema.write(schema.pieces(.both, rows: rows, settings: settings), settings: settings,
                                             filters: ["customers": "id <> 0 OR id = 0"], to: url, from: source, cancellation: Cancellation())
        return (url, outcome)
    }

    /// No differences between the fixture and `database`: structure everywhere, rows everywhere but in `big`.
    static func expectSame(_ server: Lab.Server, _ database: String) async throws {
        let source = try await ReconLabTests.session(server), target = try await ReconLabTests.session(server)
        defer { Task { await source.close(); await target.close() } }
        var options = ReconOptions()
        options.mode = .structure
        let structure = try await ReconLabTests.compare(source, "fixture", target, database, options: options)
        #expect(structure.objects.count > 20)
        // Liquibase's own tables are only in a database it updated.
        for object in structure.objects where object.differs && !object.name.uppercased().hasPrefix("DATABASECHANGELOG") {
            Issue.record("\(server) \(object.kind) \(object.name): \(object.status) \(object.parts.map(\.detail))")
        }
        options.mode = .data
        options.tables["big"] = ReconTableChoice(included: false)
        let data = try await ReconLabTests.compare(source, "fixture", target, database, options: options)
        for object in data.objects where object.differs && !object.name.uppercased().hasPrefix("DATABASECHANGELOG") {
            Issue.record("\(server) rows of \(object.name): \(String(describing: object.data?.outcome))")
        }
    }

    @Test(arguments: [Lab.mariadb114, Lab.mysql84])
    func fixtureRoundTripsThroughAChangelog(_ server: Lab.Server) async throws {
        let (url, outcome) = try await Self.changelog(server)
        #expect(outcome.changesets > 30 && outcome.rows > 50, "\(outcome)")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix(LiquibaseChangelog.header + "\n"))
        #expect(!text.contains("DEFINER="), "DEFINER is left out")
        let target = try await ReconLabTests.session(server)
        defer { Task { await target.close() } }
        try await ReconLabTests.database(target, "lane_l8b_round_trip", [])
        let statements = try await Self.apply(text, on: target)
        #expect(statements > outcome.changesets)
        try await Self.expectSame(server, "lane_l8b_round_trip")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func folderLayoutIncludesEveryChangesetInOrder() async throws {
        let (folder, outcome) = try await Self.changelog(Lab.mariadb114, layout: .folder)
        let master = try String(contentsOf: folder.appendingPathComponent(Liquibase.masterName), encoding: .utf8)
        let files = master.components(separatedBy: "\n").filter { $0.contains("file: ") }.map { line in
            String(line.split(separator: "\"")[1])
        }
        #expect(files.count == outcome.changesets)
        let listed = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(listed) == Set(files + [Liquibase.masterName]), "nothing left behind: no hidden part files")
        var text = LiquibaseChangelog.header + "\n"
        for file in files {
            let part = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            #expect(try LiquibaseChangelog(part).changesets.count == 1, "\(file)")
            text += "\n" + part.dropFirst(LiquibaseChangelog.header.count + 2)
        }
        let target = try await ReconLabTests.session(Lab.mariadb114)
        defer { Task { await target.close() } }
        try await ReconLabTests.database(target, "lane_l8b_folder", [])
        _ = try await Self.apply(text, on: target)
        try await Self.expectSame(Lab.mariadb114, "lane_l8b_folder")
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    /// Liquibase itself applies the changelog, when a liquibase program is installed (AirSQL doesn't install one).
    @Test(.enabled(if: liquibase != nil, "runs when a liquibase program is on PATH"))
    func liquibaseAppliesTheChangelog() async throws {
        let (url, _) = try await Self.changelog(Lab.mariadb114)
        let target = try await ReconLabTests.session(Lab.mariadb114)
        defer { Task { await target.close() } }
        try await ReconLabTests.database(target, "lane_l8b_liquibase", [])
        let process = Process()
        process.executableURL = Self.liquibase  // the test runs only when there is one
        process.currentDirectoryURL = url.deletingLastPathComponent()
        process.arguments = ["--changelog-file=" + url.lastPathComponent, "--url=jdbc:mariadb://127.0.0.1:\(Lab.mariadb114.port ?? 0)/lane_l8b_liquibase",
                             "--username=" + Lab.airsql.user, "update"]
        // The password in the environment, never on the command line.
        process.environment = ProcessInfo.processInfo.environment.merging(["LIQUIBASE_COMMAND_PASSWORD": Lab.airsql.password]) { $1 }
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        try await Self.expectSame(Lab.mariadb114, "lane_l8b_liquibase")
    }

    static let liquibase: URL? = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .map { URL(fileURLWithPath: String($0)).appendingPathComponent("liquibase") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}
