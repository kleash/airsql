import AppKit
import CMariaDB
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// A console tab driven through the harness (plan §2.6): New Query, typing with colours, the editor's commands, and
/// what Run says without a connection. The lab test runs statements, Manual mode and closing with a transaction open.
extension AppTests {
    @MainActor @Suite struct ConsoleAppTests {
        /// A window with the shop's connections and a new console on Production.
        static func console(_ given: AppModel? = nil, on connection: UUID = Fixtures.production.id) async throws
            -> (MainWindowController, AgentServer, ConsoleViewController) {
            let model = given ?? testModel(Fixtures.shop)
            // Shown as connected, so New Query doesn't start a connect: the fixtures lead nowhere.
            if model.states[connection] == nil { model.states[connection] = .connected(server: "MariaDB 11.8.3") }
            let (main, harness) = appWindow(model)
            main.sidebar.select([connection])
            let reply = await call(harness, "menu", ["path": "File > New Query"])
            #expect(reply.error == nil, "\(reply.error ?? "")")
            let console = try #require(main.selectedTab?.content as? ConsoleViewController)
            return (main, harness, console)
        }

        /// A closed session (Disconnect) takes its last USE with it: the console's database is the connection's again.
        @Test func aClosedSessionsDatabaseIsForgotten() async throws {
            let (_, _, console) = try await Self.console()
            let closed = DBConnection(options: ConnectOptions(host: "127.0.0.1", user: "app"), role: .main)
            ConsoleViewController.shared[console.sessionKey] = .init(database: "old", session: closed)
            defer { ConsoleViewController.shared[console.sessionKey] = nil }
            #expect(console.database == "shop")
        }

        /// The toolbar's buttons and Tx pop-up ask the console, as its menu items do: off, saying why, until it can act.
        @Test func theToolbarAsksTheConsole() async throws {
            let (main, _, console) = try await Self.console()
            let toolbar = try #require(main.window?.toolbar)
            func button(_ id: NSToolbarItem.Identifier) -> NSControl? {
                toolbar.items.first { $0.itemIdentifier == id }?.view as? NSControl
            }
            let tx = main.toolbarController.transactionPopup
            toolbar.validateVisibleItems()
            #expect(button(.run)?.isEnabled == false && button(.run)?.toolTip?.hasPrefix("Connect first: double-click") == true)
            let help = AXNode.flatten(try #require(main.window)).first { $0.id == "toolbar.run" }?.help
            #expect(help?.hasPrefix("Connect first: double-click") == true, "VoiceOver reads why too: \(help ?? "")")
            #expect(button(.commit)?.isEnabled == false && button(.commit)?.toolTip == "No transaction is open in this tab")
            #expect(button(.cancel)?.isEnabled == false && button(.cancel)?.toolTip == "Nothing is running in this tab")
            #expect(!tx.isEnabled && tx.toolTip?.hasPrefix("Connect first: double-click") == true)
            #expect(tx.itemTitles == ["Auto-commit", "Manual Commit", "", "Isolation Level", "Read Uncommitted", "Read Committed",
                                      "Repeatable Read", "Serializable"])
            // Connected, with a statement typed: Run can run and says what it does; there is still nothing to commit.
            let connection = Connection(options: ConnectOptions(host: "127.0.0.1", port: 1, user: "nobody"))
            ConsoleViewController.openConnection = { $0 == Fixtures.production.id ? connection : nil }
            defer { ConsoleViewController.openConnection = { _ in nil } }
            console.editor.setText("SELECT 1")
            toolbar.validateVisibleItems()
            #expect(button(.run)?.isEnabled == true && button(.run)?.toolTip == Commands.runStatement.tip + " (⌘↩)")
            #expect(button(.commit)?.isEnabled == false && tx.isEnabled && tx.title == "Auto-commit")
        }

        @Test func newQueryStartsConnectingADisconnectedConnection() async throws {
            let closed = SavedConnection(name: "Closed port", host: "127.0.0.1", port: 1, user: "nobody")
            let model = testModel([closed])
            let (main, harness) = appWindow(model)
            main.sidebar.select([closed.id])
            #expect(await call(harness, "menu", ["path": "File > New Query"]).error == nil)
            // Connecting, or already failed (nothing listens on port 1): either way New Query started it.
            #expect(model.states[closed.id] != nil && main.selectedTab?.connectionID == closed.id, "\(String(describing: model.states[closed.id]))")
            model.connector.cancel(closed.id)
            if let sheet = main.window?.attachedSheet { main.window?.endSheet(sheet) }
        }

        @Test func newQueryOpensAConsoleOnTheSelectedConnection() async throws {
            let (main, _, console) = try await Self.console()
            #expect(main.selectedTab?.title == "Query 1" && console.connectionID == Fixtures.production.id)
            #expect(main.window?.firstResponder === console.editor)
            #expect(!console.isEdited && console.canRename && console.fileURL == nil)
            main.openConsole(text: "", title: nil, connection: Fixtures.production.id)
            #expect(main.selectedTab?.title == "Query 2")
        }

        /// A new console gives its editor and its results about half the split each, at the window's usual and smallest
        /// size (the column that holds the find bar once held the results to their smallest).
        @Test func aNewConsoleSplitsItsEditorAndResultsAboutHalfEach() async throws {
            for size in [MainWindowController.defaultSize, MainWindowController.minimumSize] {
                let model = testModel(Fixtures.shop)
                model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8.3")
                let (main, harness) = appWindow(model, size: size)
                main.sidebar.select([Fixtures.production.id])
                #expect(await call(harness, "menu", ["path": "File > New Query"]).error == nil)
                let console = try #require(main.selectedTab?.content as? ConsoleViewController)
                main.window?.layoutIfNeeded()
                let split = console.split, results = split.arrangedSubviews[1].frame.height
                #expect(abs(results - split.bounds.height * 0.55) < 24, "\(size): results \(results) of \(split.bounds.height)")
            }
        }

        /// The bracket marks look at the text being edited, whose tokens are a moment old: deleting where an old token
        /// ended the text, or putting a shorter text in place, mustn't read past its end.
        @Test func editsThatShortenTheTextNextToABracketKeepTheEditor() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor)
            editor.setText("SELECT (1);")
            editor.setSelectedRange(NSRange(location: 11, length: 0))
            editor.deleteBackward(nil)
            editor.setSelectedRange(NSRange(location: 7, length: 3))
            editor.deleteBackward(nil)
            #expect(editor.string == "SELECT ")
            editor.setText("SELECT (1), (2), (3);")
            editor.setSelectedRange(NSRange(location: 21, length: 0))
            editor.insertText("SELECT 1", replacementRange: NSRange(location: 0, length: 21))
            #expect(editor.string == "SELECT 1")
        }

        /// Several values pasted inside an IN become a list that one Undo takes back; Paste Without Formatting and any
        /// other place keep the text as it was copied. Everything goes through the menu, as a person's paste does.
        @Test func pastingIntoAnInMakesAList() async throws {
            let (main, harness, console) = try await Self.console()
            let editor = try #require(console.editor)
            main.window?.makeFirstResponder(editor)
            let pasteboard = NSPasteboard.general
            let saved = pasteboard.string(forType: .string)
            defer {
                pasteboard.clearContents()
                if let saved { pasteboard.setString(saved, forType: .string) }
            }
            pasteboard.clearContents()
            pasteboard.setString("a\nO'Brien\n", forType: .string)
            let sql = "SELECT 1 FROM t WHERE x IN ()"
            func place(_ text: String, at caret: Int) {
                editor.setText(text)
                editor.setSelectedRange(NSRange(location: caret, length: 0))
            }
            place(sql, at: 28)
            editor.paste(nil)
            #expect(editor.string == "SELECT 1 FROM t WHERE x IN ('a', 'O\\'Brien')")
            #expect(editor.selectedRange() == NSRange(location: 43, length: 0))
            editor.undoManager?.undo()
            #expect(editor.string == sql, "one Undo takes it all back")
            place(sql, at: 28)
            editor.pasteAsPlainText(nil)
            #expect(editor.string == "SELECT 1 FROM t WHERE x IN (a\nO'Brien\n)")
            place("SELECT ", at: 7)
            editor.paste(nil)
            #expect(editor.string == "SELECT a\nO'Brien\n")
            #expect(Commands.pastePlain.shortcut == "⌥⇧⌘V")
            let menu = await call(harness, "menu", ["path": "Edit > Paste Without Formatting"])
            #expect(menu.error == nil, "\(menu.error ?? "")")
        }

        /// Edit ▸ Lines and the commands around it: what each does to the text, the cursor, and that Undo takes it back.
        @Test func lineCommands() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor)
            func on(_ text: String, _ selection: NSRange, _ command: (SQLEditorView) -> Void) -> (String, NSRange) {
                editor.setText(text)
                editor.setSelectedRange(selection)
                command(editor)
                let result = (editor.string, editor.selectedRange())
                if result.0 != text {
                    editor.undoManager?.undo()
                    #expect(editor.string == text, "Undo takes it back")
                }
                return result
            }
            func caret(_ place: Int, _ length: Int = 0) -> NSRange { NSRange(location: place, length: length) }
            let dup = { (e: SQLEditorView) in e.duplicateLine(nil) }
            #expect(on("a\nb", caret(1), dup) == ("a\na\nb", caret(3)))
            #expect(on("a\nb", caret(3), dup) == ("a\nb\nb", caret(5)), "the last line has no break")
            #expect(on("a\nb\nc", caret(0, 3), dup) == ("a\nb\na\nb\nc", caret(4, 3)))
            let del = { (e: SQLEditorView) in e.deleteLine(nil) }
            #expect(on("a\nb\nc", caret(2), del) == ("a\nc", caret(2)))
            #expect(on("a\nb", caret(3), del) == ("a", caret(1)))
            #expect(on("a", caret(0), del) == ("", caret(0)))
            let up = { (e: SQLEditorView) in e.moveLineUp(nil) }, down = { (e: SQLEditorView) in e.moveLineDown(nil) }
            #expect(on("a\nbb\nc", caret(3), up) == ("bb\na\nc", caret(1)))
            #expect(on("a\nbb", caret(3), up) == ("bb\na", caret(1)), "the last line takes a break")
            #expect(on("a\nbb\nc", caret(0), up) == ("a\nbb\nc", caret(0)), "nothing above")
            #expect(on("a\nbb\nc", caret(0), down) == ("bb\na\nc", caret(3)))
            #expect(on("a\nbb", caret(0), down) == ("bb\na", caret(3)))
            #expect(on("a\nbb", caret(3), down) == ("a\nbb", caret(3)), "nothing below")
            #expect(on("a\nb\nc", caret(0, 3), down) == ("c\na\nb", caret(2, 3)))
            let join = { (e: SQLEditorView) in e.joinLines(nil) }
            #expect(on("a\n  b\nc", caret(0), join).0 == "a b\nc")
            #expect(on("a\nb\nc", caret(0, 4), join).0 == "a b\nc")
            #expect(on("z\nb\na", caret(0, 5), { $0.sortLines(nil) }).0 == "a\nb\nz")
            #expect(on("1\n2\n3", caret(0, 5), { $0.reverseLines(nil) }).0 == "3\n2\n1")
            let toggle = { (e: SQLEditorView) in e.toggleCase(nil) }
            #expect(on("select x", caret(0, 6), toggle) == ("SELECT x", caret(0, 6)))
            #expect(on("SELECT x", caret(0, 6), toggle) == ("select x", caret(0, 6)))
            #expect(on("select x", caret(2), toggle).0 == "SELECT x", "the word at the cursor")
            let block = { (e: SQLEditorView) in e.toggleBlockComment(nil) }
            #expect(on("a b c", caret(2, 1), block).0 == "a /* b */ c")
            #expect(on("a /* b */ c", caret(5), block).0 == "a b c")
            #expect(on("  a b\nc", caret(3), block).0 == "  /* a b */\nc")
            #expect(on("SELECT (1", caret(9), { $0.completeStatement(nil) }) == ("SELECT (1);\n", caret(12)))
            // ⌘C with nothing selected takes the line, and has something to do.
            editor.setText("a\nb")
            editor.setSelectedRange(caret(0))
            let pasteboard = NSPasteboard.general, saved = pasteboard.string(forType: .string)
            defer {
                pasteboard.clearContents()
                if let saved { pasteboard.setString(saved, forType: .string) }
            }
            editor.copy(nil)
            #expect(pasteboard.string(forType: .string) == "a\n")
            #expect(editor.validateUserInterfaceItem(Commands.copy.item()))
        }

        /// Moving by statement and growing the selection by syntax; the band, shade and marks around the cursor.
        @Test func statementsAndWhatTheCursorMarks() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor)
            func caret(_ place: Int, _ length: Int = 0) -> NSRange { NSRange(location: place, length: length) }
            let script = "SELECT 1;\nSELECT 22;\nSELECT 3"
            editor.setText(script)
            editor.setSelectedRange(caret(3))
            editor.nextStatement(nil)
            #expect(editor.selectedRange() == caret(10))
            editor.nextStatement(nil)
            #expect(editor.selectedRange() == caret(21))
            editor.previousStatement(nil)
            #expect(editor.selectedRange() == caret(10))
            editor.setSelectedRange(caret(13))
            editor.previousStatement(nil)
            #expect(editor.selectedRange() == caret(10), "first to the start of its own")
            editor.selectStatement(nil)
            #expect(editor.selectedRange() == caret(10, 9))
            editor.setSelectedRange(caret(13))
            editor.moveStatementDown(nil)
            #expect(editor.string == "SELECT 1;\nSELECT 3;\nSELECT 22" && editor.selectedRange() == caret(23), "delimiters stay, the cursor goes along")
            editor.moveStatementUp(nil)
            #expect(editor.string == script && editor.selectedRange() == caret(13))
            editor.undoManager?.removeAllActions()

            editor.setSelectedRange(caret(1))
            editor.extendSelection(nil)
            #expect(editor.selectedRange() == caret(0, 6))
            editor.extendSelection(nil)
            editor.extendSelection(nil)
            #expect(editor.selectedRange().length > 6)
            editor.shrinkSelection(nil)
            editor.shrinkSelection(nil)
            #expect(editor.selectedRange() == caret(0, 6))
            editor.shrinkSelection(nil)
            #expect(editor.selectedRange() == caret(1))
            #expect(editor.validateUserInterfaceItem(Commands.extendSelection.item()))

            // Band and shade: the statement only when there's another.
            editor.setSelectedRange(caret(12))
            #expect(editor.shadedStatement == 10..<19 && editor.caretBand.height > 0)
            #expect(editor.positionLabel.stringValue == "Ln 2, Col 3")
            editor.setSelectedRange(caret(10, 6))
            #expect(editor.positionLabel.stringValue == "Ln 2, Col 1 · 6 selected" && editor.caretBand == .zero)
            editor.setText("SELECT 1")
            editor.setSelectedRange(caret(2))
            #expect(editor.shadedStatement == nil)

            // A name is marked wherever it appears, in any case or quotes; keywords, strings and numbers aren't.
            func marked(_ place: Int) -> Bool {
                editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: place, effectiveRange: nil) != nil
            }
            editor.setText("SELECT orders, `ORDERS`, 'orders', other FROM orders")
            editor.setSelectedRange(caret(7, 6))
            #expect(marked(7) && marked(15) && marked(46) && !marked(26) && !marked(35))
            editor.setSelectedRange(caret(2))
            #expect(!marked(7) && !marked(46))
        }

        /// Several carets: made each way, every edit and move at all of them, one Undo, and any other selection ends them.
        @Test func severalCarets() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor)
            func caret(_ place: Int, _ length: Int = 0) -> NSRange { NSRange(location: place, length: length) }
            func all() -> [NSRange] { ([editor.selectedRange()] + editor.extraCarets).sorted { $0.location < $1.location } }
            func type(_ text: String) { editor.insertText(text, replacementRange: editor.selectedRange()) }
            func start(_ text: String, _ selection: NSRange) {
                editor.setText(text)
                editor.setSelectedRange(selection)
            }

            start("ab\ncd\nef", caret(0, 8))
            editor.caretPerLine(nil)
            #expect(all() == [caret(2), caret(5), caret(8)])
            type("x")
            #expect(editor.string == "abx\ncdx\nefx" && all() == [caret(3), caret(7), caret(11)])
            #expect(console.text == editor.string, "the console hears of the change")
            editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            #expect(editor.string == "ab\ncd\nef")
            editor.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
            #expect(all() == [caret(0), caret(3), caret(6)], "moves go through the text view's own commands")
            editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
            #expect(all() == [caret(1), caret(4), caret(7)])
            editor.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
            editor.undoManager?.removeAllActions()
            type("(")
            #expect(editor.string == "ab()\ncd()\nef()", "brackets pair at each")
            editor.undoManager?.undo()
            #expect(editor.string == "ab\ncd\nef", "one Undo")
            #expect(editor.extraCarets.isEmpty, "and a selection made any other way ends them")

            start("ab\ncd\nef", caret(1))
            editor.addCaretBelow(nil)
            editor.addCaretBelow(nil)
            #expect(all() == [caret(1), caret(4), caret(7)])
            editor.addCaretBelow(nil)
            #expect(all().count == 3, "no line below")
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            #expect(all() == [caret(1)], "Escape keeps the main one")
            start("abc\nd\nabc", caret(9))
            editor.addCaretAbove(nil)
            #expect(all() == [caret(5), caret(9)], "the line's end when it's shorter")

            start("foo bar FOO foo", caret(1))
            editor.selectNextOccurrence(nil)
            #expect(all() == [caret(0, 3)], "first the word")
            editor.selectNextOccurrence(nil)
            #expect(all() == [caret(0, 3), caret(8, 3)], "whatever its case")
            editor.selectNextOccurrence(nil)
            editor.selectNextOccurrence(nil)
            #expect(all().count == 3, "no more")
            type("x")
            #expect(editor.string == "x bar x x", "typing the same length or not, each one goes")

            start("aaa", caret(0, 1))
            editor.selectAllOccurrences(nil)
            #expect(all() == [caret(0, 1), caret(1, 1), caret(2, 1)], "side by side they stay apart")

            // A block dragged out with ⌥ arrives as several selections.
            start("abcd\nefgh", caret(0))
            editor.setSelectedRanges([NSValue(range: caret(1, 2)), NSValue(range: caret(6, 2))], affinity: .downstream, stillSelecting: false)
            #expect(all() == [caret(1, 2), caret(6, 2)])
            type("z")
            #expect(editor.string == "azd\nezh")

            // Cut from each, paste back a line each; a clipboard that doesn't fit goes in at every caret.
            let pasteboard = NSPasteboard.general, saved = pasteboard.string(forType: .string)
            defer {
                pasteboard.clearContents()
                if let saved { pasteboard.setString(saved, forType: .string) }
            }
            start("one two\nthree two", caret(0, 3))
            editor.setCarets([caret(0, 3), caret(8, 5)])
            editor.cut(nil)
            #expect(pasteboard.string(forType: .string) == "one\nthree" && editor.string == " two\n two")
            editor.paste(nil)
            #expect(editor.string == "one two\nthree two" && all() == [caret(3), caret(13)])
            pasteboard.clearContents()
            pasteboard.setString("x", forType: .string)
            editor.paste(nil)
            #expect(editor.string == "onex two\nthreex two")

            // Column mode: ⇧↓ adds a caret instead of selecting.
            start("ab\ncd", caret(1))
            editor.toggleColumnSelection(nil)
            defer { editor.columnSelection = false }
            editor.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
            #expect(all() == [caret(1), caret(4)])
        }

        /// A fold hides lines without touching the text, follows edits around it and opens for the cursor or an edit in it.
        @Test func folding() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor)
            let layout = try #require(editor.layoutManager), container = try #require(editor.textContainer)
            func height() -> CGFloat {
                layout.ensureLayout(for: container)
                return layout.usedRect(for: container).height
            }
            func settled() async { await Task.yield() ; try? await Task.sleep(nanoseconds: 10_000_000) }
            let script = "SELECT 1,\n  2,\n  3;\nSELECT 4"
            editor.setText(script)
            let open = height()
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            editor.foldHere(nil)
            #expect(editor.folds == [9..<19] && height() < open)
            #expect(editor.string == script && console.text == script, "the text stays whole")
            editor.display()  // the ruler and "…" draw with lines hidden
            let ruler = try #require(editor.enclosingScrollView?.verticalRulerView)
            ruler.display()

            // An edit before it moves it; inside, opens it.
            editor.replace(NSRange(location: 0, length: 0), with: "-- a\n")
            #expect(editor.folds == [14..<24])
            editor.replace(NSRange(location: 16, length: 1), with: "x")
            await settled()
            #expect(editor.folds.isEmpty && height() > open - 1)

            editor.setText(script)
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            editor.foldHere(nil)
            editor.setSelectedRange(NSRange(location: 12, length: 0))
            #expect(editor.folds.isEmpty, "a cursor landing inside opens it")

            editor.foldAll(nil)
            #expect(editor.folds == [9..<19])
            editor.unfoldAll(nil)
            #expect(editor.folds.isEmpty)

            // The triangle's line: a click folds, another opens. A cursor in the fold comes out to its first line.
            editor.setSelectedRange(NSRange(location: 12, length: 0))
            editor.toggleFold(lineRange: NSRange(location: 0, length: 10))
            #expect(editor.folds == [9..<19] && editor.selectedRange().location == 9)
            editor.toggleFold(lineRange: NSRange(location: 0, length: 10))
            #expect(editor.folds.isEmpty)

            editor.setSelectedRange(NSRange(location: 3, length: 0))
            editor.foldHere(nil)
            editor.setText("x")
            #expect(editor.folds.isEmpty, "a new text has none")
        }

        /// Return after a bracket; a paste inside a string; Fold on a selection; Find's whole words and selection.
        @Test func smallEditorRows() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor)
            editor.setText("    f()")
            editor.setSelectedRange(NSRange(location: 6, length: 0))
            editor.insertNewline(nil)
            #expect(editor.string == "    f(\n        \n    )" && editor.selectedRange().location == 15)
            editor.setText("'('")
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            editor.insertNewline(nil)
            #expect(editor.string == "'(\n'", "not a bracket inside a string")

            editor.setText("SELECT a\nFROM b\nWHERE c")
            editor.setSelectedRange(NSRange(location: 8, length: 7))
            editor.foldHere(nil)
            #expect(editor.folds == [8..<15])

            let find = try #require(console.findBar)
            defer { find.close(nil) }
            editor.setText("id order_id ID id2 id")
            find.show(replace: true)
            find.search.stringValue = "id"
            func matched() -> [Int] { (find.matches() ?? []).map(\.location) }
            #expect(matched() == [0, 9, 12, 15, 19])
            find.wholeWords.performClick(nil)
            #expect(matched() == [0, 12, 19])
            editor.setSelectedRange(NSRange(location: 5, length: 10))
            find.inSelection.performClick(nil)
            #expect(matched() == [12], "the selection at the moment it was ticked")
            editor.setSelectedRange(NSRange(location: 12, length: 2))
            #expect(matched() == [12], "still there as matches get selected")
            find.replacement.stringValue = "x"
            find.perform(.replaceAll)
            #expect(editor.string == "id order_id x id2 id", "Replace All keeps to it")
            find.inSelection.performClick(nil)
            find.regex.performClick(nil)
            find.search.stringValue = "(i)d"
            find.replacement.stringValue = "$1D"
            find.perform(.replaceAll)
            #expect(editor.string == "iD order_id x id2 iD", "groups, match by match, whole words kept")
            find.regex.performClick(nil)
            find.wholeWords.performClick(nil)
        }

        /// Surround With takes the selection or word; Paste from History lists the editor's copies, newest first, without repeats.
        @Test func surroundAndPasteHistory() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor)
            func item(_ tag: Int) -> NSMenuItem {
                let item = Commands.surroundWith.item()
                item.tag = tag
                return item
            }
            editor.setText("SELECT a FROM t")
            editor.setSelectedRange(NSRange(location: 7, length: 1))
            editor.surroundWith(item(0))
            #expect(editor.string == "SELECT (a) FROM t" && editor.selectedRange() == NSRange(location: 7, length: 3))
            editor.setText("name")
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            editor.surroundWith(item(3))
            #expect(editor.string == "COALESCE(name, )", "the word at the cursor")
            editor.undoManager?.undo()
            #expect(editor.string == "name")

            let pasteboard = NSPasteboard.general, saved = pasteboard.string(forType: .string), kept = SQLEditorView.copied
            defer {
                SQLEditorView.copied = kept
                pasteboard.clearContents()
                if let saved { pasteboard.setString(saved, forType: .string) }
            }
            SQLEditorView.copied = []
            let empty = NSMenu()
            PasteHistoryMenu.shared.menuNeedsUpdate(empty)
            #expect(empty.items.map(\.title) == ["Copy Something in the Editor First"] && empty.items[0].action == nil)
            editor.setText("one two")
            for range in [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3), NSRange(location: 0, length: 3)] {
                editor.setSelectedRange(range)
                editor.copy(nil)
            }
            #expect(SQLEditorView.copied == ["one", "two"])
            let menu = NSMenu()
            PasteHistoryMenu.shared.menuNeedsUpdate(menu)
            editor.setSelectedRange(NSRange(location: 7, length: 0))
            editor.pasteFromHistory(menu.items[1])
            #expect(editor.string == "one twotwo")
        }

        /// Settings ▸ Editor reaches open editors: the font, keywords in it too; the indent Tab puts in.
        @Test func editorSettingsReachTheEditor() async throws {
            let model = testModel(Fixtures.shop)
            let (_, _, console) = try await Self.console(model)
            let editor = try #require(console.editor)
            #expect(editor.font?.isFixedPitch == true && editor.indentUnit == "    ")
            editor.setText("SELECT a")
            model.data.settings.editorFontFamily = "Menlo"
            model.data.settings.editorTabWidth = 2
            _ = await eventually(timeout: 5) { editor.font?.familyName == "Menlo" }
            #expect(editor.indentUnit == "  ")
            let keyword = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(keyword?.familyName == "Menlo", "keywords keep the family")
            let style = editor.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            #expect((style?.defaultTabInterval ?? 0) > 0)
            model.data.settings.editorUsesTabs = true
            _ = await eventually(timeout: 5) { editor.indentUnit == "\t" }
            editor.setText("a\nb")
            editor.setSelectedRange(NSRange(location: 0, length: 3))
            editor.indentLines(nil)
            #expect(editor.string == "\ta\n\tb")
            editor.outdentLines(nil)
            #expect(editor.string == "a\nb")
        }

        /// Openers bring their partners, outside strings; closers step over them; Delete takes an empty pair; ⌘Z undoes it.
        @Test func bracketsAndQuotesCloseThemselves() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor)
            func type(_ text: String) { for c in text { editor.insertText(String(c), replacementRange: editor.selectedRange()) } }
            editor.setText("")
            type("(")
            #expect(editor.string == "()" && editor.selectedRange().location == 1)
            type("'a")
            #expect(editor.string == "('a')")
            type("(")
            #expect(editor.string == "('a(')", "no pair inside a string")
            type("'")
            type(")")
            #expect(editor.string == "('a(')" && editor.selectedRange().location == 6, "both steps went over")
            editor.setText("()")
            editor.setSelectedRange(NSRange(location: 1, length: 0))
            editor.deleteBackward(nil)
            #expect(editor.string == "")
            editor.setText("a b")
            editor.setSelectedRange(NSRange(location: 2, length: 1))
            type("`")
            #expect(editor.string == "a `b`" && editor.selectedRange() == NSRange(location: 3, length: 1))
            editor.setText("abc")
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            type("(")
            #expect(editor.string == "(abc", "before a word it stays one")
        }

        /// A dragged result takes the place of the tab it is over; Messages stays where it is.
        @Test func resultTabsReorderByDragging() async throws {
            let (_, _, console) = try await Self.console()
            for title in ["One", "Two", "Three"] { console.addResult(ConsoleFixtures.customers(rows: 1), title: title, summary: "") }
            console.showResults()
            console.view.window?.layoutIfNeeded()
            let one = try #require(console.results.tabButton(for: console.resultTabs[0]))
            let three = try #require(console.results.tabButton(for: console.resultTabs[2]))
            let place = three.convert(NSPoint(x: three.bounds.midX, y: three.bounds.midY), to: nil)
            console.results.dragged(one, to: place)
            console.results.dragged(one, to: place)  // still over the same place: nothing more moves
            console.results.dragEnded()
            #expect(console.resultTabs.map(\.title) == ["Two", "Three", "One"])
        }

        @Test func goToLineAndWordWrap() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor)
            editor.setText("one\ntwo\nthree")
            editor.goTo(line: 3)
            #expect(editor.selectedRange().location == 8)
            editor.goTo(line: 99)
            #expect(editor.selectedRange().location == 13)
            #expect(editor.textContainer?.widthTracksTextView == true && !editor.isHorizontallyResizable)  // on from the start
            #expect(editor.enclosingScrollView?.hasHorizontalScroller == false)
            console.toggleWordWrap(nil)
            #expect(editor.textContainer?.widthTracksTextView == false && editor.isHorizontallyResizable)
            console.toggleWordWrap(nil)
            #expect(editor.textContainer?.widthTracksTextView == true && !editor.isHorizontallyResizable)
        }

        /// An unknown table is underlined from the schema cache a moment after the typing, with no session; Run isn't held back.
        @Test func anUnknownTableIsUnderlinedAndSaysWhatWasNotFound() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor)
            var context = (snapshot: Optional(SQLNameCheckTests.snapshot()), database: Optional("shop"), changed: Set<String>())
            editor.nameContext = { context }
            editor.setText("SELECT * FROM nosuch")
            editor.check()
            #expect(await eventually(timeout: 10) { !editor.problems.isEmpty })
            #expect(editor.problems.map(\.range) == [14..<20] && editor.problems[0].message.hasPrefix("No table named “nosuch”"))
            context.snapshot = nil
            editor.check()
            #expect(await eventually(timeout: 10) { editor.problems.isEmpty })
        }

        /// Statements after which the navigator's tree reloads.
        /// Where a Run failed is underlined and says why on hover, until the text changes.
        @Test func aFailedRunsPlaceIsUnderlinedUntilTheTextChanges() async throws {
            let (_, _, console) = try await Self.console()
            let editor = try #require(console.editor), layout = try #require(editor.layoutManager)
            editor.setText("SELECT 1\nFORM t")
            editor.runProblem = SQLProblem(range: 9..<13, message: "The SQL has a syntax error.")
            func underlined(_ index: Int) -> Bool {
                layout.temporaryAttribute(.underlineStyle, atCharacterIndex: index, effectiveRange: nil) != nil
            }
            #expect(underlined(10) && !underlined(14) && !underlined(2))
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 10, length: 1), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: try #require(editor.textContainer))
            let over = NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y)
            #expect(editor.view(editor, stringForToolTip: 0, point: over, userData: nil) == "The SQL has a syntax error.")
            #expect(editor.view(editor, stringForToolTip: 0, point: NSPoint(x: 8, y: 10), userData: nil) == "")
            editor.setSelectedRange(NSRange(location: 8, length: 0))
            editor.insertText(" ", replacementRange: editor.selectedRange())
            #expect(editor.runProblem == nil && !underlined(11))
            // What the text leaves open needs no Run, and goes when it is closed.
            editor.setText("SELECT (1")
            editor.check()
            #expect(underlined(7) && editor.problems.map(\.message) == ["This ( has no closing )"])
            editor.setSelectedRange(NSRange(location: 9, length: 0))
            editor.insertText(")", replacementRange: editor.selectedRange())
            editor.check()
            #expect(!underlined(7) && editor.problems.isEmpty)
        }

        /// ⌘Z takes back the text in front of you: each console has its own steps, and an object editor's don't touch them.
        @Test func eachTextHasItsOwnUndo() async throws {
            let model = testModel(Fixtures.shop)
            let (main, harness, first) = try await Self.console(model)
            _ = await call(harness, "type", ["text": "one"])
            first.editor.undoManager?.removeAllActions()  // a test's typing has no event to end its undo group
            first.editor.replace(NSRange(location: 3, length: 0), with: " more")
            #expect(await call(harness, "menu", ["path": "File > New Query"]).error == nil)
            let second = try #require(main.selectedTab?.content as? ConsoleViewController)
            #expect(second !== first && main.window?.firstResponder === second.editor)
            second.editor.replace(NSRange(location: 0, length: 0), with: "two")
            #expect(first.editor.undoManager !== second.editor.undoManager)
            #expect(await call(harness, "menu", ["path": "Edit > Undo"]).error == nil)
            #expect(second.text == "" && first.text == "one more")
            #expect(await call(harness, "menu", ["path": "Edit > Redo"]).error == nil)
            #expect(second.text == "two")
            // A loaded text is a starting point, and only its own editor's.
            second.editor.setText("loaded")
            #expect(second.editor.undoManager?.canUndo == false && first.editor.undoManager?.canUndo == true)
        }

        /// A long server error shows whole, wrapped at the column's width, and its text can be selected.
        @Test func messagesShowTheWholeText() async throws {
            let (_, _, console) = try await Self.console()
            let view = console.messagesView
            view.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
            let long = String(repeating: "You have an error in your SQL syntax near here. ", count: 40)
            view.append(ConsoleMessage(level: .ok, range: nil, line: nil, statement: "", text: "Done"))
            view.append(ConsoleMessage(level: .error, range: nil, line: 1, statement: "SELECT", text: long))
            #expect(view.tableView(view.table, heightOfRow: 0) == view.table.rowHeight)
            let tall = view.tableView(view.table, heightOfRow: 1)
            let column = try #require(view.table.tableColumns.last)
            let field = try #require(view.tableView(view.table, viewFor: column, row: 1) as? NSTextField)
            #expect(field.stringValue == long && field.isSelectable && field.lineBreakMode == .byWordWrapping)
            field.frame.size.width = column.width
            #expect(tall >= field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: column.width, height: 100_000)).height)
            // Narrower, it takes more lines.
            column.width /= 2
            view.tableViewColumnDidResize(Notification(name: NSTableView.columnDidResizeNotification))
            #expect(view.tableView(view.table, heightOfRow: 1) > tall)
        }

        /// A result tab's ✕ closes that tab, shown or not; Messages has none; keys go round the bar, Messages included.
        @Test func resultTabsCloseAndStep() async throws {
            let (_, harness, console) = try await Self.console()
            let one = ResultStore(columns: []), two = ResultStore(columns: [])
            console.addResult(one, title: "One", summary: "")
            console.addResult(two, title: "Two", summary: "")
            console.selectResult(console.resultTabs[0])
            func shown() -> String? { console.selectedResult?.title }
            #expect(await call(harness, "menu", ["path": "Query > Show Next Result"]).error == nil)
            #expect(shown() == "Two")
            #expect(await call(harness, "menu", ["path": "Query > Show Next Result"]).error == nil)
            #expect(shown() == "Messages")
            #expect(await call(harness, "menu", ["path": "Query > Show Next Result"]).error == nil)
            #expect(shown() == "One")
            #expect(await call(harness, "menu", ["path": "Query > Show Previous Result"]).error == nil)
            #expect(shown() == "Messages")
            let buttons = console.results.buttons
            #expect(buttons.map(\.closeButton.isHidden) == [false, false, true])
            buttons[0].closeButton.performClick(nil)
            #expect(console.resultTabs.map(\.title) == ["Two"] && shown() == "Two")
        }

        /// ⌘F in a result's rows: the find bar works on them as in a table tab, on one result shown on its side too.
        @Test func findWorksOnAResultsRows() async throws {
            let (main, harness, console) = try await Self.console()
            let store = ResultStore(columns: [ResultStore.Column(name: "name", type: MYSQL_TYPE_VAR_STRING)])
            for name in ["Ann", "Bob", "Anna"] { _ = store.append([Array(name.utf8)]) }
            console.addResult(store, title: "People", summary: "")
            console.showResults()
            let view = try #require(console.resultTabs.first?.view as? ResultGridView)
            main.window?.makeFirstResponder(view.grid)
            #expect(await call(harness, "menu", ["path": "Edit > Find > Find…"]).error == nil)
            #expect(!view.findBar.isHidden && view.findBar.replaceField.isHidden)
            view.findBar.findField.stringValue = "ann"
            view.findChanged()
            #expect(view.findBar.count.stringValue == "2 matching" && view.viewer.highlight != nil)
            view.findMatch(forward: true)
            #expect(view.grid.selection.cursor == GridPosition(row: 0, column: 0) && view.findBar.count.stringValue == "1 of 2")
            view.findMatch(forward: true)
            #expect(view.grid.selection.cursor == GridPosition(row: 2, column: 0))
            view.findBar.options.item(at: 4)?.state = .on  // Filter Rows
            view.findChanged()
            #expect(view.rows.rowCount == 2)
            view.findBar.close(nil)
            #expect(view.findBar.isHidden && view.rows.rowCount == 3 && view.viewer.highlight == nil)
            let replace = Commands.findAndReplace.item()
            #expect(!view.validateMenuItem(replace))
        }

        @Test func schemaChangesAreToldApart() {
            #expect(ConsoleViewController.changesSchema("/* new */ create table t (id int)"))
            #expect(ConsoleViewController.changesSchema("DROP VIEW v") && ConsoleViewController.changesSchema("rename table a to b"))
            #expect(!ConsoleViewController.changesSchema("SELECT 'CREATE'") && !ConsoleViewController.changesSchema("INSERT INTO t VALUES (1)"))
        }

        /// What a DROP or TRUNCATE asks to be typed: the names without their backticks, dots and commas inside them kept.
        @Test func typedNamesLoseOnlyTheirBackticks() {
            #expect(ConsoleSafety.unquoted("`shop`.`my orders`") == "shop.my orders")
            #expect(ConsoleSafety.unquoted("`my.db`") == "my.db")
            #expect(ConsoleSafety.unquoted("`a`, shop.`b``c`") == "a, shop.b`c")
            #expect(ConsoleSafety.unquoted("plain") == "plain")
        }

        @Test func typingColoursTheSQLAndTheEditorsCommandsChangeIt() async throws {
            let (main, harness, console) = try await Self.console()
            _ = await call(harness, "type", ["text": "select a, `from` from t where x = 'from' -- note"])
            let storage = try #require(console.editor.textStorage)
            func color(at text: String) -> NSColor? {
                storage.attribute(.foregroundColor, at: (storage.string as NSString).range(of: text).location, effectiveRange: nil) as? NSColor
            }
            #expect(color(at: "select") == .sqlKeyword && color(at: "'from'") == .sqlString && color(at: "-- note") == .sqlComment)
            #expect(color(at: "`from`") == .sqlIdentifier)
            // A word becomes a call when ( is typed after it, and stops being one when the ( goes.
            console.editor.setSelectedRange(NSRange(location: (storage.string as NSString).range(of: " t ").location + 3, length: 0))
            _ = await call(harness, "type", ["text": "("])
            #expect(color(at: "t (") == .sqlFunction)
            console.editor.deleteBackward(nil)
            #expect(color(at: "t where") == .sqlIdentifier)
            #expect(console.isEdited && main.tabBar.buttons.first?.toolTip?.contains("(unsaved)") == true)

            #expect(await call(harness, "menu", ["path": "Query > Format SQL"]).error == nil)
            #expect(console.text == "SELECT a, `from`\nFROM t\nWHERE x = 'from' -- note")
            console.editor.selectAll(nil)
            #expect(await call(harness, "menu", ["path": "Edit > Comment Lines"]).error == nil)
            #expect(console.text == "-- SELECT a, `from`\n-- FROM t\n-- WHERE x = 'from' -- note")
            #expect(await call(harness, "menu", ["path": "Edit > Comment Lines"]).error == nil)
            #expect(console.text == "SELECT a, `from`\nFROM t\nWHERE x = 'from' -- note")
            #expect(await call(harness, "menu", ["path": "Edit > Shift Right"]).error == nil)
            #expect(console.text.hasPrefix("    SELECT") && console.text.contains("\n    FROM"))
            #expect(await call(harness, "menu", ["path": "Edit > Shift Left"]).error == nil)
            #expect(console.text.hasPrefix("SELECT"))
        }

        @Test func findAndReplaceWithARegularExpression() async throws {
            let (_, harness, console) = try await Self.console()
            _ = await call(harness, "type", ["text": "SELECT o1, o2 FROM t WHERE o3 = 'O4'"])
            #expect(await call(harness, "menu", ["path": "Edit > Find > Find and Replace…"]).error == nil)
            let find = try #require(console.findBar)
            #expect(!find.isHidden && console.view.window?.firstResponder === find.search.currentEditor())
            find.search.stringValue = "o(\\d)"
            find.update()
            #expect(find.matches()?.isEmpty == true, "plain text: there is no o(\\d)")
            find.regex.state = .on
            find.update()
            #expect(find.matches()?.count == 4, "any case by default")
            find.matchCase.state = .on
            find.update()
            #expect(find.matches()?.count == 3)
            find.replacement.stringValue = "col$1"
            find.update()
            _ = await call(harness, "press", ["id": "find.replaceAll"])
            #expect(console.text == "SELECT col1, col2 FROM t WHERE col3 = 'O4'")
            find.search.stringValue = "("
            find.update()
            #expect(find.matches() == nil, "not a regular expression")
            find.close(nil)
            #expect(find.isHidden && console.view.window?.firstResponder === console.editor)
        }

        @Test func theSQLLogShowsFiltersAndClearsTheLog() async throws {
            let folder = try scratch()
            let log = SQLLog(fileURL: URL(fileURLWithPath: folder + "/SQL.log"))
            log.statement("SELECT * FROM orders", context: "Shop main:1", noBackslashEscapes: false)
            log.statement("CREATE USER x IDENTIFIED BY 'secret'", context: "Shop main:2", noBackslashEscapes: false)
            let viewer = SQLLogWindowController.show(log)
            keptWindows.append(viewer)
            viewer.window?.setFrameOrigin(NSPoint(x: -22000, y: -22000))
            #expect(await eventually(timeout: 5) { viewer.lines.count == 2 })
            #expect(viewer.lines.last?.contains("<secret>") == true && viewer.lines.last?.contains("'secret'") == false)
            log.statement("SELECT 2", context: "Shop main:3", noBackslashEscapes: false)
            viewer.refresh()
            #expect(await eventually(timeout: 5) { viewer.lines.count == 3 }, "follows what is added")
            // A selection outlives the reads, and lines that come after it.
            let textView = viewer.text
            #expect(await eventually(timeout: 5) { textView.string.contains("SELECT 2") })
            let selected = NSRange(location: 3, length: 12)
            textView.setSelectedRange(selected)
            viewer.refresh()
            log.statement("SELECT 3", context: "Shop main:4", noBackslashEscapes: false)
            #expect(await eventually(timeout: 5) {
                viewer.refresh()
                return textView.string.contains("SELECT 3")
            })
            #expect(textView.selectedRange() == selected)
            #expect(textView.string.components(separatedBy: "\n").count == 5, "each line once")
            SQLLogWindowController.clear(log)
            #expect(await eventually(timeout: 5) { !FileManager.default.fileExists(atPath: log.fileURL.path) })
            viewer.refresh()
            #expect(await eventually(timeout: 5) { viewer.lines.isEmpty })
            viewer.close()
        }

        @Test func completionOffersJoinsAndColumnsFromTheSchemaCache() async throws {
            let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
            ConsoleViewController.schemaCache = { _ in cache }
            defer { ConsoleViewController.schemaCache = { _ in nil } }
            var saved = Fixtures.local
            saved.database = "airsql_fixture"
            let (_, harness, console) = try await Self.console(testModel([saved]), on: saved.id)
            _ = await call(harness, "type", ["text": "SELECT * FROM orders o JOIN "])
            console.editor.complete(nil)
            let popup = try #require(console.editor.completionPopup)
            #expect(popup.isShown && popup.selected?.text == "customers c ON c.id = o.customer_id")
            console.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(!popup.isShown && console.text == "SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id")
            // Typing a dot after an alias lists its columns; ↓ and Tab choose and insert.
            console.editor.insertText(" WHERE c", replacementRange: console.editor.selectedRange())
            console.editor.insertText(".", replacementRange: console.editor.selectedRange())
            #expect(popup.isShown && popup.items.allSatisfy { $0.kind == .column })
            console.editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            let second = try #require(popup.selected)
            console.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(console.text.hasSuffix("WHERE c." + second.text))
            // Not inside a string.
            console.editor.insertText(" = 'o", replacementRange: console.editor.selectedRange())
            #expect(!popup.isShown)
        }

        @Test func templatesExpandAndTabWalksTheirFields() async throws {
            let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
            ConsoleViewController.schemaCache = { _ in cache }
            defer { ConsoleViewController.schemaCache = { _ in nil } }
            var saved = Fixtures.local
            saved.database = "airsql_fixture"
            let (_, _, console) = try await Self.console(testModel([saved]), on: saved.id)
            let editor = console.editor!
            func type(_ text: String) { for character in text { editor.insertText(String(character), replacementRange: editor.selectedRange()) } }
            // The abbreviation is on top of the list: Tab takes it, with its first field selected.
            type("selw")
            #expect(editor.completionPopup?.selected?.kind == .template)
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(console.text == "SELECT * FROM table WHERE condition;")
            #expect((console.text as NSString).substring(with: editor.selectedRange()) == "table")
            // What's typed goes in the field, and the next field is still found.
            type("orders")
            editor.completionPopup?.close()
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect((console.text as NSString).substring(with: editor.selectedRange()) == "condition")
            type("1")
            editor.completionPopup?.close()
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(console.text == "SELECT * FROM orders WHERE 1;" && editor.selectedRange().location == (console.text as NSString).length)
            #expect(editor.templateFields.isEmpty)
            console.editor.setText("")
            // A field used twice takes a caret in each place; Escape stops.
            editor.insertTemplate("$a$ = $a$ + $b$", replacing: NSRange(location: 0, length: 0))
            #expect(editor.extraCarets.count == 1)
            type("x")
            #expect(console.text == "x = x + b")
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect((console.text as NSString).substring(with: editor.selectedRange()) == "b" && editor.extraCarets.isEmpty)
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            #expect(editor.templateFields.isEmpty)
            // A second line starts where the first does.
            editor.setText("  ")
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            editor.insertTemplate("a\nb$END$", replacing: editor.selectedRange())
            #expect(console.text == "  a\n  b" && editor.selectedRange().location == 7)
            // A postfix goes the same way, with no list open.
            editor.setText("log.from")
            editor.setSelectedRange(NSRange(location: 8, length: 0))
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(console.text == "SELECT * FROM log")
            // Plain Tab still indents.
            editor.setText("xyz")
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(console.text != "xyz")
        }

        @Test func snippetsAndHistoryInTheHelpers() async throws {
            let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
            ConsoleViewController.schemaCache = { _ in cache }
            defer { ConsoleViewController.schemaCache = { _ in nil } }
            var saved = Fixtures.local
            saved.database = "airsql_fixture"
            let model = testModel([saved])
            model.data.settings.snippets = [SQLSnippet(name: "Wrap", abbreviation: "wr", folder: "Work", body: "($SELECTION$) AS $alias$")]
            let (_, harness, console) = try await Self.console(model, on: saved.id)
            #expect(await call(harness, "menu", ["path": "View > Query Helpers"]).error == nil)
            let panel = console.helpers
            panel.choice.selectedSegment = 3
            panel.reload()
            #expect((panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue == "Work")
            #expect((panel.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTextField)?.stringValue == "Wrap (wr)")
            // Inserted around the selection, with its field chosen.
            console.editor.setText("SELECT 1")
            console.editor.setSelectedRange(NSRange(location: 0, length: 8))
            panel.table.selectRowIndexes([1], byExtendingSelection: false)
            panel.insertSelected(nil)
            #expect(console.text == "(SELECT 1) AS alias")
            #expect((console.text as NSString).substring(with: console.editor.selectedRange()) == "alias")
            // Its abbreviation works in the editor.
            console.editor.setText("wr")
            console.editor.setSelectedRange(NSRange(location: 2, length: 0))
            console.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(console.text == "() AS alias")
            // Save as Snippet takes the statement, with its dollars kept.
            console.editor.setText("SELECT '$1'")
            console.saveAsSnippet(nil)
            let sheet = try #require(console.presentedViewControllers?.first as? SnippetSheet)
            let name = try #require(find(NSTextField.self, id: "snippet.name", in: sheet.view))
            name.stringValue = "Dollar"
            let save = try #require(find(NSButton.self, id: "snippet.save", in: sheet.view))
            save.performClick(nil)
            #expect(model.data.settings.snippets.last?.name == "Dollar" && model.data.settings.snippets.last?.body == "SELECT '$$1'")
            #expect(SQLTemplate.expand(model.data.settings.snippets.last!.body).text == "SELECT '$1'")
            // History comes by day, and inserts the statement.
            let entries = [HistoryEntry(sql: "SELECT 2", connection: saved.id, duration: 2), HistoryEntry(sql: "SELECT 3\nFROM t", connection: saved.id, duration: 1)]
            panel.history = { entries }
            panel.choice.selectedSegment = 4
            panel.reload()
            #expect(await eventually(timeout: 5) { panel.table.numberOfRows == 3 })
            panel.table.selectRowIndexes([2], byExtendingSelection: false)
            console.editor.setText("")
            panel.insertSelected(nil)
            #expect(console.text == "SELECT 3\nFROM t")
            // With no table in the statement the columns of the tree's table would show: with none selected, it says so.
            panel.choice.selectedSegment = 0
            console.editor.setText("")
            panel.reload()
            #expect(find(NSTextField.self, id: "helpers.empty", in: panel)?.stringValue.contains("in the tree") == true)
        }

        @Test func keywordsTakeTheirCaseAsTyped() async throws {
            var saved = Fixtures.local
            saved.database = "airsql_fixture"
            let model = testModel([saved])
            model.data.settings.autoKeywordCase = true
            SQLEditorView.settings = { [weak model] in model?.data.settings ?? AppSettings() }
            defer { SQLEditorView.settings = { AppSettings() } }
            let (_, _, console) = try await Self.console(model, on: saved.id)
            let editor = console.editor!
            func type(_ text: String) { for character in text { editor.insertText(String(character), replacementRange: editor.selectedRange()) } }
            type("select a.from, 'from ', `from` from t -- from \n")
            #expect(console.text == "SELECT a.from, 'from ', `from` FROM t -- from \n")
            model.data.settings.formatStyle.keywords = .lower
            editor.setText("")
            type("SELECT 1 ")
            #expect(console.text == "select 1 ")
            model.data.settings.autoKeywordCase = false
            editor.setText("")
            type("SELECT 1 ")
            #expect(console.text == "SELECT 1 ")
        }

        @Test func formatPaneShowsItsRulesAtWork() async throws {
            let model = testModel([])
            let pane = FormatPane(model: model)
            pane.loadView()
            func preview() -> String { find(NSTextView.self, id: "settings.format.preview", in: pane.view)?.string ?? "" }
            model.data.settings.formatStyle.keywords = .lower
            #expect(preview().contains("select c.id") && preview().contains("\nfrom customers c"))
            let presets = try #require(find(NSPopUpButton.self, id: "settings.format.preset", in: pane.view))
            let modern = try #require(SQLFormatStyle.presets.firstIndex { $0.name == "River" })
            presets.selectItem(at: modern + 1)
            _ = presets.sendAction(presets.action, to: presets.target)
            #expect(model.data.settings.formatStyle.river && preview().contains("  FROM customers c"))
            let lists = try #require(find(NSPopUpButton.self, id: "settings.format.lists", in: pane.view))
            #expect(lists.indexOfSelectedItem == 2, "the controls follow the preset")
        }

        @Test func helpersFollowTheStatementAndInsert() async throws {
            let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
            ConsoleViewController.schemaCache = { _ in cache }
            defer { ConsoleViewController.schemaCache = { _ in nil } }
            var saved = Fixtures.local
            saved.database = "airsql_fixture"
            let (_, harness, console) = try await Self.console(testModel([saved]), on: saved.id)
            _ = await call(harness, "type", ["text": "SELECT  FROM orders o"])
            console.editor.setSelectedRange(NSRange(location: 7, length: 0))
            #expect(await call(harness, "menu", ["path": "View > Query Helpers"]).error == nil)
            #expect(console.helpersShown)
            let panel = console.helpers
            #expect(panel.table.numberOfRows > 2)
            #expect((panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue == "orders o")
            panel.table.selectRowIndexes([2], byExtendingSelection: false)
            // Dragged into the editor, a column drops what a double-click inserts (quoted as completion quotes it).
            let name = try #require((panel.table.view(atColumn: 0, row: 2, makeIfNecessary: true) as? NSTextField)?.stringValue)
            let dragged = panel.tableView(panel.table, pasteboardWriterForRow: 2) as? NSPasteboardItem
            #expect(dragged?.string(forType: .string) == SQLCompletion.quote(name) && panel.tableView(panel.table, pasteboardWriterForRow: 0) == nil)
            panel.insertSelected(nil)
            #expect(console.text.hasPrefix("SELECT customer_id FROM") || console.text.hasPrefix("SELECT id FROM"), "\(console.text)")
            panel.choice.selectedSegment = 1
            panel.reload()
            #expect((panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue == "Aggregate")
            #expect(await call(harness, "menu", ["path": "View > Query Helpers"]).error == nil)
            #expect(!console.helpersShown)
        }

        /// .sql files dropped anywhere on the window (the root view takes what no view under the pointer does) open in
        /// console tabs of the active connection.
        @Test func sqlFilesDroppedOnTheWindowOpenInConsoles() async throws {
            let file = URL(fileURLWithPath: try scratch() + "/dropped.sql")
            try "SELECT 'dropped';".write(to: file, atomically: true, encoding: .utf8)
            let model = testModel([Fixtures.local])
            let (main, _) = appWindow(model)
            main.sidebar.select([Fixtures.local.id])
            main.sidebarSelectionChanged()
            let root = try #require(main.window?.contentView as? FileDropView)
            #expect(root.registeredDraggedTypes.contains(.fileURL))
            root.open?([file])
            #expect(await eventually(timeout: 5) { (main.selectedTab?.content as? ConsoleViewController)?.fileURL == file })
            #expect(main.selectedTab?.connectionID == Fixtures.local.id && main.selectedTab?.title == "dropped.sql")
            for tab in main.tabs { main.close(tab) }
        }

        @Test func filesOpenSaveAndTabsComeBackAfterRelaunch() async throws {
            let folder = try scratch()
            ConsoleDocuments.shared.fileURL = URL(fileURLWithPath: folder + "/Consoles.json")
            let file = URL(fileURLWithPath: folder + "/top customers.sql")
            try "SELECT 1;".write(to: file, atomically: true, encoding: .utf8)
            let (main, harness, untitled) = try await Self.console()
            _ = await call(harness, "type", ["text": "SELECT 'unsaved';"])
            main.openFiles([file])
            #expect(await eventually(timeout: 5) { main.tabs.count == 2 })
            let opened = try #require(main.selectedTab?.content as? ConsoleViewController)
            #expect(main.selectedTab?.title == "top customers.sql" && opened.text == "SELECT 1;" && !opened.isEdited && !opened.canRename)
            _ = await call(harness, "type", ["text": "\nSELECT 2;"])
            #expect(opened.isEdited)
            opened.saveQuery(nil)
            #expect(await eventually(timeout: 5) { !opened.isEdited })
            #expect(try String(contentsOf: file, encoding: .utf8) == "SELECT 1;\nSELECT 2;")
            await main.openFiles([file]).value
            #expect(main.tabs.count == 2, "a file already open shows its tab")

            // Quit and launch again: both come back, in order, with their text and connection.
            _ = await call(harness, "type", ["text": "\n-- not saved yet"])
            ConsoleDocuments.shared.main = main
            ConsoleDocuments.shared.saveNow()
            let (relaunched, _) = appWindow(testModel(Fixtures.shop))
            ConsoleDocuments.shared.restore(into: relaunched)
            // The file opened from Finder as AirSQL starts: its tab coming back shows, with its unsaved text, not a second.
            await relaunched.openFiles([file]).value
            let restored = relaunched.tabs.compactMap { $0.content as? ConsoleViewController }
            #expect(relaunched.tabs.map(\.title) == ["Query 1", "top customers.sql"])
            #expect(restored.first?.text == untitled.text && restored.first?.connectionID == Fixtures.production.id)
            #expect(restored.last?.text == "SELECT 1;\nSELECT 2;\n-- not saved yet" && restored.last?.isEdited == true)
            #expect(restored.last?.fileURL == file)
            relaunched.select(relaunched.tabs[0])
            await relaunched.openFiles([file]).value
            #expect(relaunched.tabs.count == 2 && relaunched.selectedTab === relaunched.tabs[1], "opened again: its tab shows")
            ConsoleDocuments.shared.fileURL = ConsoleTabStore.fileURL
        }

        @Test func runSaysToConnectFirst() async throws {
            let (_, harness, console) = try await Self.console()
            _ = await call(harness, "type", ["text": "SELECT 1"])
            let run = await call(harness, "menu", ["path": "Query > Run Statement"])
            #expect(run.error?.contains("Connect first") == true, "\(run.error ?? "")")
            #expect(console.results.cancelButton.isHidden)
            let commit = await call(harness, "menu", ["path": "Query > Commit"])
            #expect(commit.error?.contains("No transaction is open") == true, "\(commit.error ?? "")")
        }

        /// A console without a connection says how to give it one: with Change Connection, or by adding the first.
        @Test func aConsoleWithoutAConnectionSaysHowToGetOne() async throws {
            func empty(_ main: MainWindowController) -> String? {
                main.window?.layoutIfNeeded()
                return main.selectedTab.flatMap { find(NSTextField.self, id: "console.empty", in: $0.content.view)?.stringValue }
            }
            let (main, _) = appWindow(testModel(Fixtures.shop))
            main.openConsole(text: "SELECT 1", title: "orders.sql", connection: nil)
            #expect(empty(main) == "Choose a connection for this tab with Query ▸ Change Connection… to run SQL.")
            let model = testModel()
            let (first, _) = appWindow(model)
            first.openConsole(text: "SELECT 1", title: "orders.sql", connection: nil)
            #expect(empty(first) == "Add a connection with File ▸ New Connection… (⌘N) to run SQL.")
            model.data.connections.append(Fixtures.local)
            #expect(await eventually(timeout: 5) { empty(first)?.hasPrefix("Choose a connection") == true })
        }

        /// A read-only connection's console refuses what AirSQL can't prove only reads before it sends anything: here to a
        /// connection that can't connect (nothing listens on port 1), so a statement sent would fail there instead.
        @Test func aReadOnlyConnectionsConsoleRefusesWhatMayWrite() async throws {
            var saved = Fixtures.production
            saved.readOnly = true
            let unreachable = Connection(options: ConnectOptions(host: "127.0.0.1", port: 1, user: "nobody"))
            ConsoleViewController.openConnection = { $0 == saved.id ? unreachable : nil }
            defer { ConsoleViewController.openConnection = { _ in nil } }
            let (_, harness, console) = try await Self.console(testModel([saved]))
            for (sql, command) in [("SET SESSION TRANSACTION READ WRITE;\nCREATE DATABASE lane_safety_probe;", "Run All"),
                                   ("START TRANSACTION READ WRITE", "Run Statement"), ("UPDATE t SET a = 1", "Explain"),
                                   ("SELECT SLEEP(1)", "Profile")] {
                console.editor.setText(sql)
                #expect(await call(harness, "menu", ["path": "Query > " + command]).error == nil, "\(command)")
                #expect(console.running == nil, "\(command)")
                #expect(console.messagesView.messages.last?.text.hasPrefix("“Production · shop” is read-only, so nothing ran.")
                        == true, "\(command): \(console.messagesView.messages.last?.text ?? "")")
            }
            #expect(console.messagesView.messages.first?.text == "“Production · shop” is read-only, so nothing ran. SET isn't "
                + "a read-only statement; only SELECT, WITH … SELECT, SHOW, DESCRIBE and EXPLAIN are. To change anything, "
                + "turn off Read-only in its connection settings.")
            #expect(console.messagesView.messages.map(\.statement) == ["SET SESSION TRANSACTION READ WRITE",
                                                                    "START TRANSACTION READ WRITE",
                                                                    "EXPLAIN UPDATE t SET a = 1", "SELECT SLEEP(1)"])
        }

        /// The audit's probe on a read-only connection to MariaDB 11.4 and MySQL 8.4: SET SESSION TRANSACTION READ WRITE
        /// would lift the session's own READ ONLY and let CREATE DATABASE through, so the console refuses both, and START
        /// TRANSACTION READ WRITE; SELECT, SHOW, EXPLAIN and USE still run, and Explain and Profile too.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"), arguments: [Lab.mariadb114, Lab.mysql84])
        func aReadOnlyConnectionRefusesTheProbeAndStillReads(_ server: Lab.Server) async throws {
            var options = DBLab.options(server, tls: DBLab.required)
            options.readOnly = true
            let connection = Connection(options: options, log: DBLab.log)
            try await connection.connect()
            var saved = Fixtures.production
            saved.readOnly = true
            ConsoleViewController.openConnection = { $0 == saved.id ? connection : nil }
            defer { ConsoleViewController.openConnection = { _ in nil } }
            let (_, harness, console) = try await Self.console(testModel([saved]))
            func run(_ sql: String, _ command: String = "Run All") async {
                console.editor.setText(sql)
                #expect(await call(harness, "menu", ["path": "Query > " + command]).error == nil, "\(command)")
                _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            }

            let probe = "lane_safety_probe"
            for sql in ["SET SESSION TRANSACTION READ WRITE;\nCREATE DATABASE \(probe);", "START TRANSACTION READ WRITE",
                        "CREATE DATABASE \(probe)"] {
                await run(sql)
                #expect(console.messagesView.messages.last?.text.contains("is read-only, so nothing ran.") == true,
                        "\(sql): \(console.messagesView.messages.map(\.text))")
            }
            let main = try await connection.session(.main)
            #expect(try await main.query("SELECT @@transaction_read_only").first?.rows?.string(0, 0) == "1")
            #expect(try await main.query("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '\(probe)'")
                .first?.rows?.string(0, 0) == "0")

            let before = console.messagesView.messages.count
            await run("USE fixture;\nSELECT COUNT(*) FROM customers;\nSHOW TABLES;\nEXPLAIN SELECT * FROM customers WHERE id = 1;")
            // MySQL's EXPLAIN adds a note (1003, the query as it rewrote it): a warning, not an error.
            #expect(console.messagesView.messages.dropFirst(before).prefix(4).map(\.level) == [.ok, .ok, .ok, .ok]
                    && !console.messagesView.messages.dropFirst(before).contains { $0.level == .error },
                    "\(console.messagesView.messages.dropFirst(before).map(\.text))")
            #expect(console.resultTabs.count == 3)
            await run("SELECT * FROM customers WHERE id = 1", "Explain")
            #expect(console.selectedResult?.title == "Plan")
            await run("SELECT * FROM customers WHERE id = 1", "Profile")
            #expect(console.resultTabs.last?.title == "Profile", "\(console.resultTabs.map(\.title))")
            await connection.disconnect()
        }

        /// Run All against MariaDB 11.8: a result tab per result set (named from the comment above), Messages, Manual
        /// mode's transaction in the badge, and closing the last console with the transaction open.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func runsStatementsAndHoldsTheTransactionUntilAsked() async throws {
            let options = DBLab.options(DBLab.server("mariadb"), tls: DBLab.required)
            let connection = Connection(options: options, log: DBLab.log)
            try await connection.connect()
            let database = "lane_l4_console_app"
            let setup = try await connection.toolsSession()
            for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)", "CREATE TABLE \(database).t (id INT PRIMARY KEY)"] {
                _ = try await setup.query(sql)
            }
            ConsoleViewController.openConnection = { $0 == Fixtures.production.id ? connection : nil }
            defer { ConsoleViewController.openConnection = { _ in nil } }
            let model = testModel(Fixtures.shop)
            model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8")
            let (main, harness, console) = try await Self.console(model)

            _ = await call(harness, "type", ["text": "-- Two numbers\nSELECT 1 AS one;\nSELECT 2 AS two, 3 AS three;"])
            #expect(await call(harness, "key", ["combo": "cmd+shift+return"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.resultTabs.map(\.label) == ["Two numbers · 1 × 1", "Result 2 · 1 × 2"])
            #expect(console.messagesView.messages.map(\.level) == [.ok, .ok])
            #expect(console.messagesView.messages.first?.line == 2)

            #expect(await call(harness, "menu", ["path": "Query > Transaction Mode > Manual Commit"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(!console.autocommit)
            _ = await call(harness, "type", ["text": "\nINSERT INTO \(database).t VALUES (1), (2);"])
            #expect(await call(harness, "key", ["combo": "cmd+return"]).error == nil)
            // Production asks before any write from the console: the SQL preview sheet, then Run.
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(main.window?.attachedSheet?.title == "Run this statement on Production · shop?")
            #expect(await call(harness, "press", ["title": "Run"]).error == nil)
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.transactionBadge == "Transaction open · 2 changes", "\(console.messagesView.messages.map(\.text))")
            #expect(main.statusBar.transaction.value == "Transaction open · 2 changes")

            // Profile: the statement's result, then where the server spent its time.
            console.editor.setSelectedRange(NSRange(location: 20, length: 0))
            #expect(await call(harness, "menu", ["path": "Query > Profile"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.resultTabs.last?.title == "Profile", "\(console.resultTabs.map(\.title))")

            // Explain: the plan in a tab of its own.
            #expect(await call(harness, "menu", ["path": "Query > Explain"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.selectedResult?.title == "Plan")

            // Closing the connection's last console asks about the transaction, then about the unsaved text.
            main.closeTab(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "press", ["title": "Roll Back"]).error == nil)
            _ = await eventually(timeout: 10) { main.window?.attachedSheet?.title != "" && console.session?.inTransaction == false }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "press", ["title": "Don't Save"]).error == nil)
            #expect(await eventually(timeout: 10) { main.tabs.isEmpty })
            let count = try await setup.query("SELECT COUNT(*) FROM \(database).t").first?.rows?.string(0, 0)
            #expect(count == "0", "rolled back")
            _ = try await setup.query("DROP DATABASE \(database)")
            await connection.disconnect()
        }
    }
}

// Closing several tabs, and the middle button on a tab.
extension AppTests.ConsoleAppTests {
    /// A middle-button release, as the mouse sends it.
    @MainActor static func middleClick() throws -> NSEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center)
        return try #require(event.flatMap(NSEvent.init(cgEvent:)))
    }

    @Test func closeAllTabsAsksAboutEachTabInTurnAndCancelKeepsTheRest() async throws {
        let (main, harness, first) = try await Self.console()
        first.editor.string = "SELECT 1;"
        _ = await call(harness, "menu", ["path": "File > New Query"])
        let second = try #require(main.selectedTab?.content as? ConsoleViewController)
        second.editor.string = "SELECT 2;"
        _ = await call(harness, "menu", ["path": "File > New Query"])
        #expect(main.tabs.count == 3)

        main.closeAllTabs(nil)
        // The first tab isn't the one shown when the command comes, and is still asked about, on show.
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(main.selectedTab?.content === first)
        _ = await call(harness, "press", ["title": "Don't Save"])
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(main.selectedTab?.content === second && main.tabs.count == 2)
        _ = await call(harness, "press", ["title": "Cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(main.tabs.count == 2 && main.selectedTab?.content === second)

        second.editor.string = ""
        main.closeAllTabs(nil)
        #expect(await eventually(timeout: 5) { main.tabs.isEmpty })
    }

    @Test func reopenClosedTabBringsBackAConsolesTextUnderItsName() async throws {
        let (main, harness, console) = try await Self.console()
        console.editor.string = "SELECT 'lost';"
        let title = main.selectedTab?.title
        main.closeTab(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "press", ["title": "Don't Save"])
        #expect(await eventually(timeout: 5) { main.tabs.isEmpty })
        main.reopenClosedTab(nil)
        let back = try #require(main.selectedTab?.content as? ConsoleViewController)
        #expect(back !== console && back.text == "SELECT 'lost';" && main.selectedTab?.title == title)
        back.editor.string = ""
        #expect(!main.validateMenuItem(Commands.reopenClosedTab.item()), "the list is empty again")
    }

    @Test func theMiddleButtonClosesATabNotShownAfterAskingAndTheOneShownStays() async throws {
        let (main, harness, first) = try await Self.console()
        first.editor.string = "SELECT 1;"
        _ = await call(harness, "menu", ["path": "File > New Query"])
        let shown = try #require(main.selectedTab)
        let button = try #require(main.tabBar.buttons.first { $0.tab?.content === first })
        button.otherMouseUp(with: try Self.middleClick())
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "press", ["title": "Don't Save"])
        #expect(await eventually(timeout: 5) { main.tabs.count == 1 })
        #expect(main.selectedTab === shown)
    }

    @Test func theMiddleButtonClosesAResultButNotMessages() async throws {
        let (_, _, console) = try await Self.console()
        console.addResult(ConsoleFixtures.customers(rows: 1), title: "Kept", summary: "")
        console.addResult(ConsoleFixtures.customers(rows: 1), title: "Gone", summary: "")
        let tab = try #require(console.resultTabs.last)
        console.selectResult(tab)
        let button = try #require(console.results.tabButton(for: tab))
        button.otherMouseUp(with: try Self.middleClick())
        #expect(console.resultTabs.count == 1 && !console.resultTabs.contains { $0 === tab })
        let messages = try #require(console.results.tabButton(for: console.messagesTab))
        messages.otherMouseUp(with: try Self.middleClick())
        #expect(console.resultTabs.count == 1 && !console.resultTabs.contains { $0 === tab })
    }
}
