import Foundation
import CryptoKit

// CryptoKit-backed replacements for the SwiftECC/BigInt types used by the
// vendored NearbyShare core. P-256 ECDH via KeyAgreement, ECDSA via Signing.

struct ECPublicKey {
    let keyAgreement: P256.KeyAgreement.PublicKey
    let signing: P256.Signing.PublicKey

    var rawX: Data {
        Data(keyAgreement.rawRepresentation.prefix(32))
    }
    var rawY: Data {
        Data(keyAgreement.rawRepresentation.suffix(32))
    }
}

struct ECPrivateKey {
    let keyAgreement: P256.KeyAgreement.PrivateKey
    let signing: P256.Signing.PrivateKey

    var publicKey: ECPublicKey {
        ECPublicKey(keyAgreement: keyAgreement.publicKey, signing: signing.publicKey)
    }

	/// Raw (r || s), 32 bytes each — matches ECSignature serialization in use.
	enum SignError: Error{case failed}
	func sign(msg: Data) throws -> (r: Data, s: Data) {
		let sig=try signing.signature(for: msg)
		let raw = sig.rawRepresentation
		return (Data(raw.prefix(32)), Data(raw.suffix(32)))
	}
}

enum ECDomain {
    static func makeKeyPair() -> (ECPublicKey, ECPrivateKey) {
        let ka = P256.KeyAgreement.PrivateKey()
        let sk = P256.Signing.PrivateKey()
        let pub = ECPublicKey(keyAgreement: ka.publicKey, signing: sk.publicKey)
        return (pub, ECPrivateKey(keyAgreement: ka, signing: sk))
    }

    /// ECDH shared secret, hashed with SHA-256 (matches SwiftECC multiplyPoint().x flow).
    static func sharedSecret(privateKey: ECPrivateKey, peerX: Data, peerY: Data) throws -> Data {
        var x = peerX
        var y = peerY
        if x.count > 32 { x = x.suffix(32) }
        if y.count > 32 { y = y.suffix(32) }
        var raw = Data([0x04])
        raw.append(pad32(stripLeadingZero(x)))
        raw.append(pad32(stripLeadingZero(y)))
        let peerPub = try P256.KeyAgreement.PublicKey(x963Representation: raw)
        let secret = try privateKey.keyAgreement.sharedSecretFromKeyAgreement(with: peerPub)
        var sha = SHA256()
        sha.update(data: secret.withUnsafeBytes { Data($0) })
        return Data(sha.finalize())
    }

    static func stripLeadingZero(_ d: Data) -> Data {
        var v = d
        while v.count > 1 && v.first == 0 { v = v.dropFirst() }
        return Data(v)
    }

    static func pad32(_ d: Data) -> Data {
        if d.count >= 32 { return d.suffix(32) }
        return Data(repeating: 0, count: 32 - d.count) + d
    }
}

/// Signed big-endian bytes for protobuf x/y fields (strip accidental leading zero, keep sign bit clear).
func signedBytes(_ raw32: Data) -> Data {
    let v = ECDomain.stripLeadingZero(raw32)
    if v.count > 32 { return v.suffix(32) }
    if let first = v.first, first & 0x80 != 0 {
        return Data([0]) + v
    }
    return v
}
