import AirSQLCore
import AppKit

/// Settings ▸ Liquibase (lane L8b): who changesets are by, their ids, the files a changelog is written in, DEFINER and
/// how procedures, functions, triggers and events are kept whole.
final class LiquibasePane: SettingsPaneController {
    override var helpPage: HelpPage { .liquibase }

    override func build() {
        form.row("Author", [text(\.liquibase.author, id: "settings.liquibaseAuthor", tip: "Type who the changesets are by, as Liquibase records it",
                                 placeholder: "Your Mac account's name", width: 200)])
        form.row("Ids", [text(\.liquibase.ids, id: "settings.liquibaseIds",
                              tip: "Type how changeset ids are made: {date}, {time}, {n} (001, 002…) and {object}",
                              placeholder: "{date}-{n}-{object}", width: 200)],
                 caption: "{date} 20261102, {time} 141500, {n} counts on from the changesets the changelog has, {object} is the "
                    + "table, view or routine.")
        form.row("Changelog files", [choice(\.liquibase.layout, id: "settings.liquibaseLayout",
                                            tip: "Write a changelog as one file, or as a folder with a file per changeset", [
                                                ("One file", LiquibaseSettings.Layout.oneFile),
                                                ("A folder: a file per changeset", .folder),
                                            ])],
                 caption: "A folder also gets \(Liquibase.masterName), which includes the files in order: point Liquibase at it.")
        form.row("Routines", [choice(\.liquibase.delimiter, id: "settings.liquibaseDelimiter",
                                     tip: "Choose how procedures, functions, triggers and events stay whole: their bodies hold semicolons", [
                                         ("The changeset's only statement (splitStatements:false)", LiquibaseSettings.Delimiter.splitStatements),
                                         ("Each statement ended by // (endDelimiter://)", .slashes),
                                     ])],
                 caption: "A change with several statements and a routine among them always ends each with //.")
        form.row("", [toggle("Leave DEFINER out of views, routines, triggers and events", id: "settings.liquibaseDefiner",
                             tip: "Let them run as whoever runs the changelog, not as an account the other server may not have",
                             \.liquibase.stripDefiner)])
        form.row("", [toggle("Add --rollback where it can be written", id: "settings.liquibaseRollback",
                             tip: "Write the DROP that undoes each CREATE, and what undoes added columns, keys and foreign keys",
                             \.liquibase.rollback)])
    }
}
