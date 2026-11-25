import CryptoKit
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// Serial codes. Not asked for at present: the app opens for everyone. The check is kept so it can be switched back on.
/// A serial is a person's name signed with a key that only the author holds; the app carries the public half,
/// which can check a serial but cannot make one. Nothing goes online. Serials are made with tools/serial.swift.
enum License {
    /// The public half of the signing key.
    static let publicKey = "ULFNN8NiRg+wBaVC3JDlBrNUNPjXtIJM+VATZCq2oMk="

    private static func data(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// The name a serial was made for, or nil if it is not a real one.
    static func owner(of serial: String) -> String? {
        let s = serial.filter { !$0.isWhitespace }
        // MIT-<name>-<signature>; the signature is always 86 characters.
        guard s.hasPrefix("MIT-"), s.count > 4 + 1 + 86 else { return nil }
        let sig = String(s.suffix(86)), body = s.dropFirst(4).dropLast(87)
        guard s.dropLast(86).last == "-", let payload = data(String(body)), let signature = data(sig),
              let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(signature, for: payload), let name = String(data: payload, encoding: .utf8), !name.isEmpty else { return nil }
        return name
    }

    /// The Mac the serials are made on needs none.
    static var isAuthor: Bool {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mitroley/serial-signing.key")
        guard let d = try? Data(contentsOf: file), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) else { return false }
        return k.publicKey.rawRepresentation.base64EncodedString() == publicKey
    }

    static var saved: String { UserDefaults.standard.string(forKey: "serial") ?? "" }
    static var ownerName: String? { isAuthor ? "the author" : owner(of: saved) }
}
