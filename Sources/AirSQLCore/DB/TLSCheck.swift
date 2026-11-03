import CMariaDB
import CryptoKit
import Foundation
import Security

/// A connection's TLS settings.
public struct TLSOptions: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// No TLS (a server on this Mac, or a network you trust end to end).
        case off
        /// Encrypted, but the certificate isn't checked: anyone in between can read along. Pinning is better.
        case required
        /// Encrypted, with a certificate from an authority this Mac (or `caFile`) trusts, whatever name it is for.
        case verifyCA
        /// Encrypted, with a trusted certificate for the database's host name as typed in the connection.
        case verifyIdentity
    }

    public var mode: Mode
    /// PEM certificates of the authorities that sign private servers' certificates, trusted besides the Mac's own.
    public var caFile: String?
    /// The client certificate and its key (PEM), for servers that ask for one (REQUIRE X509).
    public var certFile: String?
    public var keyFile: String?
    /// The SHA-256 fingerprint ("AB:CD:…") of the certificate the person trusted in the Trust sheet: the server must show
    /// exactly that certificate, and no other check applies.
    public var pinnedFingerprint: String?

    public init(mode: Mode = .verifyIdentity, caFile: String? = nil, certFile: String? = nil, keyFile: String? = nil,
                pinnedFingerprint: String? = nil) {
        self.mode = mode
        self.caFile = caFile
        self.certFile = certFile
        self.keyFile = keyFile
        self.pinnedFingerprint = pinnedFingerprint
    }

    /// Whether the server's identity is proven (by the Mac's trust or a pin), which a login that sends the password as
    /// plain text needs.
    var verified: Bool { pinnedFingerprint != nil || mode == .verifyCA || mode == .verifyIdentity }
}

/// A server's certificate, as the Trust sheet shows it.
public struct TLSCertificate: Equatable, Sendable {
    /// DER.
    public var data: Data
    /// SHA-256 of `data`, "AB:CD:…": what `TLSOptions.pinnedFingerprint` keeps (MARIADB_OPT_TLS_PEER_FP reads it too).
    public var fingerprint: String
    /// Whom it is for, as macOS sums it up (usually the common name).
    public var summary: String

    init(_ data: Data, _ certificate: SecCertificate) {
        self.data = data
        fingerprint = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
        summary = SecCertificateCopySubjectSummary(certificate) as String? ?? ""
    }

    /// `fingerprint` compared without colons or case.
    static func sameFingerprint(_ a: String, _ b: String) -> Bool {
        func plain(_ text: String) -> String { text.replacingOccurrences(of: ":", with: "").lowercased() }
        return plain(a) == plain(b)
    }
}

/// Checks the server's certificate the macOS way (plan §2.2, R2): with `SecTrust` (the Mac's trusted roots and the
/// user's trust settings, plus `TLSOptions.caFile`) against the database's real host name as typed, not the address
/// AirSQL connects to (a route's local socket), or against the pinned fingerprint. Connector/C 3.4 calls it right after
/// the TLS handshake through MARIADB_OPT_TLS_VERIFICATION_CALLBACK, before any login data is sent, on the thread that
/// connects; the handshake itself never fails on the certificate (its OpenSSL trusts nothing: OPENSSLDIR is empty).
final class TLSCheck {
    let host: String
    let options: TLSOptions
    let mysql: UnsafeMutablePointer<MYSQL>
    /// The server's certificate, once the handshake showed it.
    private(set) var certificate: TLSCertificate?
    /// Why the check failed: the connect's error, in place of Connector/C's.
    private(set) var failure: AirSQLError?

    init(host: String, options: TLSOptions, mysql: UnsafeMutablePointer<MYSQL>) {
        self.host = host
        self.options = options
        self.mysql = mysql
    }

    /// The check of the connect running on this thread.
    static var current: TLSCheck? {
        get { Thread.current.threadDictionary[key] as? TLSCheck }
        set { Thread.current.threadDictionary[key] = newValue }
    }
    private static let key = "AirSQL.TLSCheck"

    /// What Connector/C calls (int (*)(MARIADB_TLS *, unsigned int flags)); the flags are its own idea of what to check.
    static let callback: @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Int32 = { tls, _ in
        guard let check = current else { return 1 }
        let passed = check.verify(peerCertificates(tls))
        // Connector/C goes on to its own password-based check (MariaDB 11.4's) unless the status is cleared, and fails
        // the connect for a status above HOST|TRUST.
        check.mysql.pointee.net.tls_verify_status = passed ? 0 : UInt8(MARIADB_TLS_VERIFY_ERROR)
        return passed ? 0 : 1
    }

    /// The certificates the server sent (DER), its own first.
    static func peerCertificates(_ tls: UnsafeMutableRawPointer?) -> [Data] {
        // MARIADB_TLS (ma_tls.h): { void *data; MARIADB_PVIO *pvio; void *ssl; … }; ssl is OpenSSL's SSL.
        guard let tls, let ssl = tls.load(fromByteOffset: 2 * MemoryLayout<UnsafeRawPointer>.stride, as: OpaquePointer?.self),
              let stack = SSL_get_peer_cert_chain(ssl) else { return [] }
        return (0..<OPENSSL_sk_num(stack)).compactMap { index in
            let x509 = OpaquePointer(OPENSSL_sk_value(stack, index))
            let length = i2d_X509(x509, nil)
            guard length > 0 else { return nil }
            var data = Data(count: Int(length))
            data.withUnsafeMutableBytes { buffer in
                var out = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                _ = i2d_X509(x509, &out)
            }
            return data
        }
    }

    /// True when the connection may go on.
    func verify(_ chain: [Data]) -> Bool {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard let leaf = certificates.first, certificates.count == chain.count else {
            failure = AirSQLError(.tls, "The server sent no usable certificate.")
            return false
        }
        let certificate = TLSCertificate(chain[0], leaf)
        self.certificate = certificate
        if let pin = options.pinnedFingerprint {
            guard TLSCertificate.sameFingerprint(pin, certificate.fingerprint) else {
                failure = AirSQLError(.certificateChanged(certificate),
                                      "The server's certificate isn't the one you trusted for this connection. Someone may "
                                      + "be intercepting the connection, or the server got a new certificate. Only trust "
                                      + "the new one if you know why it changed.",
                                      details: "Trusted: \(pin)\nShown: \(certificate.fingerprint)")
                return false
            }
            return true
        }
        guard options.mode != .required else { return true }

        let policy = SecPolicyCreateSSL(true, options.mode == .verifyIdentity ? host as CFString : nil)
        var made: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &made) == errSecSuccess, let trust = made else {
            failure = AirSQLError(.tls, "AirSQL couldn't check the server's certificate.")
            return false
        }
        if let caFile = options.caFile {
            guard let authorities = Self.certificates(inPEM: caFile), !authorities.isEmpty else {
                failure = AirSQLError(.tls, "Can't read certificates from the CA file \(caFile).")
                return false
            }
            SecTrustSetAnchorCertificates(trust, authorities as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)  // and the Mac's own
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return true }
        let reason: String
        switch error.map({ CFErrorGetCode($0) }).map(OSStatus.init) {
        case errSecHostNameMismatch:
            reason = "The certificate is for “\(certificate.summary)”, not for “\(host)”."
        case errSecCertificateExpired:
            reason = "The certificate has expired."
        case errSecCertificateNotValidYet:
            reason = "The certificate isn't valid yet. Check the date on this Mac."
        default:
            reason = "The certificate isn't signed by an authority this Mac trusts."
        }
        failure = AirSQLError(.untrustedCertificate(certificate),
                              reason + " Check its fingerprint with the server's administrator before you trust it.",
                              details: (error.map { CFErrorCopyDescription($0) as String } ?? "")
                                + "\nSHA-256 fingerprint: \(certificate.fingerprint)")
        return false
    }

    /// The certificates in a PEM file, nil if it can't be read.
    static func certificates(inPEM path: String) -> [SecCertificate]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        return text.components(separatedBy: begin).dropFirst().compactMap { block in
            guard let body = block.components(separatedBy: end).first,
                  let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
            return SecCertificateCreateWithData(nil, data as CFData)
        }
    }
}
