import CryptoKit
import Foundation

/// The receiver's long-term key. Prefers the Secure Enclave (the private key
/// can never leave the chip); falls back to a software key stored in Keychain.
final class ReceiverKey {
    private enum Backing {
        case enclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
        case software(P256.KeyAgreement.PrivateKey)
    }
    private let backing: Backing

    private init(_ b: Backing) { backing = b }

    static func generate(preferEnclave: Bool = true) -> ReceiverKey {
        if preferEnclave, SecureEnclave.isAvailable,
           let k = try? SecureEnclave.P256.KeyAgreement.PrivateKey() {
            return ReceiverKey(.enclave(k))
        }
        return ReceiverKey(.software(P256.KeyAgreement.PrivateKey()))
    }

    /// Serialized form for Keychain. For enclave keys this is an opaque blob
    /// that only this Mac's Secure Enclave can use.
    var serialized: Data {
        switch backing {
        case .enclave(let k): return Data([1]) + k.dataRepresentation
        case .software(let k): return Data([0]) + k.rawRepresentation
        }
    }

    convenience init?(serialized d: Data) {
        guard let tag = d.first else { return nil }
        let rest = Data(d.dropFirst())
        if tag == 1, let k = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: rest) {
            self.init(.enclave(k))
        } else if tag == 0, let k = try? P256.KeyAgreement.PrivateKey(rawRepresentation: rest) {
            self.init(.software(k))
        } else {
            return nil
        }
    }

    var isHardwareBacked: Bool {
        if case .enclave = backing { return true }
        return false
    }

    /// 65-byte uncompressed P-256 point (what WebCrypto's "raw" export uses).
    var publicKey: Data {
        switch backing {
        case .enclave(let k): return k.publicKey.x963Representation
        case .software(let k): return k.publicKey.x963Representation
        }
    }

    func sharedSecret(with pub: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        switch backing {
        case .enclave(let k): return try k.sharedSecretFromKeyAgreement(with: pub)
        case .software(let k): return try k.sharedSecretFromKeyAgreement(with: pub)
        }
    }

    /// Short human-comparable fingerprint, matches the web page's.
    var fingerprint: String { Self.fingerprint(of: publicKey) }

    static func fingerprint(of pub: Data) -> String {
        let hex = SHA256.hash(data: pub).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map {
            let s = hex.index(hex.startIndex, offsetBy: $0)
            return String(hex[s..<hex.index(s, offsetBy: 4)])
        }.joined(separator: "-")
    }
}

/// A decrypted item as sent by the web page.
struct Payload {
    /// `pair` carries the sender's own pairing link, so the receiver can send back (two-way).
    enum Kind: String { case text, file, pair }
    let kind: Kind
    let from: String
    let sentAt: Date
    let name: String?
    let mimeType: String?
    let body: Data
}

enum EnvelopeError: Error { case malformed, badHeader }

/// Envelope:  "WD1" | ephemeralPub(65) | iv(12) | ciphertext | tag(16)
/// Key:       HKDF-SHA256(ECDH(receiverPriv, ephemeralPub), salt: ephemeralPub||receiverPub, info: "pigeon v1")
/// AAD:       "WD1" | ephemeralPub
/// Plaintext: u32be(headerLen) | header JSON | body
enum Envelope {
    static let magic = Data("WD1".utf8)
    static let info = Data("pigeon v1".utf8)

    static func open(_ env: Data, with key: ReceiverKey) throws -> Payload {
        let d = Data(env) // rebase indices to 0
        guard d.count >= 3 + 65 + 12 + 16, d.prefix(3) == magic else { throw EnvelopeError.malformed }
        let eph = d.subdata(in: 3..<68)
        let iv = d.subdata(in: 68..<80)
        let ct = d.subdata(in: 80..<(d.count - 16))
        let tag = d.subdata(in: (d.count - 16)..<d.count)

        let ephPub = try P256.KeyAgreement.PublicKey(x963Representation: eph)
        let secret = try key.sharedSecret(with: ephPub)
        let sym = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: eph + key.publicKey, sharedInfo: info, outputByteCount: 32)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ct, tag: tag)
        let pt = try AES.GCM.open(box, using: sym, authenticating: magic + eph)
        return try parse(pt)
    }

    /// Encrypt to a recipient's public key (same format the web page produces).
    static func seal(header: [String: Any], body: Data, to recipientPub: Data) throws -> Data {
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: recipientPub)
        let eph = P256.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.x963Representation
        let sym = try eph.sharedSecretFromKeyAgreement(with: recipient).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: ephPub + recipientPub, sharedInfo: info, outputByteCount: 32)
        let h = try JSONSerialization.data(withJSONObject: header)
        let len = Data([UInt8(h.count >> 24 & 0xff), UInt8(h.count >> 16 & 0xff), UInt8(h.count >> 8 & 0xff), UInt8(h.count & 0xff)])
        let box = try AES.GCM.seal(len + h + body, using: sym, nonce: AES.GCM.Nonce(), authenticating: magic + ephPub)
        return magic + ephPub + box.nonce.withUnsafeBytes { Data($0) } + box.ciphertext + box.tag
    }

    private static func parse(_ pt: Data) throws -> Payload {
        guard pt.count >= 4 else { throw EnvelopeError.badHeader }
        let hlen = Int(pt[0]) << 24 | Int(pt[1]) << 16 | Int(pt[2]) << 8 | Int(pt[3])
        guard hlen > 0, hlen <= 16_384, pt.count >= 4 + hlen else { throw EnvelopeError.badHeader }
        let headerData = pt.subdata(in: 4..<(4 + hlen))
        guard let h = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let kind = Payload.Kind(rawValue: h["kind"] as? String ?? "") else { throw EnvelopeError.badHeader }
        let ts = (h["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let from = String((h["from"] as? String ?? "Unknown").prefix(40))
        return Payload(kind: kind, from: from, sentAt: ts,
                       name: h["name"] as? String, mimeType: h["type"] as? String,
                       body: pt.subdata(in: (4 + hlen)..<pt.count))
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func random(_ n: Int) -> Data {
        var d = Data(count: n)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(ok == errSecSuccess)
        return d
    }
}
