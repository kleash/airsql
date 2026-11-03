import AirSQLCore
import AppKit

// `AirSQL --version` prints AirSQL's version and its client library's, and opens no window (CI runs it to check that the
// app finds the libmariadb in its bundle).
if CommandLine.arguments.dropFirst().first == "--version" {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(not bundled)"
    print("AirSQL \(version), MariaDB Connector/C \(MariaDB.clientVersion)")
    exit(0)
}

// ssh runs AirSQL as its askpass program (`SSH_ASKPASS`, with AIRSQL_ASKPASS_SOCK set): the prompt goes to the running
// AirSQL, which asks the person or answers from the Keychain, and the answer is printed for ssh.
if Env.value("ASKPASS_SOCK") != nil, CommandLine.arguments.count > 1 {
    exit(Askpass.runHelper(prompt: CommandLine.arguments[1]))
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
