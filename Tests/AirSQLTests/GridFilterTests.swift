import Foundation
import Testing
@testable import AirSQLCore

/// Quick filters, the WHERE bar, Search All Columns and sorting (grid-spec §4): the SQL for the server, and the same
/// decisions on loaded rows.
struct GridFilterTests {
    let name = GridColumn(name: "name", type: "varchar")
    let price = GridColumn(name: "price", type: "decimal", kind: .number)

    @Test func quickFiltersShowTheirSQL() {
        #expect(GridCondition(name, .equals, ["Ann"]).sql() == "`name` = 'Ann'")
        #expect(GridCondition(name, .equals, [nil]).sql() == "`name` IS NULL")
        #expect(GridCondition(name, .notEquals, ["Ann"]).sql() == "`name` <> 'Ann'")
        #expect(GridCondition(name, .notEquals, [nil]).sql() == "`name` IS NOT NULL")
        #expect(GridCondition(price, .less, ["10"]).sql() == "`price` < 10")
        #expect(GridCondition(price, .greater, ["1e3"]).sql() == "`price` > 1e3")
        #expect(GridCondition(name, .startsWith, ["An"]).sql() == "`name` LIKE 'An%'")
        #expect(GridCondition(name, .endsWith, ["nn"]).sql() == "`name` LIKE '%nn'")
        #expect(GridCondition(name, .contains, ["n"]).sql() == "`name` LIKE '%n%'")
        #expect(GridCondition(name, .contains, ["50%_off!"]).sql() == "`name` LIKE '%50!%!_off!!%' ESCAPE '!'")
        #expect(GridCondition(price, .isIn, ["1", "2"]).sql() == "`price` IN (1, 2)")
        #expect(GridCondition(price, .isIn, ["1", nil]).sql() == "(`price` IN (1) OR `price` IS NULL)")
        #expect(GridCondition(price, .notIn, ["1", nil]).sql() == "(`price` NOT IN (1) AND `price` IS NOT NULL)")
        #expect(GridCondition(price, .isIn, [nil]).sql() == "`price` IS NULL")
        #expect(GridCondition(name, .isNull).sql() == "`name` IS NULL")
        #expect(GridCondition(name, .isNotNull).sql() == "`name` IS NOT NULL")
        // A "number" that isn't one is quoted, never pasted in.
        #expect(GridCondition(price, .equals, ["1 OR 1=1"]).sql() == "`price` = '1 OR 1=1'")
    }

    @Test(arguments: [false, true])
    func hostileValuesStayQuoted(noBackslashEscapes: Bool) {
        for value in Hostile.values {
            let column = GridColumn(name: value)
            let quoted = SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes)
            #expect(GridCondition(column, .equals, [value]).sql(noBackslashEscapes: noBackslashEscapes)
                    == SQLQuote.identifier(value) + " = " + quoted)
            let like = GridCondition(column, .contains, [value]).sql(noBackslashEscapes: noBackslashEscapes)
            #expect(like.hasPrefix(SQLQuote.identifier(value) + " LIKE '%"), "\(value.debugDescription)")
        }
    }

    @Test func loadedRowsMatchAsTheServerWould() {
        #expect(GridCondition(name, .equals, ["Ann"]).matches("Ann"))
        #expect(!GridCondition(name, .equals, ["Ann"]).matches(nil))
        #expect(GridCondition(name, .equals, [nil]).matches(nil))
        #expect(!GridCondition(name, .notEquals, ["Ann"]).matches(nil))
        #expect(GridCondition(name, .notEquals, ["Ann"]).matches("Bob"))
        #expect(GridCondition(price, .less, ["10"]).matches("9.5"))
        #expect(!GridCondition(price, .less, ["10"]).matches("10.0"))
        #expect(GridCondition(price, .greater, ["9"]).matches("10"))  // by value, not as text
        #expect(GridCondition(name, .startsWith, ["an"]).matches("Ann"))
        #expect(GridCondition(name, .endsWith, ["NN"]).matches("Ann"))
        #expect(GridCondition(name, .contains, ["é"]).matches("CAFE"))
        #expect(!GridCondition(name, .contains, ["x"]).matches(nil))
        #expect(GridCondition(name, .isIn, ["Ann", nil]).matches(nil))
        #expect(!GridCondition(name, .notIn, ["Ann"]).matches(nil))
        #expect(GridCondition(name, .isNull).matches(nil) && !GridCondition(name, .isNotNull).matches(nil))
    }

    @Test func whereBarAndAddedConditions() {
        #expect(GridFilter.condition("  WHERE id > 3 \n") == "id > 3")
        #expect(GridFilter.condition("where\nid > 3") == "id > 3")
        #expect(GridFilter.condition("whereabouts = 1") == "whereabouts = 1")
        #expect(GridFilter.adding("`b` = 2", to: "") == "`b` = 2")
        #expect(GridFilter.adding("`b` = 2", to: "WHERE a = 1 OR c = 3") == "(a = 1 OR c = 3) AND `b` = 2")
    }

    @Test func searchAllColumnsCoversEveryKind() {
        let columns = [GridColumn(name: "id", kind: .number), name, GridColumn(name: "born", kind: .date),
                       GridColumn(name: "doc", kind: .json), GridColumn(name: "photo", kind: .binary)]
        #expect(GridFilter.search("an", in: columns) == "CAST(`id` AS CHAR) LIKE '%an%' OR `name` LIKE '%an%' OR "
                + "CAST(`born` AS CHAR) LIKE '%an%' OR `doc` LIKE '%an%'")
        #expect(GridFilter.search("0xff", in: columns)?.hasSuffix(" OR `photo` = X'FF'") == true)
        #expect(GridFilter.search("1%", in: [name]) == "`name` LIKE '%1!%%' ESCAPE '!'")
        #expect(GridFilter.search("", in: columns) == nil)
        #expect(GridFilter.search("x", in: [GridColumn(name: "photo", kind: .binary)]) == nil)
        #expect(GridFilter.matches("ANN", ["1", nil, "Joanna"]))
        #expect(!GridFilter.matches("x", ["1", nil]))
    }

    @Test func sortsOnTheServerAndHere() {
        #expect(GridSorting.orderBy([.init(column: "name", ascending: true), .init(column: "p`rice", ascending: false)])
                == "`name` ASC, `p``rice` DESC")
        #expect(GridSorting.orderBy([]) == "")
        let values: [[String?]] = [["b", "10"], [nil, "9"], ["a", "10"], ["B", nil], ["a", "2"]]
        let columns = [name, price]
        let byPrice = GridSorting.sorted(Array(values.indices), by: [(1, true)], columns: columns) { values[$0][$1] }
        #expect(byPrice == [3, 4, 1, 0, 2])  // NULL first, then by value; equal rows keep their order
        let byNameThenPrice = GridSorting.sorted(Array(values.indices), by: [(0, true), (1, false)], columns: columns) {
            values[$0][$1]
        }
        #expect(byNameThenPrice == [1, 2, 4, 0, 3])  // without case: a, a, b, B
        let descending = GridSorting.sorted(Array(values.indices), by: [(1, false)], columns: columns) { values[$0][$1] }
        #expect(descending == [0, 2, 1, 4, 3])
    }

    @Test func findAndReplaceWithCaseRegexAndWholeWords() {
        let plain = GridFind("an")
        #expect(plain.matches("Joanna", plain.expression) && plain.matches("ANN", plain.expression) && !plain.matches(nil, plain.expression))
        let cased = GridFind("an", matchCase: true)
        #expect(!cased.matches("ANN", cased.expression))
        let words = GridFind("an", wholeWords: true)
        #expect(!words.matches("Joanna", words.expression) && words.matches("an apple", words.expression))
        let regex = GridFind("(\\d+)-(\\d+)", regex: true)
        #expect(regex.replacing(in: "10-20 and 3-4", with: "$2-$1", regex.expression) == "20-10 and 4-3")
        // Without regex, special characters are plain text, in the pattern and the replacement.
        let dots = GridFind("a.b")
        #expect(!dots.matches("axb", dots.expression) && dots.replacing(in: "a.b A.B", with: "$0\\", dots.expression) == "$0\\ $0\\")
        #expect(GridFind("(", regex: true).expression == nil && GridFind("").expression == nil)
    }
}
