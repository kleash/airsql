import Foundation

/// A saved ER diagram of a database: which tables, where their boxes are, and how they show. Kept on this Mac
/// (`TableViewSettings.diagrams`), like virtual keys.
public struct ERLayout: Codable, Equatable {
    public enum Arrangement: String, Codable, CaseIterable {
        case leftToRight, topToBottom, grid
    }

    public enum Detail: String, Codable, CaseIterable {
        case allColumns, keysOnly, namesOnly
    }

    public struct Point: Codable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// What the first diagram of a database is called.
    public static let wholeDatabase = "Whole database"

    public var name: String
    /// The tables drawn; nil: every table of the database, as they come and go.
    public var tables: [String]?
    /// Where boxes were left, top left corner by table. A table without one is placed by `arrangement`.
    public var positions: [String: Point] = [:]
    public var arrangement = Arrangement.leftToRight
    public var detail = Detail.allColumns
    public var showsComments = false
    public var showsVirtualKeys = true

    public init(name: String, tables: [String]? = nil) {
        self.name = name
        self.tables = tables
    }

    /// `diagrams` with the whole database first, as saved or new.
    public static func list(_ diagrams: [ERLayout]) -> [ERLayout] {
        diagrams.contains { $0.tables == nil } ? diagrams : [ERLayout(name: wholeDatabase)] + diagrams
    }

    /// "Diagram 3": the first of that form not in `diagrams`.
    public static func newName(in diagrams: [ERLayout]) -> String {
        let taken = Set(diagrams.map(\.name))
        return (1...).lazy.map { "Diagram \($0)" }.first { !taken.contains($0) }!
    }
}
