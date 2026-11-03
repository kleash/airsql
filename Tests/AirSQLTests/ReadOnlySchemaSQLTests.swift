@testable import AirSQLCore
import Testing

/// Every statement the schema session sends passes the read-only check, so the agent gate never asks about the
/// navigator's own queries.
struct ReadOnlySchemaSQLTests {
    @Test(arguments: ["10.11.9-MariaDB", "11.4.2-MariaDB", "5.7.44", "8.0.40", "8.4.3", "9.1.0"], [false, true])
    func introspectionIsReadOnly(version: String, noBackslashEscapes: Bool) {
        let schema = SchemaIntrospection(server: SchemaServer(version: version,
                                                              sqlMode: noBackslashEscapes ? "NO_BACKSLASH_ESCAPES" : ""))
        let names = Hostile.names
        var sql = [SchemaIntrospection.serverSQL, schema.databasesSQL(nil), schema.databasesSQL(names),
                   schema.statisticsSQL("shop"), schema.statisticsSQL(names[0], tables: names)]
        if let setup = schema.statisticsSetupSQL { sql.append(setup) }
        for scope: SchemaScope in [.databases(nil), .databases(names), .objects(database: names[0], names: names)] {
            sql += [schema.tablesSQL(scope), schema.routinesSQL(scope), schema.triggersSQL(scope),
                    schema.triggersSQL(scope, byTable: true), schema.eventsSQL(scope), schema.columnsSQL(scope),
                    schema.indexesSQL(scope), schema.foreignKeysSQL(scope), schema.foreignKeyRulesSQL(scope)]
                + schema.checksSQL(scope)
        }
        for statement in sql {
            #expect(ReadOnlyClassifier.classify(statement, noBackslashEscapes: noBackslashEscapes) == .readOnly,
                    "\(statement)")
        }
    }
}
