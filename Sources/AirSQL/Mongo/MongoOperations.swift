import AirSQLCore
import AppKit

/// The host page's operations (currentOp): this login's own by default, which needs no privilege; All Operations lists
/// everyone's when the login may (tried without `$ownOps`; refused, it falls back and says why). Kill Operation asks
/// first and runs killOp; it refuses the server's own work and is off on a read-only connection.
extension MongoHostContent {
    /// The operations to show, or why they couldn't be read. The first read tries everyone's, to know whether the
    /// toggle may be on.
    func readOperations(_ session: MongoSession, all wanted: Bool) async -> ([MongoHost.Operation]?, String?) {
        var found: [BSONDocument]?
        if wanted || allRefusal == nil {
            do {
                let everyone = try await session.currentOperations(all: true)
                allRefusal = .some(nil)
                if wanted { found = everyone }
            } catch let error as AirSQLError where error.kind == .accessDenied {
                allRefusal = "This login may list only its own operations: everyone's need the inprog privilege (clusterMonitor)"
                allOperations.state = .off
            } catch {
                return (nil, "Couldn't read the operations: " + error.localizedDescription)
            }
        }
        do {
            if found == nil { found = try await session.currentOperations(all: false) }
            return (MongoHost.operations(found ?? []), nil)
        } catch {
            return (nil, "Couldn't read the operations: " + error.localizedDescription)
        }
    }

    var operationsNote: String {
        (allOperations.state == .on ? "every login's" : "this login's") + " operations on the primary, read at "
            + Date().formatted(date: .omitted, time: .standard)
    }

    var selectedOperations: [MongoHost.Operation] {
        let keys = Set(operations.selected.map(\.key))
        return operationsFound.filter { keys.contains($0.id) }
    }

    /// The bar's controls, as their menu items: enabled when they can act, else saying why not.
    func updateButtons() {
        let reason = reason(Commands.killOperation.action)
        kill.isEnabled = reason == nil
        kill.toolTip = reason ?? Commands.killOperation.tip
        let refusal = allRefusal ?? nil
        allOperations.isEnabled = allRefusal != nil && refusal == nil
        allOperations.toolTip = refusal ?? (allRefusal == nil ? "Wait for the first read" : "List every login's operations, not only this login's")
    }

    /// Why a command can't act now; nil: it can.
    func reason(_ action: Selector?) -> String? {
        switch action {
        case Commands.killOperation.action?:
            if open.saved.readOnly { return "This connection is read-only: turn that off in Edit Connection… ▸ Options to kill operations" }
            if pane != .operations { return "Show the Operations first" }
            let chosen = selectedOperations
            if chosen.isEmpty { return "Select an operation first" }
            return chosen.lazy.compactMap(\.killRefusal).first
        case Commands.copy.action?:
            return currentListSelectionIsEmpty ? "Select some rows first" : nil
        default:
            return nil
        }
    }

    private var currentListSelectionIsEmpty: Bool { [figures, members, operations][pane.rawValue].selected.isEmpty }

    /// Asks, then ends the selected operations with killOp on the host page's session, and reads the list again.
    @objc func killOperation(_ sender: Any?) {
        if let reason = reason(Commands.killOperation.action) { return showError(reason, title: "Couldn't kill the operation", on: view.window) }
        guard let window = view.window else { return }
        let targets = selectedOperations
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Kill operation \(targets[0].id)?" : "Kill \(targets.count) operations?"
        alert.informativeText = "It stops at its next chance and its client gets an error. What it wrote so far stays, but a "
            + "transaction it is part of is aborted."
        let button = alert.addButton(withTitle: "Kill Operation")
        button.hasDestructiveAction = true
        button.toolTip = Commands.killOperation.tip
        alert.addButton(withTitle: "Cancel").toolTip = "Leave it running"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await self?.kill(targets) }
        }
    }

    func kill(_ targets: [MongoHost.Operation]) async {
        var problems: [String] = []
        do {
            let session = try await hostSession()
            for op in targets {
                do { try await session.killOperation(op.opid) } catch { problems.append("Operation \(op.id): " + error.localizedDescription) }
            }
        } catch {
            problems.append(error.localizedDescription)
        }
        if !problems.isEmpty { showError(problems.joined(separator: "\n"), title: "Not every operation was killed", on: view.window) }
        refresh(nil)
    }
}
