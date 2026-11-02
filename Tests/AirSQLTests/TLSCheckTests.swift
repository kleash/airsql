import CMariaDB
import Foundation
import Security
import Testing
@testable import AirSQLCore

/// A throwaway certificate authority and server certificates, made with macOS's openssl in a temporary folder: what
/// TLSCheck sees from a private server. `DBLabTests` checks the same against real servers.
final class TestCertificates {
    let dir: URL
    var caFile: String { dir.appendingPathComponent("ca.pem").path }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("ca.cnf", """
            [req]
            distinguished_name = dn
            prompt = no
            [dn]
            CN = AirSQL Test CA
            [ca]
            basicConstraints = critical, CA:TRUE
            keyUsage = critical, keyCertSign, cRLSign
            subjectKeyIdentifier = hash
            """)
        try openssl("req", "-x509", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "30",
                    "-sha256", "-config", "ca.cnf", "-extensions", "ca")
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// A certificate for `name` signed by the authority (DER).
    func server(_ name: String) throws -> Data {
        try write("\(name).ext", """
            basicConstraints = critical, CA:FALSE
            keyUsage = critical, digitalSignature, keyEncipherment
            extendedKeyUsage = serverAuth
            subjectAltName = DNS:\(name)
            """)
        try openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "\(name).key", "-out", "\(name).csr", "-subj", "/CN=\(name)")
        try openssl("x509", "-req", "-in", "\(name).csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "\(name).pem",
                    "-days", "30", "-sha256", "-extfile", "\(name).ext")
        let certificate = try #require(TLSCheck.certificates(inPEM: dir.appendingPathComponent("\(name).pem").path)?.first)
        return SecCertificateCopyData(certificate) as Data
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func openssl(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "openssl \(arguments.joined(separator: " "))")
    }
}

@Suite(.serialized)
final class TLSCheckTests {
    let certificates: TestCertificates
    let mysql = mysql_init(nil)!

    init() throws {
        certificates = try TestCertificates()
    }

    deinit { mysql_close(mysql) }

    func check(_ host: String, _ options: TLSOptions, _ chain: [Data]) -> (passed: Bool, failure: AirSQLError?, check: TLSCheck) {
        let check = TLSCheck(host: host, options: options, mysql: mysql)
        let passed = check.verify(chain)
        return (passed, check.failure, check)
    }

    @Test func checksTheRealHostName() throws {
        let leaf = try certificates.server("db.airsql.test")
        let options = TLSOptions(mode: .verifyIdentity, caFile: certificates.caFile)
        #expect(check("db.airsql.test", options, [leaf]).passed)

        let wrong = check("other.airsql.test", options, [leaf])
        #expect(!wrong.passed)
        guard case .untrustedCertificate(let certificate)? = wrong.failure?.kind else {
            Issue.record("expected an untrusted certificate, got \(String(describing: wrong.failure))")
            return
        }
        #expect(certificate.summary == "db.airsql.test")
        #expect(wrong.failure?.message.contains("not for “other.airsql.test”") == true)
        #expect(certificate.fingerprint.count == 95)
    }

    @Test func trustsOnlyKnownAuthorities() throws {
        let leaf = try certificates.server("db.airsql.test")
        let result = check("db.airsql.test", TLSOptions(mode: .verifyIdentity), [leaf])
        #expect(!result.passed)
        #expect(result.failure?.message.hasPrefix("The certificate isn't signed by an authority this Mac trusts.") == true)
        // The CA without the name check; and encryption only.
        #expect(check("other.airsql.test", TLSOptions(mode: .verifyCA, caFile: certificates.caFile), [leaf]).passed)
        #expect(check("other.airsql.test", TLSOptions(mode: .required), [leaf]).passed)
    }

    @Test func aPinnedCertificateIsTheOnlyOneAccepted() throws {
        let leaf = try certificates.server("db.airsql.test")
        let fingerprint = try #require(check("x", TLSOptions(mode: .required), [leaf]).check.certificate?.fingerprint)
        // Pinned: no authority, any name.
        #expect(check("10.0.0.9", TLSOptions(mode: .verifyIdentity, pinnedFingerprint: fingerprint.lowercased()), [leaf]).passed)

        let other = try certificates.server("db2.airsql.test")
        let changed = check("db.airsql.test", TLSOptions(mode: .verifyIdentity, caFile: certificates.caFile,
                                                        pinnedFingerprint: fingerprint), [other])
        #expect(!changed.passed)
        guard case .certificateChanged? = changed.failure?.kind else {
            Issue.record("expected a changed certificate, got \(String(describing: changed.failure))")
            return
        }
    }

    @Test func aMissingCAFileOrCertificateFails() throws {
        let leaf = try certificates.server("db.airsql.test")
        let missing = check("db.airsql.test", TLSOptions(mode: .verifyIdentity, caFile: "/nonexistent/ca.pem"), [leaf])
        #expect(!missing.passed && missing.failure?.kind == .tls)
        let none = check("db.airsql.test", TLSOptions(mode: .required), [])
        #expect(!none.passed && none.failure?.kind == .tls)
    }
}
