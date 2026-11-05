import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The row of actions over a grid.
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
    }
}
