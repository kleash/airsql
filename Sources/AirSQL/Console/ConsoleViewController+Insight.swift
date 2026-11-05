import AirSQLCore
import AppKit

/// Gives the SQL editor's Code commands what only the console knows.
extension ConsoleViewController {
    func wireInsight() {
        editor.insightHooks = InsightHooks(
            isReadOnly: { [weak self] in self?.connection?.readOnly == true },
            disabledInspections: { [weak self] in Set(self?.model.data.settings.disabledInspections ?? []) },
            refreshSchema: { [weak self] in self?.refresh(nil) },
            previewRows: { [weak self] sql in self?.previewRows(sql) },
            openObject: { [weak self] symbol in self?.open(symbol) })
    }

    /// Runs a preview's SELECT as a result of this tab: nothing is written, whatever the statement it came from.
    private func previewRows(_ sql: String) {
        guard ReadOnlyClassifier.classify(sql, noBackslashEscapes: editor.noBackslashEscapes) == .readOnly
                || !StatementCheck.writes(sql, noBackslashEscapes: editor.noBackslashEscapes) else {
            note(.warning, "This statement can't be previewed: its conditions call something that may change data.")
            return
        }
        start(ConsoleRun(kind: .run, statements: [SQLStatement(sql: sql)], text: text))
    }

    /// Goes to a table's editor, or a routine's.
    private func open(_ symbol: SQLSymbol) {
        guard let main = mainWindow, let context = Editors.context(connection, in: model), let database = symbol.database else {
            note(.info, "Connect first to open “\(symbol.name)”.")
            return
        }
        if symbol.kind == .routine {
            let function = Self.schemaCache(connectionID!)?.snapshot.database(database)?.routines.first { $0.name == symbol.name }?.kind == .function
            main.openObjectEditor(function ? .function : .procedure, name: symbol.name, database: database, context: context)
        } else {
            main.openTableEditor(symbol.table ?? symbol.name, database: database, context: context)
        }
    }
}
