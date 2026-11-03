import Foundation

/// The questions a dialog login asks after the password (PAM's one-time codes, an LDAP prompt). Connector/C's dialog
/// plugin answers the first password question with the connection's password, then looks up `mariadb_auth_dialog` by
/// name and calls it, on the session's thread, for each further question.
public enum LoginDialog {
    /// Asks the person `prompt` and waits for the answer (`secret`: a password or a code, hidden as it is typed); nil
    /// gives up the login. The app sets it; it is called off the main thread.
    public static var ask: ((_ prompt: String, _ secret: Bool) -> String?)?

    /// The function Connector/C finds by name, referenced here so the linker keeps it in the app.
    public static let function: @convention(c) (OpaquePointer?, Int32, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?,
                                                Int32) -> UnsafeMutablePointer<CChar>? = mariadbAuthDialog
}

/// Connector/C's dialog callback (`mysql_authentication_dialog_ask_t`): `type` 2 is a password, 1 a question shown as
/// typed. The answer goes into `buffer`, cut to its `length`.
@_cdecl("mariadb_auth_dialog")
public func mariadbAuthDialog(_ mysql: OpaquePointer?, _ type: Int32, _ prompt: UnsafePointer<CChar>?,
                              _ buffer: UnsafeMutablePointer<CChar>?, _ length: Int32) -> UnsafeMutablePointer<CChar>? {
    guard let buffer, length > 1, let answer = LoginDialog.ask?(prompt.map { String(cString: $0) } ?? "", type == 2) else {
        return nil
    }
    let bytes = Array(answer.utf8.prefix(Int(length) - 1))
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return buffer
}
