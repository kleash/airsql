import Foundation

/// Text that recreates objects, from their SHOW CREATE statements (scope: "See the CREATE or ALTER SQL before it runs"): for
/// Copy CREATE of several objects and the SQL Generator, one script or a file per object. Reads only; nothing here runs.
public struct DDLScript {
    /// An object with the statement the server shows for it. `table`: a trigger's.
    public struct Item: Equatable {
        public var object: DatabaseObject
        public var code: String
        public var table: String?

        public init(_ object: DatabaseObject, code: String, table: String? = nil) {
            self.object = object
            self.code = code
            self.table = table
        }
    }

    public struct Options: Equatable {
        public var ifNotExists = false
        public var orReplace = false
        public var skipDefiner = false
        public var databaseNames = false
        public var indexes = true
        public var foreignKeys = true
        public var autoIncrement = true
        public var triggers = true

        public init() {}
    }

    /// How Save to Folder lays its files out.
    public enum Layout: Int, CaseIterable {
        case flat, byKind, byDatabase, numbered
    }

    public var items: [Item]
    public var options = Options()
    public var server: SchemaServer

    public init(_ items: [Item], options: Options = Options(), server: SchemaServer) {
        self.items = items
        self.options = options
        self.server = server
    }

    /// Reads each object's statement, in order. `triggers`: the triggers of the tables among them, read too.
    public static func load(_ objects: [DatabaseObject], triggers: [DatabaseObject: String] = [:], from source: SchemaQuerying)
        async throws -> [Item] {
        var items: [Item] = []
        for object in objects {
            try Task.checkCancellation()
            let column = ObjectKind(rawValue: object.kind.rawValue)?.columns.code ?? 1
            let row = try await source.rows(NavigatorSQL.showCreate(object)).first
            guard let row, column < row.count, let code = row[column] else {
                throw DesignError("The server didn't show how \(object.name) is made: you may not have the right to see it")
            }
            items.append(Item(object, code: code, table: triggers[object]))
        }
        return items
    }

    /// The objects in an order that runs: tables, sequences, views, routines, then triggers and events. Views may read
    /// each other, in the order given.
    private var ordered: [Item] {
        let order: [DatabaseObject.Kind] = [.table, .sequence, .view, .function, .procedure, .trigger, .event]
        let wanted = options.triggers ? items : items.filter { $0.table == nil }
        return wanted.enumerated().sorted {
            (order.firstIndex(of: $0.element.object.kind) ?? 0, $0.offset) < (order.firstIndex(of: $1.element.object.kind) ?? 0, $1.offset)
        }.map(\.element)
    }

    /// Every statement in one script. Tables are written in any order, so foreign key checks are off while they run.
    public var text: String {
        let statements = ordered.map(statement)
        let tables = ordered.filter { $0.object.kind == .table }
        guard options.foreignKeys, tables.count > 1, tables.contains(where: { $0.code.contains(" FOREIGN KEY ") }) else {
            return statements.joined(separator: "\n\n") + "\n"
        }
        return (["SET FOREIGN_KEY_CHECKS = 0;"] + statements + ["SET FOREIGN_KEY_CHECKS = 1;"]).joined(separator: "\n\n") + "\n"
    }

    /// A file per object: its path under the folder chosen, and its text. No name can climb out of that folder, and no two
    /// files differ only by case (a Mac's disk takes them as the same).
    public func files(_ layout: Layout) -> [(path: String, text: String)] {
        var taken = Set<String>()
        return ordered.enumerated().map { offset, item in
            let folder = item.object.kind.rawValue + "s"
            let file = Self.fileName(item.object.name)
            let base: String
            switch layout {
            case .flat: base = file
            case .byKind: base = folder + "/" + file
            case .byDatabase: base = Self.fileName(item.object.database) + "/" + folder + "/" + file
            case .numbered: base = String(format: "%03d_", offset + 1) + file
            }
            var path = base + ".sql", copy = 1
            while !taken.insert(path.lowercased()).inserted {
                copy += 1
                path = base + "-\(copy).sql"
            }
            return (path, statement(item) + "\n")
        }
    }

    /// A name as one part of a path.
    static func fileName(_ name: String) -> String {
        let safe = name.map { "/:\\\0".contains($0) || $0.isNewline ? "_" : $0 }
        let text = String(safe)
        return text.hasPrefix(".") ? "_" + text.dropFirst() : text.isEmpty ? "_" : text
    }

    /// The object's statement with the options applied, ended as a client takes it: a body with `;` in it goes in DELIMITER
    /// lines.
    func statement(_ item: Item) -> String {
        let code = rewritten(item).trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBody = [.procedure, .function, .trigger, .event].contains(item.object.kind) && code.contains(";")
        return hasBody ? "DELIMITER ;;\n" + code + ";;\nDELIMITER ;" : code + ";"
    }

    private func rewritten(_ item: Item) -> String {
        let object = item.object
        switch object.kind {
        case .table:
            return prefixed(tableBody(item.code), "CREATE TABLE ", object, ifNotExists: options.ifNotExists)
        case .sequence:
            return prefixed(item.code, "CREATE SEQUENCE ", object, ifNotExists: options.ifNotExists)
        default:
            var code = options.skipDefiner ? ObjectCode.settingDefiner(item.code, to: nil) : item.code
            guard let header = CreateHeader(code) else { return code }
            if options.databaseNames {
                code.replaceSubrange(header.nameRange, with: object.quoted)
            } else if header.database != nil {
                code.replaceSubrange(header.nameRange, with: SQLQuote.identifier(object.name))
            }
            // MySQL has OR REPLACE for views only; a statement can't have it and IF NOT EXISTS.
            if options.orReplace, !header.orReplace, object.kind == .view || server.flavour == .mariadb {
                code.insert(contentsOf: " OR REPLACE", at: header.afterCreate)
            } else if options.ifNotExists, !header.orReplace, object.kind == .event || server.flavour == .mariadb {
                code.insert(contentsOf: " IF NOT EXISTS", at: header.afterKind)
            }
            return code
        }
    }

    /// `prefix` then the name: with IF NOT EXISTS and the database when asked. Code of another form stays as it is.
    private func prefixed(_ code: String, _ prefix: String, _ object: DatabaseObject, ifNotExists: Bool) -> String {
        guard code.hasPrefix(prefix) else { return code }
        var scanner = HeaderScanner(code)
        scanner.index = code.index(code.startIndex, offsetBy: prefix.count)
        guard scanner.name() != nil else { return code }
        let name = options.databaseNames ? object.quoted : SQLQuote.identifier(object.name)
        return prefix + (ifNotExists ? "IF NOT EXISTS " : "") + name + code[scanner.index...]
    }

    /// SHOW CREATE TABLE's text without the lines left out, a line per column, key and constraint as the server writes it
    /// (a comment's line breaks come escaped).
    private func tableBody(_ code: String) -> String {
        var lines = code.components(separatedBy: "\n").filter { line in
            if !options.foreignKeys, line.hasPrefix("  CONSTRAINT "), line.contains(" FOREIGN KEY ") { return false }
            if !options.indexes, ["  KEY ", "  UNIQUE KEY ", "  FULLTEXT KEY ", "  SPATIAL KEY ", "  VECTOR KEY "].contains(where: line.hasPrefix) {
                return false
            }
            return true
        }
        if let close = lines.firstIndex(where: { $0.hasPrefix(")") }), close > 0, lines[close - 1].hasSuffix(",") {
            lines[close - 1].removeLast()
        }
        if !options.autoIncrement, let close = lines.firstIndex(where: { $0.hasPrefix(")") }) {
            lines[close] = lines[close].replacingOccurrences(of: " AUTO_INCREMENT=[0-9]+", with: "", options: .regularExpression)
        }
        return lines.joined(separator: "\n")
    }
}
