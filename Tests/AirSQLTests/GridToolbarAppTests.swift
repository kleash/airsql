import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The row of actions over a grid, and long values read on demand.
extension AppTests {
    @MainActor @Suite struct GridToolbarAppTests {
        @Test func aTableTabsButtonsActOnItsRowsAndSayWhyTheyCant() async throws {
            let (main, _, tab) = try await GridDataAppTests.tab()
            main.window?.makeFirstResponder(main.sidebar.outline)  // the buttons don't need the focus in the grid
            tab.toolbar.validate()
            let apply = try #require(tab.toolbar.button(Commands.apply))
            #expect(!apply.isEnabled && apply.toolTip == "No changes are pending")

            tab.grid.selection.selectRow(0)
            tab.toolbar.validate()
            let delete = try #require(tab.toolbar.button(Commands.deleteRows))
            #expect(delete.isEnabled && delete.toolTip?.hasSuffix("(\(Commands.deleteRows.shortcut))") == true)
            delete.performClick(nil)
            #expect(tab.source?.changes.isEmpty == false)
            tab.toolbar.validate()
            #expect(apply.isEnabled)

            let panel = try #require(tab.toolbar.button(Commands.valuePanel))
            panel.performClick(nil)
            #expect(tab.viewer.valuePanel != nil)
            tab.toolbar.validate()
            #expect(panel.contentTintColor == .accent)
        }

        @Test func theFindButtonOpensTheFindBarFromAnywhere() async throws {
            let (main, _, tab) = try await GridDataAppTests.tab()
            main.window?.makeFirstResponder(main.sidebar.outline)
            tab.toolbar.validate()
            let find = try #require(tab.toolbar.button(Commands.find))
            find.performClick(nil)
            #expect(!tab.findBar.isHidden)
        }

        @Test func aResultShowsItsEditingButtonsOnlyWhenItCanBeEdited() async throws {
            let (main, _) = appWindow(testModel())
            let store = ConsoleFixtures.customers(rows: 2)
            let view = ResultGridView(store: store, nullText: "NULL", fontSize: 12)
            main.window?.contentView = view
            view.showToolbar()
            main.window?.layoutIfNeeded()
            view.toolbar.validate()
            #expect(view.toolbar.button(Commands.apply)?.isHidden == true)
            // Nothing outside the console answers these: not shown.
            #expect(view.toolbar.button(Commands.pinResult)?.isHidden == true)
            let transpose = try #require(view.toolbar.button(Commands.transpose))
            #expect(!transpose.isHidden)
            transpose.performClick(nil)
            #expect(view.viewer.transposed)
        }

        @Test func everyButtonHasATipAndAnImage() async throws {
            let (_, _, tab) = try await GridDataAppTests.tab()
            let groups = GridToolbar.Item.viewItems + GridToolbar.Item.findItems + GridToolbar.Item.changeItems
            tab.toolbar.validate()
            for item in groups {
                let button = try #require(tab.toolbar.button(item.command), "\(item.command.title)")
                #expect(!button.isHidden, "\(item.command.title)")
                #expect(button.image != nil, "\(item.symbol)")
                #expect(button.toolTip?.isEmpty == false, "\(item.command.title)")
            }
        }

        @Test func aNarrowTabDropsButtonsRatherThanWidening() async throws {
            let (main, _, tab) = try await GridDataAppTests.tab(size: MainWindowController.minimumSize)
            main.window?.layoutIfNeeded()
            #expect(tab.toolbar.frame.maxX <= tab.view.bounds.maxX)
            #expect((main.window?.frame.width ?? 0) <= MainWindowController.minimumSize.width, "\(main.window?.frame.width ?? 0) \(tab.toolbar.frame)")
            let shown = tab.toolbar.subviews.flatMap(\.subviews).filter { !$0.isHidden }.count
            #expect(shown > 3, "\(shown)")
        }

        /// customers with a `note` cut at the server, and what reading its row back finds.
        static func cutTab() async throws -> (MainWindowController, AgentServer, TableDataController, FakeTableSession, String) {
            let session = FakeTableSession.customers()
            let whole = String(repeating: "note ", count: 400) + "end", row = session.rows[0]
            session.rows[0][3] = String(whole.prefix(1_001))
            session.edited = [row.enumerated().map { $0 == 3 ? whole : $1 }]
            let (main, harness, tab) = try await GridDataAppTests.tab("customers", session: session)
            await ready { tab.loading != nil }
            return (main, harness, tab, session, whole)
        }

        @Test func aPageCutsTheLongColumnAndLoadFullCellReadsItBack() async throws {
            let (_, harness, tab, session, whole) = try await Self.cutTab()
            let source = try #require(tab.source)
            #expect(session.statements.contains { $0.contains("LEFT(`note`, 1001)") })
            #expect(source.isCut(0, 3))
            tab.grid.selection.select(GridPosition(row: 0, column: tab.grid.columnOrder.firstIndex(of: 3) ?? 3))
            tab.viewer.toggleValuePanel(nil)
            let panel = try #require(tab.viewer.valuePanel)
            #expect(!panel.loadFullButton.isHidden && !panel.text.isEditable)
            #expect(await call(harness, "menu", ["path": "Data > Load Full Cell"]).error == nil)
            await ready { tab.loading != nil }
            #expect(source.value(0, 3) == whole && !source.isCut(0, 3))
            #expect(panel.loadFullButton.isHidden && panel.text.string == whole)
        }

        @Test func editingACutCellOpensItsWholeValue() async throws {
            let (_, _, tab, _, whole) = try await Self.cutTab()
            tab.grid.selection.select(GridPosition(row: 0, column: tab.grid.columnOrder.firstIndex(of: 3) ?? 3))
            #expect(tab.dataGrid(tab.grid, edit: 0, column: 3, typed: nil))
            await ready { tab.loading != nil }
            #expect(tab.viewer.valuePanel?.text.string == whole)
            #expect(tab.viewer.valuePanel?.text.isEditable == true)
        }

        @Test func copyingACutCellCopiesItsWholeValue() async throws {
            let (_, _, tab, _, whole) = try await Self.cutTab()
            tab.grid.selection.select(GridPosition(row: 0, column: tab.grid.columnOrder.firstIndex(of: 3) ?? 3))
            tab.viewer.copy(nil)
            await ready { tab.loading != nil }
            #expect(NSPasteboard.general.string(forType: .string)?.contains(whole) == true)
        }

        @Test func duplicatingARowWithACutCellCopiesItsWholeValue() async throws {
            let (_, _, tab, _, whole) = try await Self.cutTab()
            tab.grid.selection.selectRow(0)
            tab.duplicateRow(nil)
            await ready { tab.loading != nil }
            let insert = try #require(tab.source?.changes.state.inserts.first)
            #expect(insert.values["note"] == .text(whole))
        }

        @Test func aQuickFilterRefusesTheStartOfAValue() async throws {
            let (_, _, tab, _, _) = try await Self.cutTab()
            tab.grid.selection.select(GridPosition(row: 0, column: tab.grid.columnOrder.firstIndex(of: 3) ?? 3))
            let item = Commands.filterEquals.item()
            #expect(!tab.validateMenuItem(item))
            #expect(item.toolTip?.contains("Load Full Cell") == true)
        }

        @Test func aHiddenColumnIsntReadAndShowingItReadsTheRowsAgain() async throws {
            let session = FakeTableSession()
            let (_, _, tab) = try await GridDataAppTests.tab(session: session)
            tab.viewer.setHidden(true, columns: [4])
            tab.refresh(nil)
            await ready { tab.loading != nil }
            #expect(session.statements.last { $0.hasPrefix("SELECT") && $0.contains("LIMIT") }?.contains("`region`, `number`, NULL,") == true)
            let reads = session.statements.count
            tab.viewer.setHidden(false, columns: [4])
            await ready { tab.loading != nil }
            #expect(session.statements.count > reads)
            #expect(session.statements.last { $0.hasPrefix("SELECT") && $0.contains("LIMIT") }?.contains("`total`") == true)
        }
    }
}

/// The pager, Page Down at the end, and the tab's query.
extension AppTests {
    @MainActor @Suite struct GridPagerAppTests {
        typealias Tab = GridDataAppTests

        static func tab(rows: Int = 2_500) async throws -> (MainWindowController, AgentServer, TableDataController, FakeTableSession) {
            let session = FakeTableSession()
            session.rows = (1...1_000).map { [String($0), "7", "EU", "100", "1.00", nil] }
            let (main, harness, tab) = try await Tab.tab(session: session)
            await ready { tab.loading != nil }
            return (main, harness, tab, session)
        }

        var lastPage: (FakeTableSession) -> String? { { $0.statements.last { $0.contains(" LIMIT ") } } }

        @Test func thePagerReplacesTheRowsAndSaysWhereItIs() async throws {
            let (_, _, tab, session) = try await Self.tab()
            let source = try #require(tab.source)
            #expect(tab.pageLabel.stringValue.hasPrefix("1–1,000"))
            let previous = Commands.previousPage.item()
            #expect(!tab.validateMenuItem(previous) && previous.toolTip == "These are the first rows")
            tab.showNextPage(nil)
            await ready { tab.loading != nil }
            #expect(lastPage(session)?.hasSuffix("LIMIT 1000 OFFSET 1000") == true)
            #expect(source.firstRow == 1_000 && source.loadedRows == 1_000)
            #expect(tab.pageLabel.stringValue.hasPrefix("1,001–2,000"))
            #expect(tab.viewer.status.rows.stringValue.hasPrefix("Rows 1,001–2,000"))
            tab.loadRows(more: true)
            await ready { tab.loading != nil }
            #expect(lastPage(session)?.hasSuffix("LIMIT 1001 OFFSET 1999") == true)
            tab.refresh(nil)
            await ready { tab.loading != nil }
            #expect(source.firstRow == 1_000)  // Refresh stays on the page
            tab.showFirstPage(nil)
            await ready { tab.loading != nil }
            #expect(source.firstRow == 0)
        }

        @Test func aTableOpensNewestFirstWhenTheSettingIsOn() async throws {
            let connection = SavedConnection(name: "Local", host: "127.0.0.1", user: "app")
            let model = testModel([connection])
            model.data.settings.newestFirst = true
            let (main, _) = appWindow(model)
            let session = FakeTableSession()
            let tab = try await Tab.open(in: main, connection: connection, session: session)
            await ready { tab.loading != nil }
            #expect(lastPage(session)?.hasSuffix("ORDER BY `id` DESC LIMIT 1000") == true)
        }

        @Test func aNewFilterGoesBackToTheStart() async throws {
            let (_, _, tab, _) = try await Self.tab()
            tab.showNextPage(nil)
            await ready { tab.loading != nil }
            tab.applyFilter("id > 1")
            await ready { tab.loading != nil }
            #expect(tab.source?.firstRow == 0)
        }

        @Test func lastPageCountsFirst() async throws {
            let (_, _, tab, session) = try await Self.tab()
            tab.showLastPage(nil)
            await ready { tab.loading != nil || tab.total?.exact != true }
            await ready { tab.loading != nil }
            #expect(session.statements.contains { $0.hasPrefix("SELECT COUNT(*)") })
            #expect(tab.source?.firstRow == 0)  // the fake's 1,000 rows are one page
        }

        @Test func rowsPerPageIsTheTabsOwn() async throws {
            let (_, _, tab, session) = try await Self.tab()
            let item = NSMenuItem()
            item.tag = 500
            tab.setPageSize(item)
            await ready { tab.loading != nil }
            #expect(tab.rowsPerPage == 500)
            #expect(lastPage(session)?.hasSuffix("LIMIT 500") == true)
            let choice = Commands.pageSize.item()
            choice.tag = 500
            #expect(tab.validateMenuItem(choice) && choice.state == .on)
        }

        @Test func pageDownOnTheLastRowLoadsMore() async throws {
            let (_, _, tab, session) = try await Self.tab()
            tab.grid.selection.select(GridPosition(row: 998, column: 0))
            let reads = session.statements.count
            tab.grid.moveDown(nil)
            #expect(tab.loading != nil)
            await ready { tab.loading != nil }
            #expect(session.statements.count > reads)
            #expect(lastPage(session)?.contains("OFFSET 999") == true)
        }

        @Test func theQueryCarriesTheFilterAndTheSort() async throws {
            let (main, _, tab, _) = try await Self.tab()
            tab.applyFilter("region = 'EU'")
            await ready { tab.loading != nil }
            tab.copyTableQuery(nil)
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            #expect(text.contains("WHERE (region = 'EU'") && text.hasSuffix("LIMIT 1000;"))
            tab.openTableQuery(nil)
            #expect((main.selectedTab?.content as? ConsoleViewController)?.text == text)
        }
    }
}

/// The small commands on a grid's columns and cells.
extension AppTests {
    @MainActor @Suite struct GridCommandsAppTests {
        typealias Tab = GridDataAppTests

        @Test func hideOtherColumnsKeepsTheSelectionAndResetViewBringsThemBack() async throws {
            let session = FakeTableSession()
            let (_, _, tab) = try await Tab.tab(session: session)
            tab.grid.selection.selectColumn(2)
            tab.viewer.hideOtherColumns(nil)
            #expect(tab.grid.columnOrder == [2])
            tab.applyFilter("id > 0")
            await ready { tab.loading != nil }
            tab.resetView(nil)
            await ready { tab.loading != nil }
            #expect(tab.grid.columnOrder == Array(0..<6))
            #expect(tab.source?.filter == "" && tab.source?.hiddenColumns.isEmpty == true)
        }

        @Test func openURLIsOnlyForAWebAddress() async throws {
            let session = FakeTableSession()
            session.rows[0][2] = "https://example.com/a?b=1"
            let (_, _, tab) = try await Tab.tab(session: session)
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            #expect(tab.viewer.validateMenuItem(Commands.openURL.item()))
            tab.grid.selection.select(GridPosition(row: 1, column: 2))
            let item = Commands.openURL.item()
            #expect(!tab.viewer.validateMenuItem(item) && item.toolTip?.contains("web address") == true)
        }

        @Test func compareCellsWantsTwoCellsAndOpensTheirDifference() async throws {
            let (main, _, tab) = try await Tab.tab()
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            #expect(!tab.viewer.validateMenuItem(Commands.compareCells.item()))
            tab.grid.selection.select(GridPosition(row: 1, column: 2), add: true)
            #expect(tab.viewer.validateMenuItem(Commands.compareCells.item()))
            tab.viewer.compareCells(nil)
            #expect(main.selectedTab?.title == "Compare Cells")
        }

        @Test func anExpressionWaitsAsAPendingValue() async throws {
            let (_, _, tab) = try await Tab.tab()
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            #expect(tab.validateMenuItem(Commands.setExpression.item()))
            tab.setSelected { _ in .sql("UPPER('eu')") }
            #expect(tab.source?.cell(0, 2) == .placeholder("ƒ UPPER('eu')"))
        }

        @Test func aTypedOrderByIsCheckedOnAReadOnlyConnection() async throws {
            let (_, _, tab) = try await Tab.tab(readOnly: true)
            let source = try #require(tab.source)
            source.orderText = "(SELECT 1 FROM orders FOR UPDATE)"
            #expect(tab.refusesOnReadOnly(source))
            source.orderText = "LENGTH(region)"
            #expect(!tab.refusesOnReadOnly(source))
        }

        @Test func rowsOfSeveralLinesAreTaller() {
            let one = GridStyles(fontSize: 12), three = GridStyles(fontSize: 12, lines: 3)
            #expect(three.rowHeight == one.rowHeight + 2 * three.lineHeight && three.baseline == one.baseline)
        }

        @Test func aResultsHeaderHasFunnels() async throws {
            let (main, _) = appWindow(testModel())
            let view = ResultGridView(store: ConsoleFixtures.customers(rows: 2), nullText: "NULL", fontSize: 12)
            main.window?.contentView = view
            #expect(view.viewer.dataGridFiltersColumns(view.grid))
        }

        @Test func theExportSheetPreviewsAndChoosesASeparator() async throws {
            let (main, _, tab) = try await Tab.tab()
            tab.exportRows(nil)
            await ready { main.window?.attachedSheet == nil }
            let sheet = try #require(main.window?.attachedSheet)
            let content = try #require(sheet.contentView)
            let preview = try #require(find(NSTextField.self, id: "export.preview", in: content))
            #expect(preview.stringValue.contains("EU"))
            sheet.sheetParent?.endSheet(sheet)
        }

        @Test func anExpressionIsRefusedOnAReadOnlyConnection() async throws {
            let (_, _, tab) = try await Tab.tab(readOnly: true)
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            #expect(!tab.validateMenuItem(Commands.setExpression.item()))
        }
    }
}
