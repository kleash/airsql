import AirSQLCore
import AppKit
import Combine

/// Settings ▸ Format: the rules of Format SQL, a choice of named sets of them, and what they do to a sample.
final class FormatPane: SettingsPaneController {
    static let sample = """
        with recent as (select customer_id, max(created) last_seen from orders group by customer_id)
        select c.id, c.name, case when r.last_seen is null then 'new' else 'known' end as kind, count(*) as total
        from customers c left join recent r on r.customer_id = c.id join orders o on o.customer_id = c.id and o.total>0
        where c.status in ('active', 'new') and c.id not in (select id from blocked) group by c.id order by total desc limit 10;
        insert into log (at, message) values (now(), 'a'), (now(), 'b');
        create table t (id int primary key auto_increment, long_name varchar(20) not null, key k (long_name)) engine=InnoDB;
        """

    private let preview = NSTextView()
    /// Puts each control back on the saved style, after a preset.
    private var refreshes: [() -> Void] = []

    private func rule<Value: Equatable>(_ path: WritableKeyPath<SQLFormatStyle, Value>, id: String, tip: String,
                                        _ choices: [(title: String, value: Value)]) -> NSPopUpButton {
        let full = (\AppSettings.formatStyle).appending(path: path)
        let control = choice(full, id: "settings.format.\(id)", tip: tip, choices)
        refreshes.append { [weak self, weak control] in
            guard let self else { return }
            control?.selectItem(at: choices.firstIndex { $0.value == self.model.data.settings[keyPath: full] } ?? 0)
        }
        return control
    }

    private func switchRule(_ title: String, _ path: WritableKeyPath<SQLFormatStyle, Bool>, id: String, tip: String) -> NSButton {
        let full = (\AppSettings.formatStyle).appending(path: path)
        let control = toggle(title, id: "settings.format.\(id)", tip: tip, full)
        refreshes.append { [weak self, weak control] in
            guard let self else { return }
            control?.state = self.model.data.settings[keyPath: full] ? .on : .off
        }
        return control
    }

    private func wordCase(_ path: WritableKeyPath<SQLFormatStyle, SQLWordCase>, id: String, tip: String) -> NSPopUpButton {
        rule(path, id: id, tip: tip, [("As written", .keep), ("UPPER", .upper), ("lower", .lower)])
    }

    override func build() {
        let presets = popup(["Choose…"] + SQLFormatStyle.presets.map(\.name), selected: 0, id: "settings.format.preset",
                            tip: "Set all the rules below to a named set", target: self, action: #selector(presetChosen(_:)))
        form.row("Preset", [presets])
        form.row("Keywords", [wordCase(\.keywords, id: "keywords", tip: "Choose how reserved words are written, by Format SQL and completion"),
                              label("Types:"), wordCase(\.types, id: "types", tip: "Choose how column types are written"),
                              label("Functions:"), wordCase(\.functions, id: "functions", tip: "Choose how built-in functions are written")])
        form.row("Names", [wordCase(\.identifiers, id: "identifiers", tip: "Choose how tables and columns without quotes are written"),
                           label("Aliases:"), wordCase(\.aliases, id: "aliases", tip: "Choose how aliases are written, everywhere they're used")],
                 caption: "Leave names as written unless your server ignores their case: on Linux, table names usually have one.")
        form.row("Indent", [rule(\.indent, id: "indent", tip: "Choose how far subqueries and blocks move in", [2, 3, 4, 8].map { ("\($0) spaces", $0) })])
        form.row("Lists", [rule(\.lists, id: "lists", tip: "Choose when SELECT, SET, GROUP BY and ORDER BY put each item on a line",
                                [("On one line", .oneLine), ("A line each when long", .whenLong), ("A line each", .always)]),
                           switchRule("Comma first", \.commaFirst, id: "commaFirst", tip: "Start a list's lines with the comma instead of ending them with it")])
        form.row("Conditions", [switchRule("AND and OR on lines", \.conditionsOnLines, id: "conditionsOnLines", tip: "Put each condition of WHERE, HAVING and ON on a line"),
                                switchRule("At the start", \.operatorFirst, id: "operatorFirst", tip: "Start the line with AND or OR instead of ending the one before")])
        form.row("Joins", [switchRule("Indented", \.joinsIndented, id: "joinsIndented", tip: "Move JOIN lines in under FROM"),
                           switchRule("ON on its own line", \.joinOnOwnLine, id: "joinOnOwnLine", tip: "Put a join's ON on the line below it")])
        form.row("Subqueries", [rule(\.brackets, id: "brackets", tip: "Choose where a subquery's brackets go",
                                     [("Bracket ends the line", .endOfLine), ("Bracket on its own line", .ownLine), ("Bracket indented", .indented)]),
                                switchRule("Right-align clauses", \.river, id: "river", tip: "Line up the clause words on their right, so the text runs down one column")])
        form.row("Layout", [switchRule("CASE on lines", \.caseOnLines, id: "caseOnLines", tip: "Put each WHEN and ELSE of a CASE on a line"),
                            switchRule("Align columns", \.alignColumns, id: "alignColumns", tip: "Line up the types of CREATE TABLE's columns"),
                            switchRule("Rows on lines", \.rowsOnLines, id: "rowsOnLines", tip: "Put each row of VALUES on a line")])
        form.row("Spaces", [switchRule("Around operators", \.spaceAroundOperators, id: "spaceAroundOperators", tip: "Put a space on both sides of = + - and their like"),
                            switchRule("After commas", \.spaceAfterComma, id: "spaceAfterComma", tip: "Put a space after each comma"),
                            switchRule("Inside brackets", \.spaceInsideBrackets, id: "spaceInsideBrackets", tip: "Put a space inside the brackets of a call or a list")])
        preview.isEditable = false
        preview.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        preview.drawsBackground = false
        preview.toolTip = "Shows what Format SQL does to a sample with these rules"
        preview.setAccessibilityIdentifier("settings.format.preview")
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = preview
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.heightAnchor.constraint(equalToConstant: 170), scroll.widthAnchor.constraint(equalToConstant: 430)])
        form.row("Preview", [scroll])
        observers.append(model.$data.map(\.settings.formatStyle).removeDuplicates().sink { [weak self] style in self?.showPreview(style) })
    }

    private var observers: [AnyCancellable] = []

    private func showPreview(_ style: SQLFormatStyle) { preview.string = SQLFormatter.format(Self.sample, style: style) ?? Self.sample }

    @objc private func presetChosen(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0 else { return }
        model.data.settings.formatStyle = SQLFormatStyle.presets[sender.indexOfSelectedItem - 1].style
        refreshes.forEach { $0() }
        sender.selectItem(at: 0)
    }
}
