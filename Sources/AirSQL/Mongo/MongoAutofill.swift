import AirSQLCore
import AppKit

/// What autofill (`MongoCompletion`) is given for a collection: only what is in memory now, so typing never waits.
extension OpenMongoConnection {
    /// The suggestions at `caret`: from the cached sample, else from `loaded` (the paths of the documents a tab shows).
    func autofill(_ root: MongoCaret.Root, _ text: String, _ caret: Int, database: String, collection: String, path: String? = nil,
                  loaded: [String] = []) -> (Range<Int>, [CompletionItem]) {
        var sample = connection.samples.cached(database: database, collection: collection)
        if sample == nil, !loaded.isEmpty {
            sample = MongoSample(schema: MongoSchema(sample: []))
            sample?.loadedPaths = loaded
        }
        let samples = connection.samples
        let found = MongoCompletion.items(root: root, text: text, caret: caret, sample: sample,
                                          indexes: indexes[database + "." + collection] ?? [],
                                          collections: collections[database]?.map(\.name) ?? [], serverVersion: server.version,
                                          path: path, foreign: { samples.cached(database: database, collection: $0) })
        return (found.range, found.items)
    }

    /// Reads the collection's sample for autofill, off the main thread, unless it is cached or being read.
    func readSample(database: String, collection: String) {
        let samples = connection.samples
        guard samples.cached(database: database, collection: collection) == nil else { return }
        Task.detached { _ = try? await samples.sample(database: database, collection: collection) }
    }
}

/// Autofill in a plain text view: a query bar field's editor or the document editor's text, with the console's list
/// (`CompletionPopup`). It opens on Esc, and as `$`, `.`, `"` or a word's second letter is typed; while it is open ↑ and ↓
/// choose, Return inserts, Tab replaces the rest of the word and Esc closes. The pipeline editor has the console's own.
@MainActor
final class MongoAutofill {
    typealias Complete = (_ text: String, _ caret: Int) -> (Range<Int>, [CompletionItem])
    private var popup: CompletionPopup?
    private weak var popupEditor: NSTextView?
    /// An item being inserted: its edit doesn't open the list again.
    private var accepting = false

    var isShown: Bool { popup?.isShown == true }
    var items: [CompletionItem] { popup?.items ?? [] }

    /// After an edit in `textView`.
    func textChanged(_ textView: NSTextView, _ complete: Complete) {
        guard !accepting else { return }
        let caret = textView.selectedRange(), text = textView.string as NSString
        guard caret.length == 0, caret.location > 0 else { return close() }
        var word = 0
        while word < caret.location, SQLLexer.isNameChar(text.character(at: caret.location - 1 - word)) { word += 1 }
        let opener = [0x24, 0x2E, 0x22].contains(text.character(at: caret.location - 1))  // $ . "
        if opener || word >= 2 || (isShown && word >= 1) { show(textView, complete) } else { close() }
    }

    /// A command from `textView`'s keys; true when the list took it.
    func command(_ selector: Selector, in textView: NSTextView, _ complete: Complete) -> Bool {
        if let popup, popup.isShown {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): popup.move(-1)
            case #selector(NSResponder.moveDown(_:)): popup.move(1)
            case #selector(NSResponder.insertNewline(_:)): accept(popup, replacingWord: false)
            case #selector(NSResponder.insertTab(_:)): accept(popup, replacingWord: true)
            case #selector(NSResponder.cancelOperation(_:)): popup.close()
            default:
                popup.close()
                return false
            }
            return true
        }
        guard selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.complete(_:)) else { return false }
        show(textView, complete)
        return isShown
    }

    func close() { popup?.close() }

    private func show(_ textView: NSTextView, _ complete: Complete) {
        let (range, items) = complete(textView.string, textView.selectedRange().location)
        let typed = (textView.string as NSString).substring(with: NSRange(range))
        guard !(items.count == 1 && items[0].text == typed) else { return close() }
        if popup == nil || popupEditor !== textView {
            popup?.close()
            popup = CompletionPopup(editor: textView, id: "mongo.completion")
            popupEditor = textView
            popup?.documentation = { $0.detail }
        }
        popup?.show(items, replacing: range)
    }

    private func accept(_ popup: CompletionPopup, replacingWord: Bool) {
        accepting = true
        popup.accept(replacingWord: replacingWord)
        accepting = false
    }
}
