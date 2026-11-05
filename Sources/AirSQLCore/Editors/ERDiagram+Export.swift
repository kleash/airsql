import Foundation

// The diagram as text other tools draw: PlantUML, Graphviz DOT, GraphML and draw.io. `positions`: where its boxes are, so
// the tools that keep coordinates show the diagram as it was left.
extension ERDiagram {
    private var tables: [SchemaTable] { columns.flatMap { $0 } }

    /// A column's line: its key mark, name and type.
    private func line(_ column: SchemaColumn, in table: SchemaTable) -> String {
        let primary = table.primaryKey?.parts.contains { $0.column == column.name } ?? false
        let foreign = table.foreignKeys.contains { $0.columns.contains(column.name) }
        return (primary ? "PK " : foreign ? "FK " : "") + column.name + " : " + column.dataType
    }

    public func plantUML() -> String {
        let quoted = { (name: String) in "\"" + name.replacingOccurrences(of: "\"", with: "'") + "\"" }
        var lines = ["@startuml", "hide circle", "skinparam linetype ortho", ""]
        for table in tables {
            lines.append("entity " + quoted(table.name) + " as " + Self.word(table.name) + " {")
            lines += table.columns.map { "  " + line($0, in: table).replacingOccurrences(of: "\n", with: " ") }
            lines += ["}", ""]
        }
        for link in links {
            lines.append(Self.word(link.parent) + (link.optional ? " |o" : " ||") + "--" + (link.unique ? "o| " : "o{ ")
                         + Self.word(link.child) + " : " + quoted(link.name))
        }
        return (lines + ["@enduml"]).joined(separator: "\n") + "\n"
    }

    public func dot() -> String {
        let quoted = { (text: String) in
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        // A record label's own punctuation is escaped, then the whole is a quoted string.
        let record = { (text: String) in
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
                .replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "<", with: "\\<")
                .replacingOccurrences(of: ">", with: "\\>")
        }
        var lines = ["digraph schema {", "  rankdir=LR;", "  node [shape=record];"]
        for table in tables {
            let rows = table.columns.map { record(line($0, in: table)) + "\\l" }.joined()
            lines.append("  " + quoted(table.name) + " [label=\"{" + record(table.name) + "|" + rows + "}\"];")
        }
        lines += links.map { "  " + quoted($0.child) + " -> " + quoted($0.parent) + " [label=" + quoted($0.name) + "];" }
        return (lines + ["}"]).joined(separator: "\n") + "\n"
    }

    public func graphML(positions: [String: ERLayout.Point] = [:]) -> String {
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                     "<graphml xmlns=\"http://graphml.graphdrawing.org/xmlns\">",
                     "  <key id=\"label\" for=\"all\" attr.name=\"label\" attr.type=\"string\"/>",
                     "  <key id=\"columns\" for=\"node\" attr.name=\"columns\" attr.type=\"string\"/>",
                     "  <key id=\"x\" for=\"node\" attr.name=\"x\" attr.type=\"double\"/>",
                     "  <key id=\"y\" for=\"node\" attr.name=\"y\" attr.type=\"double\"/>",
                     "  <graph id=\"schema\" edgedefault=\"directed\">"]
        for table in tables {
            let name = Self.xml(table.name)
            lines.append("    <node id=\"\(name)\">")
            lines.append("      <data key=\"label\">\(name)</data>")
            lines.append("      <data key=\"columns\">" + Self.xml(table.columns.map { line($0, in: table) }.joined(separator: "\n")) + "</data>")
            if let point = positions[table.name] {
                lines.append("      <data key=\"x\">\(point.x)</data>")
                lines.append("      <data key=\"y\">\(point.y)</data>")
            }
            lines.append("    </node>")
        }
        for link in links {
            lines.append("    <edge source=\"\(Self.xml(link.child))\" target=\"\(Self.xml(link.parent))\">"
                         + "<data key=\"label\">\(Self.xml(link.name))</data></edge>")
        }
        return (lines + ["  </graph>", "</graphml>"]).joined(separator: "\n") + "\n"
    }

    /// A draw.io file: a box per table with its columns, an arrow per foreign key.
    public func drawIO(positions: [String: ERLayout.Point] = [:]) -> String {
        var lines = ["<mxfile>", "  <diagram name=\"Schema\">", "    <mxGraphModel>", "      <root>",
                     "        <mxCell id=\"0\"/>", "        <mxCell id=\"1\" parent=\"0\"/>"]
        var ids: [String: String] = [:]
        for (index, table) in tables.enumerated() {
            let id = "t\(index)"
            ids[table.name] = id
            let point = positions[table.name] ?? ERLayout.Point(x: Double(index % 6) * 240, y: Double(index / 6) * 280)
            let text = "<b>" + Self.xml(table.name) + "</b><hr>" + table.columns.map { Self.xml(line($0, in: table)) }.joined(separator: "<br>")
            lines.append("        <mxCell id=\"\(id)\" value=\"\(Self.xml(text))\" "
                         + "style=\"rounded=1;html=1;whiteSpace=wrap;align=left;verticalAlign=top;\" vertex=\"1\" parent=\"1\">")
            lines.append("          <mxGeometry x=\"\(point.x)\" y=\"\(point.y)\" width=\"200\" "
                         + "height=\"\(40 + 18 * table.columns.count)\" as=\"geometry\"/>")
            lines.append("        </mxCell>")
        }
        for (index, link) in links.enumerated() {
            guard let source = ids[link.child], let target = ids[link.parent] else { continue }
            lines.append("        <mxCell id=\"k\(index)\" value=\"\(Self.xml(link.name))\" style=\"endArrow=block;html=1;\" edge=\"1\" "
                         + "parent=\"1\" source=\"\(source)\" target=\"\(target)\"><mxGeometry relative=\"1\" as=\"geometry\"/></mxCell>")
        }
        return (lines + ["      </root>", "    </mxGraphModel>", "  </diagram>", "</mxfile>"]).joined(separator: "\n") + "\n"
    }

    /// Text in an XML attribute or element. Characters XML 1.0 can't hold at all become spaces.
    static func xml(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n": result += "&#10;"
            default: result.unicodeScalars.append(scalar.value < 0x20 && scalar != "\t" ? " " : scalar)
            }
        }
        return result
    }
}
