import CryptoKit
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// Serial codes. A serial is a person's name signed with a key that only the author holds; the app carries the public half,
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

/// Shown over the window until a serial is entered. There is nothing behind it to click.
struct LicenseGate: View {
    // MITROLEY_GATE=1 shows the gate even on the author's Mac, to look at it.
    @State private var unlocked = (License.ownerName != nil && ProcessInfo.processInfo.environment["MITROLEY_GATE"] == nil) || CommandLine.arguments.contains("--selftest")
    @State private var text = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        if !unlocked {
            ZStack {
                Theme.bg.opacity(0.97).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 72, height: 72)
                    Text("Enter your serial").font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                    Text("mitroley is shared by invitation. Paste the serial you were sent; it is checked on this Mac and nothing goes online.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    TextField("MIT-…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).lineLimit(2...4)
                        .padding(10).frame(width: 420)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(wrong ? Theme.danger : .clear, lineWidth: 1))
                        .focused($focused)
                        .onSubmit(check)
                        .onChange(of: text) { _, _ in wrong = false }
                    if wrong {
                        Text("That serial is not valid. Copy the whole line, from MIT- to the end.").font(.system(size: 12)).foregroundStyle(Theme.danger)
                    }
                    HStack(spacing: 8) {
                        Button("Quit") { NSApp.terminate(nil) }.buttonStyle(PillButtonStyle())
                        Button("Paste") { text = NSPasteboard.general.string(forType: .string) ?? text }.buttonStyle(PillButtonStyle())
                        Button("Unlock", action: check).buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(30)
            }
            .onAppear { focused = true }
        }
    }

    private func check() {
        guard License.owner(of: text) != nil else { wrong = true; return }
        UserDefaults.standard.set(text.filter { !$0.isWhitespace }, forKey: "serial")
        unlocked = true
    }
}
