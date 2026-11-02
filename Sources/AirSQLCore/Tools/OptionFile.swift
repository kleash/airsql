import Darwin
import Foundation

/// The client tools' private files (plan §2.9): option files holding a login, and Terminal's scripts, in a folder only
/// this user can open, each removed once its tool has read it, and anything left over removed at the next launch.
public enum OptionFile {
    /// Application Support/AirSQL/ClientTools (0700).
    public static var folder: URL { Store.directory.appendingPathComponent("ClientTools", isDirectory: true) }

    /// Writes a new option file only this user can read (0600) with the login in [client]: the user and the password.
    /// File work: off the main thread.
    public static func write(user: String, password: String, in folder: URL = folder) throws -> URL {
        let text = "[client]\nuser=\(value(user))\npassword=\(value(password))\n"
        return try create(Data(text.utf8), named: UUID().uuidString + ".cnf", mode: 0o600, in: folder)
    }

    /// Creates `name` in `folder` (made private first) with `data`, failing if it exists or is a link.
    public static func create(_ data: Data, named name: String, mode: mode_t, in folder: URL = folder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(folder.path, 0o700) == 0 else { throw posixError("Can't protect \(folder.path)") }
        let url = folder.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw posixError("Can't create a private file in \(folder.path)") }
        defer { close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fchmod(fd, mode) == 0 else {
            unlink(url.path)
            throw posixError("Can't write a private file in \(folder.path)")
        }
        return url
    }

    /// Removes what runs that ended with the app left behind (at launch). File work.
    public static func removeLeftovers(in folder: URL = folder) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// `text` as an option file value the tools read back exactly: in double quotes (so # and spaces at the ends stay),
    /// with \\, \", \n, \r and \t escaped.
    static func value(_ text: String) -> String {
        var out = "\""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\r\n": out += "\\r\\n"
            default: out.append(character)
            }
        }
        return out + "\""
    }

    private static func posixError(_ message: String) -> AirSQLError {
        AirSQLError(.other, message + ": " + String(cString: strerror(errno)))
    }
}
