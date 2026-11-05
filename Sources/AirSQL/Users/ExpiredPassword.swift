import AirSQLCore
import AppKit

extension Connector {
    /// The login's password has expired: asks for a new one and changes it, then the connect goes on with it. Read-only,
    /// Production and agents get `error`, as for any write to accounts. It isn't saved: the Keychain's stays until the
    /// person changes it, and the next connect asks.
    func changeExpiredPassword(_ saved: SavedConnection, _ password: String, routeSocket: String?, on window: NSWindow?,
                               _ error: AirSQLError) async throws -> String {
        guard saved.usersRefusal == nil, let window else { throw error }
        var note = "The server wants a new password for “\(saved.user)” before it allows anything else."
        var new: String?
        while new == nil {
            let words = note
            let answer: (String, String)? = await withCheckedContinuation { done in
                track(saved.id, showExpiredPasswordPrompt(for: saved.displayName, note: words, on: window) { done.resume(returning: $0) })
            }
            guard let answer else { throw AirSQLError(.cancelled, "Cancelled.") }
            if !answer.0.isEmpty, answer.0 == answer.1 { new = answer.0 } else { note = "The two passwords weren't the same. Type them again." }
        }
        var options = saved.connectOptions(password: password, routeSocket: routeSocket)
        options.newPassword = new
        let session = DBConnection(options: options, role: .tools)
        defer { Task { await session.close() } }
        do {
            _ = try await session.connect()
        } catch {
            throw AirSQLError(.authFailed, UserSQL.errorText(error, hiding: new))
        }
        return new ?? password
    }
}

/// Asks for a new password twice. `reply` gets both, or nil for Cancel.
@MainActor @discardableResult
func showExpiredPasswordPrompt(for connection: String, note: String, on window: NSWindow, reply: @escaping ((String, String)?) -> Void) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "The password of “\(connection)” has expired"
    alert.informativeText = note + " It goes to the server only; update a saved password yourself in the connection's settings."
    func secure(_ y: CGFloat, _ placeholder: String, id: String, tip: String) -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: y, width: 300, height: 22))
        field.placeholderString = placeholder
        field.toolTip = tip
        field.setAccessibilityIdentifier(id)
        return field
    }
    let first = secure(30, "New password", id: "password.new", tip: "Type the new password: it goes to the server only, never into a log")
    let second = secure(0, "New password again", id: "password.repeat", tip: "Type it again, to catch a slip")
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
    accessory.addSubview(first)
    accessory.addSubview(second)
    alert.accessoryView = accessory
    alert.addButton(withTitle: "Change").toolTip = "Change the password on the server and connect"
    alert.addButton(withTitle: "Cancel").toolTip = "Don't connect"
    alert.window.initialFirstResponder = first
    alert.beginSheetModal(for: window) { reply($0 == .alertFirstButtonReturn ? (first.stringValue, second.stringValue) : nil) }
    return alert
}
