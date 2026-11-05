import Foundation

/// A compare's report to save: HTML to read or send, CSV for a spreadsheet (every difference, one per line),
/// Markdown for a ticket. HTML and Markdown list at most `rowsShown` rows per table.
public enum ReconReport {
    public enum Format: String, CaseIterable {
        case html, csv, markdown

        public var fileExtension: String { self == .markdown ? "md" : rawValue }
    }

    public static let rowsShown = 1_000

    /// One difference, as each format writes it.
    public struct Line {
        public var kind: String, object: String, status: String, difference: String, item: String, detail: String
    }

    public static func text(_ result: ReconResult, format: Format) -> String {
        switch format {
        case .csv: return csv(result)
        case .markdown: return markdown(result)
        case .html: return html(result)
        }
    }

    /// The summary the compare window shows too.
    public static func summary(_ result: ReconResult) -> [(label: String, value: String)] {
        if result.isServer { return serverSummary(result) }
        let tables = result.objects.filter { $0.kind == .table }
        let others = result.objects.filter { $0.kind != .table }
        let rows = tables.filter { $0.status == .same || $0.status == .different }.compactMap(\.data).filter(\.differs)
        let matching = tables.filter { !$0.differs }.count, different = tables.filter { $0.status == .different }.count
        let changed = rows.reduce(0) { $0 + $1.differenceCount }
        return [(matching == 1 ? "table matches" : "tables match", matching.formatted()),
                (different == 1 ? "table differs in structure" : "tables differ in structure", different.formatted()),
                ("only in \(result.source.name)", result.objects.filter { $0.status == .onlyInSource }.count.formatted()),
                ("only in \(result.target.name)", result.objects.filter { $0.status == .onlyInTarget }.count.formatted()),
                ("\(changed == 1 ? "row differs" : "rows differ") in \(rows.count) \(rows.count == 1 ? "table" : "tables")",
                 changed.formatted()),
                ("views, routines, triggers and events differ", others.filter { $0.status == .different }.count.formatted())]
    }

    /// The same six figures for two servers: the pairs, then what differs within them.
    private static func serverSummary(_ result: ReconResult) -> [(label: String, value: String)] {
        let pairs = result.objects
        let matching = pairs.filter { $0.status == .same }.count, different = pairs.filter { $0.status == .different }.count
        let tables = result.databases.values.flatMap(\.objects).filter { $0.kind == .table }.compactMap(\.data).filter(\.differs)
        let rows = tables.reduce(0) { $0 + $1.differenceCount }
        let objects = result.databases.values.flatMap(\.objects).filter(\.differs).count
        return [(matching == 1 ? "database matches" : "databases match", matching.formatted()),
                (different == 1 ? "database differs" : "databases differ", different.formatted()),
                ("only in \(result.source.name)", pairs.filter { $0.status == .onlyInSource }.count.formatted()),
                ("only in \(result.target.name)", pairs.filter { $0.status == .onlyInTarget }.count.formatted()),
                ("\(rows == 1 ? "row differs" : "rows differ") in \(tables.count) \(tables.count == 1 ? "table" : "tables")",
                 rows.formatted()),
                ("objects differ in those databases", objects.formatted())]
    }

    /// How an object compares, in plain words: "different structure and data", "only in Production".
    public static func status(_ object: ReconObject, _ result: ReconResult) -> String {
        switch object.status {
        case .same: return object.data?.differs == true ? "different data" : "same"
        case .different where object.kind == .database: return "different"
        case .different: return object.data?.differs == true ? "different structure and data" : "different structure"
        case .onlyInSource: return "only in \(result.source.name)"
        case .onlyInTarget: return "only in \(result.target.name)"
        }
    }

    /// Every difference of an object: its structure parts, then its rows (at most `limit`).
    public static func lines(_ object: ReconObject, _ result: ReconResult, limit: Int = .max) -> [Line] {
        let status = self.status(object, result)
        func line(_ difference: String, _ item: String, _ detail: String) -> Line {
            Line(kind: object.kind.rawValue, object: object.name, status: status, difference: difference, item: item,
                 detail: detail)
        }
        var lines = object.parts.map { line("structure", "\($0.kind.rawValue) \($0.name)", $0.detail) }
        if let pair = result.databases[object.name] {
            // A pair of databases: its objects' differences, each named within the database.
            return lines + pair.objects.filter(\.differs).flatMap { inner in
                Self.lines(inner, pair, limit: limit).map { found in
                    var found = found
                    found.object = "\(object.name).\(found.object)"
                    return found
                }
            }
        }
        guard let data = object.data else { return lines }
        let columns = data.columns
        let width = min(max(data.key.count, columns.isEmpty ? 0 : 1), columns.count)
        func key(_ row: ReconRow) -> String {
            (0..<width).map { "\(columns[$0].name)=\(value(row, $0, columns))" }.joined(separator: ", ")
        }
        func rest(_ row: ReconRow, _ side: String) -> String {
            (["only in \(side)"] + (width..<columns.count).map { "\(columns[$0].name)=\(value(row, $0, columns))" })
                .joined(separator: "; ")
        }
        switch data.outcome {
        case .notCompared(let why): lines.append(line("rows", "", "not compared: \(why)"))
        case .differentWithoutKey: lines.append(line("rows", "", "different (no key to match rows on)"))
        case .tooManyDifferences:
            lines.append(line("rows", "", "more than \(ReconDataCompare.maxDifferences) rows differ"))
        case .same, .different:
            let changes = data.changed.prefix(limit).map { change in
                line("changed row", key(change.source), change.columns.map { column in
                    "\(columns[column].name): \(value(change.target, column, columns)) → \(value(change.source, column, columns))"
                }.joined(separator: "; "))
            }
            lines += data.missing.prefix(limit).map { line("missing row", key($0), rest($0, result.source.name)) }
            lines += data.extra.prefix(limit).map { line("extra row", key($0), rest($0, result.target.name)) }
            lines += changes
        }
        return lines
    }

    static func value(_ row: ReconRow, _ column: Int, _ columns: [ReconColumn]) -> String {
        row.text(column, kind: columns[column].kind).map { "'\($0)'" } ?? "NULL"
    }

    private static func header(_ result: ReconResult) -> [String] {
        let ignored = result.options.ignore.names
        func side(_ end: ReconEnd) -> String {
            end.name + (end.database.isEmpty ? "" : " · \(end.database)") + " (\(end.version))"
        }
        return ["\(side(result.source)) → \(side(result.target))",
                "Compared \(result.options.mode == .both ? "structure and data" : result.options.mode.rawValue) on "
                    + ISO8601DateFormatter().string(from: Date()) + String(format: " in %.1f s; ", result.duration)
                    + "\(result.rowsChecked) rows checked, \(result.rowsFetched) fetched",
                ignored.isEmpty ? "Nothing ignored" : "Ignoring " + ignored.joined(separator: ", ")]
    }

    private static func csv(_ result: ReconResult) -> String {
        func field(_ text: String) -> String {
            // A leading =, +, - or @ would make a spreadsheet run the cell as a formula.
            var text = text
            if let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { text = "'" + text }
            return text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        var rows = ["kind,object,status,difference,item,detail"]
        for object in result.objects where object.differs {
            rows += lines(object, result).map { line in
                [line.kind, line.object, line.status, line.difference, line.item, line.detail].map(field).joined(separator: ",")
            }
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// A line's item, with the object it belongs to where that isn't the section's own (a pair of databases).
    private static func item(_ line: Line, of object: ReconObject) -> String {
        line.object == object.name ? line.item : "\(line.object): \(line.item)"
    }

    private static func markdown(_ result: ReconResult) -> String {
        func cell(_ text: String) -> String {
            String(text.prefix(200)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
                .components(separatedBy: .newlines).joined(separator: " ")
        }
        var text = ["# Compare report", ""] + header(result).map { $0 + "  " } + ["", "| | |", "|---:|---|"]
        text += summary(result).map { "| \($0.value) | \(cell($0.label)) |" }
        for object in result.objects where object.differs {
            text += ["", "## \(object.kind.rawValue.capitalized) \(cell(object.name)): \(status(object, result))", "",
                     "| Difference | Item | Detail |", "|---|---|---|"]
            text += lines(object, result, limit: rowsShown).map { "| \($0.difference) | \(cell(item($0, of: object))) | \(cell($0.detail)) |" }
        }
        return text.joined(separator: "\n") + "\n"
    }

    private static func html(_ result: ReconResult) -> String {
        func escape(_ text: String) -> String {
            String(text.prefix(500)).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var body = header(result).map { "<p>\(escape($0))</p>" }
        body.append("<table class=summary>" + summary(result).map { "<tr><td>\($0.value)</td><td>\(escape($0.label))</td></tr>" }
            .joined() + "</table>")
        for object in result.objects where object.differs {
            body.append("<h2>\(escape(object.kind.rawValue.capitalized)) \(escape(object.name)) "
                        + "<small>\(escape(status(object, result)))</small></h2>")
            body.append("<table><tr><th>Difference</th><th>Item</th><th>Detail</th></tr>" + lines(object, result, limit: rowsShown)
                .map { "<tr><td>\(escape($0.difference))</td><td>\(escape(item($0, of: object)))</td><td>\(escape($0.detail))</td></tr>" }
                .joined() + "</table>")
        }
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><title>Compare report</title><style>
            body { font: 14px -apple-system, system-ui, sans-serif; margin: 32px; color: #1d1d1f; }
            table { border-collapse: collapse; margin: 8px 0 24px; } td, th { border: 1px solid #d2d2d7; padding: 4px 8px;
            text-align: left; vertical-align: top; } .summary td:first-child { text-align: right; font-weight: 600; }
            small { color: #6e6e73; font-weight: normal; }
            </style></head><body><h1>Compare report</h1>
            \(body.joined(separator: "\n"))
            </body></html>

            """
    }
}

/// Two texts side by side, line by line: equal lines on both sides, a line only one side has against a gap (nil), as
/// the compare window shows two CREATE statements.
public enum ReconLines {
    public static func aligned(_ left: String, _ right: String) -> [(left: String?, right: String?)] {
        let a = left.components(separatedBy: "\n"), b = right.components(separatedBy: "\n")
        // The longest common subsequence of lines (definitions are at most a few thousand lines).
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var rows: [(left: String?, right: String?)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                rows.append((a[i], b[j]))
                i += 1
                j += 1
            } else if j == b.count || i < a.count && lengths[i + 1][j] >= lengths[i][j + 1] {
                rows.append((a[i], nil))
                i += 1
            } else {
                rows.append((nil, b[j]))
                j += 1
            }
        }
        return rows
    }
}
