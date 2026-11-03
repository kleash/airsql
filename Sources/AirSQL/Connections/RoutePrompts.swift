// showSSHPrompt and the host key sheet follow AirSCP 1.4.0 Sources/AirSCP/Prompts.swift (showPrompt).
import AirSQLCore
import AppKit

/// Asks an ssh prompt relayed by askpass (a password, a passphrase, a code) in an alert sheet: a secure field, with
/// "Remember in Keychain" when `canRemember`. `hop` names the SSH host it is for; `title` replaces the alert's own;
/// `retry`: the same ssh asks again, so the last answer was wrong. `reply` gets the answer (nil: Cancel) and Remember.
@MainActor @discardableResult
func showSSHPrompt(_ kind: PromptKind, text: String, hop: String?, title: String? = nil, canRemember: Bool, retry: Bool,
                   on window: NSWindow, reply: @escaping (_ answer: String?, _ remember: Bool) -> Void) -> NSAlert {
    let alert = NSAlert()
    let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch kind {
    case .password(let user, let host):
        let name = hop ?? [user, host].compactMap { $0 }.joined(separator: "@")
        alert.messageText = name.isEmpty ? "SSH password" : "SSH password for \(name)"
    case .passphrase:
        alert.messageText = "Passphrase of the key for \(hop ?? "SSH")"
    default:
        alert.messageText = "\(hop ?? "The SSH host") asks"
    }
    alert.informativeText = asked
    if let title { alert.messageText = title }
    if retry {  // the same question again: say so, or it looks as if nothing happened
        let what = kind == .passphrase ? "passphrase" : kind == .other ? "answer" : "password"
        alert.informativeText = "That \(what) wasn't accepted. Try again." + (asked.isEmpty ? "" : "\n" + asked)
    }
    let field = NSSecureTextField(frame: NSRect(x: 0, y: canRemember ? 28 : 0, width: 300, height: 22))
    field.placeholderString = kind == .passphrase ? "Passphrase" : kind == .other ? "Answer" : "Password"
    field.toolTip = "Type the answer: it goes to the server that asked only, never into a log or a command line"
    field.setAccessibilityIdentifier("prompt.answer")
    let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
    remember.toolTip = "Save it in your Keychain once the connection works, so the next connect doesn't ask"
    remember.setAccessibilityIdentifier("prompt.remember")
    remember.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: canRemember ? 50 : 22))
    accessory.addSubview(field)
    if canRemember { accessory.addSubview(remember) }
    alert.accessoryView = accessory
    alert.addButton(withTitle: "OK").toolTip = "Send the answer to the server that asked"
    alert.addButton(withTitle: "Cancel").toolTip = "Don't answer: connecting stops"
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
        reply(response == .alertFirstButtonReturn ? field.stringValue : nil,
              canRemember && remember.state == .on && !AgentGuard.refuses("Only the person at the Mac can save a password: it was used for this login only."))
    }
    return alert
}

/// Asks whether to trust an SSH host's key that ssh hasn't seen before: Trust makes ssh remember it in known_hosts.
@MainActor @discardableResult
func showHostKeyTrust(host: String, fingerprint: String, prompt: String, on window: NSWindow,
                      reply: @escaping (Bool) -> Void) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Trust the SSH host “\(host.isEmpty ? "unknown" : host)”?"
    alert.informativeText = "AirSQL hasn't connected to this SSH host before. If this key fingerprint is the one its "
        + "administrator gave you, trust it: ssh then remembers the key (in known_hosts) and warns if it ever changes."
    let type = prompt.components(separatedBy: "\n").first { $0.contains(" key fingerprint is ") }?
        .components(separatedBy: " key fingerprint is ").first
    alert.accessoryView = fingerprintView((type.map { "\($0) key fingerprint:\n" } ?? "Key fingerprint:\n")
                                          + (fingerprint.isEmpty ? prompt : fingerprint))
    alert.addButton(withTitle: "Trust").toolTip = "Remember this key and connect"
    alert.addButton(withTitle: "Cancel").toolTip = "Don't connect"
    addHelp(to: alert, .trust)
    // Trust is the person's (the agents' gate, plan §2.8): an agent's Trust is a Cancel.
    alert.beginSheetModal(for: window) { reply($0 == .alertFirstButtonReturn && !AgentGuard.refuses("Only the person at the Mac can trust a certificate or host key: nothing was trusted.")) }
    return alert
}

/// Warns that a server shows another certificate than the one pinned for the connection; trusting pins the new one.
@MainActor @discardableResult
func showChangedCertificate(server: String, certificate: TLSCertificate, on window: NSWindow,
                            reply: @escaping (Bool) -> Void) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "The certificate of “\(server)” has changed"
    alert.informativeText = "This server shows another certificate than the one you trusted. Someone may be intercepting "
        + "the connection, or the server got a new certificate. Trust the new one only if its administrator told you it "
        + "changed and this fingerprint matches."
    alert.accessoryView = fingerprintView("New SHA-256 fingerprint:\n" + certificate.fingerprint
                                          + "\n\n" + certificateDetails(certificate).joined(separator: "\n"))
    let trust = alert.addButton(withTitle: "Trust the New Certificate")
    trust.toolTip = "Remember the new certificate instead of the old one and connect"
    trust.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel").toolTip = "Don't connect"
    alert.buttons[1].keyEquivalent = "\r"  // the safe answer is the default
    trust.keyEquivalent = ""
    addHelp(to: alert, .trust)
    // Trust is the person's (the agents' gate, plan §2.8): an agent's Trust is a Cancel.
    alert.beginSheetModal(for: window) { reply($0 == .alertFirstButtonReturn && !AgentGuard.refuses("Only the person at the Mac can trust a certificate or host key: nothing was trusted.")) }
    return alert
}

/// Asks for the user name and password of a connection that asks at each connect; neither is saved.
@MainActor @discardableResult
func showLoginPrompt(for connection: String, user: String, retry: Bool, on window: NSWindow,
                     reply: @escaping ((user: String, password: String)?) -> Void) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Log in to “\(connection)”"
    alert.informativeText = retry ? "The server didn't accept that user name or password. Try again."
        : "Type the database user and password. AirSQL keeps them until you disconnect and never saves them."
    let userField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 22))
    userField.stringValue = user
    userField.placeholderString = "User"
    userField.toolTip = "Type the database user to log in as"
    userField.setAccessibilityIdentifier("login.user")
    let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
    passwordField.placeholderString = "Password"
    passwordField.toolTip = "Type the password: it goes to the server only, never into a log or a command line"
    passwordField.setAccessibilityIdentifier("login.password")
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
    accessory.addSubview(userField)
    accessory.addSubview(passwordField)
    alert.accessoryView = accessory
    alert.addButton(withTitle: "Connect").toolTip = "Log in with this user and password"
    alert.addButton(withTitle: "Cancel").toolTip = "Don't connect"
    alert.window.initialFirstResponder = user.isEmpty ? userField : passwordField
    userField.nextKeyView = passwordField
    alert.beginSheetModal(for: window) { response in
        reply(response == .alertFirstButtonReturn ? (userField.stringValue, passwordField.stringValue) : nil)
    }
    return alert
}

/// What a certificate says about itself, for the Trust sheet: whom it is for and by whom, and when it is valid.
func certificateDetails(_ certificate: TLSCertificate) -> [String] {
    guard let secCertificate = SecCertificateCreateWithData(nil, certificate.data as CFData) else { return [certificate.summary] }
    let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
    let values = SecCertificateCopyValues(secCertificate, keys, nil) as? [String: [String: Any]] ?? [:]
    func value(_ key: CFString) -> Any? { values[key as String]?[kSecPropertyKeyValue as String] }
    let issuer = (value(kSecOIDX509V1IssuerName) as? [[String: Any]])?
        .first { $0[kSecPropertyKeyLabel as String] as? String == (kSecOIDCommonName as String) }?[kSecPropertyKeyValue as String] as? String
    func date(_ key: CFString) -> String? {
        (value(key) as? NSNumber).map {
            DateFormatter.localizedString(from: Date(timeIntervalSinceReferenceDate: $0.doubleValue), dateStyle: .medium, timeStyle: .none)
        }
    }
    var lines = ["Issued to " + (certificate.summary.isEmpty ? "an unnamed server" : certificate.summary)
                 + (issuer.map { " by " + $0 } ?? "")]
    if let from = date(kSecOIDX509V1ValidityNotBefore), let until = date(kSecOIDX509V1ValidityNotAfter) {
        lines.append("Valid from \(from) until \(until)")
    }
    return lines
}

/// A fingerprint as the Trust sheets show it: monospaced, selectable, wrapping within the alert.
@MainActor
private func fingerprintView(_ text: String) -> NSView {
    let field = label(text, font: .monospacedSystemFont(ofSize: 11, weight: .regular), wraps: true)
    field.isSelectable = true
    field.setAccessibilityIdentifier("trust.fingerprint")
    field.preferredMaxLayoutWidth = 300
    field.translatesAutoresizingMaskIntoConstraints = true
    field.frame.size = NSSize(width: 300, height: field.fittingSize.height)
    return field
}
