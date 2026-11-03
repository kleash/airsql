import AirSQLCore
import AppKit

/// What a connect asks the person, and the Keychain before them: the database login, the proxy's password, ssh's
/// prompts relayed by askpass (host keys, passwords, passphrases, codes) and the Trust sheet for a server certificate.
extension Connector {
    /// The database password: the Keychain's at first (none saved: none), and the person's when the server refuses it
    /// or the connection asks at each connect (then with the user name, which isn't saved either).
    func databasePassword(_ saved: inout SavedConnection, on window: NSWindow?, retry: Bool) async throws -> String {
        if !retry && !saved.askPassword { return await secret(saved.id.uuidString) ?? "" }
        guard let window else { throw AirSQLError(.authFailed, "The server didn't accept the user name or password.") }
        let name = saved.displayName, id = saved.id
        if saved.askPassword {
            let answer: (user: String, password: String)? = await withCheckedContinuation { done in
                track(id, showLoginPrompt(for: name, user: saved.user, retry: retry, on: window) { done.resume(returning: $0) })
            }
            guard let answer else { throw AirSQLError(.cancelled, "Cancelled.") }
            saved.user = answer.user
            return answer.password
        }
        let answer: (String?, Bool) = await withCheckedContinuation { done in
            track(id, showPasswordPrompt(for: name, user: saved.user, retry: true, canRemember: true, on: window) {
                done.resume(returning: ($0, $1))
            })
        }
        guard let password = answer.0 else { throw AirSQLError(.cancelled, "Cancelled.") }
        if answer.1 { remembered[id, default: [:]][id.uuidString] = password }
        return password
    }

    /// The proxy's password: none without a user, else the Keychain's or the person's.
    func proxyPassword(_ saved: SavedConnection, typed: String?, on window: NSWindow?) async throws -> String {
        guard !saved.proxy.user.isEmpty else { return "" }
        if let typed, !typed.isEmpty { return typed }
        if let stored = await secret(saved.proxySecretKey) { return stored }
        guard let window else { throw AirSQLError(.authFailed, "The proxy needs its password.") }
        let id = saved.id, key = saved.proxySecretKey
        let answer: (String?, Bool) = await withCheckedContinuation { done in
            track(id, showSSHPrompt(.password(user: saved.proxy.user, host: saved.proxy.host), text: "The proxy "
                                    + "\(saved.proxy.host) wants the password of “\(saved.proxy.user)”.", hop: nil,
                                    title: "Password for the proxy \(saved.proxy.host)", canRemember: true, retry: false,
                                    on: window) { done.resume(returning: ($0, $1)) })
        }
        guard let password = answer.0 else { throw AirSQLError(.cancelled, "Cancelled.") }
        if answer.1 { remembered[id, default: [:]][key] = password }
        return password
    }

    /// Answers ssh's prompts for `saved`: a host key with the Trust sheet; a hop's password or passphrase from the
    /// Keychain once (only to an ssh AirSQL started), else from the person, with Remember; anything else (codes) asked.
    /// Declining stops the connect.
    func sshPrompts(for saved: SavedConnection, on window: NSWindow?) -> AskpassServer.Handler {
        var tried = Set<String>(), asked = Set<String>()
        return { [weak self] request, reply in MainActor.assumeIsolated {
            guard let self, let window else { return reply(nil) }
            let id = saved.id
            @MainActor func ask(_ hop: SSHHop?, _ key: String?, retry: Bool) {
                let remember = key != nil && request.kind != .other
                self.track(id, showSSHPrompt(request.kind, text: request.prompt, hop: hop?.displayName, canRemember: remember,
                                             retry: retry, on: window) { answer, remembering in
                    reply(answer)
                    guard let answer else { return self.cancel(id) }
                    if remembering, let key { self.remembered[id, default: [:]][key] = answer }
                })
            }
            if case .hostKey(let host, let fingerprint) = request.kind {
                self.track(id, showHostKeyTrust(host: host, fingerprint: fingerprint, prompt: request.prompt, on: window) {
                    reply($0 ? "yes" : nil)
                    if !$0 { self.cancel(id) }
                })
                return
            }
            let hop = Self.hop(asking: request, in: saved), key = hop.map(saved.secretKey(for:))
            let attempt = (key ?? request.prompt) + " \(request.pid)", retry = asked.contains(attempt)
            asked.insert(attempt)
            guard let key, request.kind != .other, request.fromAirSQL, !tried.contains(key) else { return ask(hop, key, retry: retry) }
            tried.insert(key)
            Task {
                if let stored = await self.secret(key) { reply(stored) } else { ask(hop, key, retry: retry) }
            }
        } }
    }

    /// The hop a password or passphrase prompt is for: by its user@host, or its key file.
    static func hop(asking request: AskpassRequest, in saved: SavedConnection) -> SSHHop? {
        let hops = saved.sshHops
        switch request.kind {
        case .password(let user, let host?):
            return hops.first { $0.host.caseInsensitiveCompare(host) == .orderedSame && (user == nil || $0.user.isEmpty || $0.user == user) }
        case .password:
            let passwords = hops.filter { $0.login == .password }
            return passwords.count == 1 ? passwords[0] : nil
        case .passphrase:
            return hops.first { $0.login == .keyFile && !$0.keyFile.isEmpty
                && request.prompt.contains(($0.keyFile as NSString).expandingTildeInPath) }
        default:
            return nil
        }
    }

    /// Asks whether to trust a certificate macOS doesn't (or one that changed since it was pinned).
    func askTrust(_ certificate: TLSCertificate, server saved: SavedConnection, changed: Bool, on window: NSWindow) async -> Bool {
        let name = saved.host.isEmpty ? saved.displayName : saved.host, id = saved.id
        return await withCheckedContinuation { done in
            if changed {
                track(id, showChangedCertificate(server: name, certificate: certificate, on: window) { done.resume(returning: $0) })
            } else {
                track(id, showTrust(server: name, fingerprint: certificate.fingerprint, details: certificateDetails(certificate),
                                    on: window) { done.resume(returning: $0) })
            }
        }
    }

    /// A Keychain secret, read off the main thread (a locked keychain may wait for the person).
    func secret(_ key: String) async -> String? {
        let read = model.savedPassword
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: read(key)) }
        }
    }

    /// Saves the answers the person asked to remember, now that they worked.
    func saveRemembered(_ id: UUID) {
        guard let answers = remembered.removeValue(forKey: id) else { return }
        let write = model.setSavedPassword
        DispatchQueue.global(qos: .userInitiated).async {
            for (key, secret) in answers { write(key, secret) }
        }
    }

    /// Keeps a prompt shown for `id`, so a cancelled or failed connect closes it.
    func track(_ id: UUID, _ alert: NSAlert) {
        sheets[id, default: []].append(alert.window)
    }

    /// Closes the prompts still shown for `id`.
    func closePrompts(_ id: UUID) {
        for sheet in sheets.removeValue(forKey: id) ?? [] where sheet.isVisible {
            sheet.sheetParent?.endSheet(sheet, returnCode: .abort)
        }
    }

    /// Says why connecting failed, with ssh's or the server's own last words.
    func showConnectError(_ error: AirSQLError, connection: String, on window: NSWindow?) {
        let details = error.details.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
        showError(error.message + (details.isEmpty ? "" : "\n\n" + details), title: "Can't connect to “\(connection)”", on: window)
    }
}
