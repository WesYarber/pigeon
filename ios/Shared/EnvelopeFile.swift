import CryptoKit
import Foundation

extension Envelope {
    /// Same format as `seal(header:body:to:)` (see mac/Sources/Crypto.swift), but
    /// writes the envelope straight to a file instead of assembling one more
    /// full-size copy in memory, which matters inside the Share extension.
    static func seal(header: [String: Any], body: Data, to recipientPub: Data, into file: URL) throws {
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: recipientPub)
        let eph = P256.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.x963Representation
        let sym = try eph.sharedSecretFromKeyAgreement(with: recipient).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: ephPub + recipientPub, sharedInfo: info, outputByteCount: 32)
        let h = try JSONSerialization.data(withJSONObject: header)
        let len = Data([UInt8(h.count >> 24 & 0xff), UInt8(h.count >> 16 & 0xff), UInt8(h.count >> 8 & 0xff), UInt8(h.count & 0xff)])
        let box = try AES.GCM.seal(len + h + body, using: sym, nonce: AES.GCM.Nonce(), authenticating: magic + ephPub)

        FileManager.default.createFile(atPath: file.path, contents: nil)
        let out = try FileHandle(forWritingTo: file)
        defer { try? out.close() }
        try out.write(contentsOf: magic + ephPub + box.nonce.withUnsafeBytes { Data($0) })
        try out.write(contentsOf: box.ciphertext)
        try out.write(contentsOf: box.tag)
    }
}
