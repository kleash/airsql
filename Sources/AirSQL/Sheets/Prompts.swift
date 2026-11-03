// Ported from AirSCP 1.4.0 Sources/AirSCP/Prompts.swift (the prompt and Trust alerts, errors, addOK).
import AirSQLCore
import AppKit

/// Asks whether to trust a server's TLS certificate that macOS doesn't (self-signed, or from a private certificate
/// authority): its SHA-256 fingerprint to compare, and what the certificate says (`details`: subject, issuer, dates).
/// Trust pins the fingerprint (plan §2.2). `reply` gets true for Trust.
@MainActor @discardableResult
func showTrust(server: String, fingerprint: String, details: [String], on window: NSWindow,
               reply: @escaping (Bool) -> Void) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Trust the certificate of “\(server)”?"
    alert.informativeText = "macOS doesn't trust this server's certificate: it is self-signed or from a private certificate "
        + "authority. If this fingerprint is the one its administrator gave you, trust it: AirSQL then remembers it and "
        + "warns if it ever changes."
    let fingerprintText = label("SHA-256 fingerprint:\n" + fingerprint, font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                wraps: true)
    fingerprintText.isSelectable = true
    fingerprintText.setAccessibilityIdentifier("trust.fingerprint")
    var views = [fingerprintText]
    for line in details {
        let text = label(line, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, wraps: true)
        text.isSelectable = true
        views.append(text)
    }
    alert.accessoryView = alertText(views, width: 286)
    alert.addButton(withTitle: "Trust").toolTip = "Remember this certificate and connect"
    alert.addButton(withTitle: "Cancel").toolTip = "Don't connect"
    addHelp(to: alert, .trust)
    // Trust is the person's (the agents' gate, plan §2.8): an agent's Trust is a Cancel.
    alert.beginSheetModal(for: window) { response in
        reply(response == .alertFirstButtonReturn && !AgentGuard.refuses("Only the person at the Mac can trust a certificate or host key: nothing was trusted."))
    }
    return alert
}

/// Asks for a connection's password (asked at each connect, or after the server refused it): a secure field, and
/// "Remember in Keychain" when `canRemember`. `reply` gets the password (nil for Cancel) and whether to remember it.
@MainActor @discardableResult
func showPasswordPrompt(for connection: String, user: String, retry: Bool, canRemember: Bool, on window: NSWindow,
                        reply: @escaping (_ password: String?, _ remember: Bool) -> Void) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Password for “\(connection)”"
    let who = user.isEmpty ? "the database user" : "the database user “\(user)”"
    alert.informativeText = retry ? "The server didn't accept that password for \(who). Try again." : "Type the password of \(who)."
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
    field.placeholderString = "Password"
    field.toolTip = "Type the password: it goes to the server only, never into a log or a command line"
    field.setAccessibilityIdentifier("password.field")
    let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
    remember.toolTip = "Save it in your Keychain so the next connect doesn't ask (off by default)"
    remember.setAccessibilityIdentifier("password.remember")
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: canRemember ? 50 : 22))
    field.frame.origin.y = canRemember ? 28 : 0
    accessory.addSubview(field)
    if canRemember {
        remember.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        accessory.addSubview(remember)
    }
    alert.accessoryView = accessory
    alert.addButton(withTitle: "Connect").toolTip = "Log in with this password"
    alert.addButton(withTitle: "Cancel").toolTip = "Don't connect"
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
        reply(response == .alertFirstButtonReturn ? field.stringValue : nil,
              canRemember && remember.state == .on && !AgentGuard.refuses("Only the person at the Mac can save a password: it was used for this login only."))
    }
    return alert
}

/// Text under an alert's message, its letters in line with the message's: AppKit puts an accessory 4 points left of the
/// alert's text (room for fields' bezels), and a label's letters start 2 points into its frame.
@MainActor
func alertText(_ lines: [NSTextField], width: CGFloat) -> NSView {
    let stack = NSStackView(views: lines)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
    for line in lines { line.preferredMaxLayoutWidth = width - 6 }
    stack.widthAnchor.constraint(equalToConstant: width).isActive = true  // short lines too: AppKit centres a narrower one
    stack.frame.size = NSSize(width: width, height: stack.fittingSize.height)
    return stack
}

/// An alert for an error: what failed (`title`) and the message in plain words.
@MainActor
func showError(_ message: String, title: String, on window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addOK()
    log.error("\(title, privacy: .public): \(message, privacy: .public)")
    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}

extension NSAlert {
    /// The OK button of an alert that only says something.
    func addOK() {
        addButton(withTitle: "OK").toolTip = "Close this message"
    }
}

/// Adds the alert's "?" button, which opens `page` of AirSQL Help. Call it last: after the buttons and the accessory.
@MainActor
func addHelp(to alert: NSAlert, _ page: HelpPage) {
    alert.showsHelp = true
    alert.helpAnchor = page.rawValue
    alert.delegate = AlertHelp.shared
    alert.layout()  // makes the button now, to give it a tooltip and an id like the sheets' "?"
    func buttons(in view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) } }
    for button in buttons(in: alert.window.contentView ?? NSView()) where button.bezelStyle == .helpButton {
        button.toolTip = "Open the page of AirSQL Help about this, in your browser"
        button.setAccessibilityIdentifier("help")
    }
}

/// Opens an alert's help page (its "?" button).
final class AlertHelp: NSObject, NSAlertDelegate {
    static let shared = AlertHelp()

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        NSWorkspace.shared.open(HelpPage(rawValue: alert.helpAnchor ?? "")?.url ?? HelpPage.site)
        return true
    }
}
