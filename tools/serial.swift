// mitroley. Copyright © 2026 Ayan Mitra.
//
// Makes a serial code for one person.   swift tools/serial.swift "Their Name"
//
// The signing key lives only on your Mac, at ~/Library/Application Support/mitroley/serial-signing.key. Keep a backup of it
// somewhere safe and never put it in the repository: whoever has it can make serials. The app holds only the matching
// public key, which can check a serial but cannot make one. The first run creates the key and prints the public half.
import CryptoKit
import Foundation

let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mitroley")
let file = dir.appendingPathComponent("serial-signing.key")
func b64url(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }

let key: Curve25519.Signing.PrivateKey
if let data = try? Data(contentsOf: file), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
    key = k
} else {
    key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try key.rawRepresentation.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    print("New signing key saved. Public key for License.swift: \(key.publicKey.rawRepresentation.base64EncodedString())")
}
let args = CommandLine.arguments.dropFirst()
if args.first == "--public" { print(key.publicKey.rawRepresentation.base64EncodedString()); exit(0) }
let name = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
guard !name.isEmpty else { print("Usage: swift tools/serial.swift \"Their Name\""); exit(1) }
let payload = Data(name.utf8)
let signature = try key.signature(for: payload)
print("MIT-\(b64url(payload))-\(b64url(signature))")
