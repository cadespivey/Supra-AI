// Deterministic CMS signer for the release preflight manifest.
//
//   swift Scripts/sign-release-manifest.swift \
//     --identity "Developer ID Application: NAME (TEAMID)" \
//     --team-id TEAMID --input manifest.json --output manifest.json.cms
//
// `security cms -S -N <nickname>` resolves nicknames unreliably and silently
// falls back to an arbitrary default identity when the nickname does not match
// (observed on the release host: an S/MIME email certificate), which the
// downstream Team ID gate then rejects. This tool selects the signing identity
// from the Keychain by exact certificate subject summary AND validates the
// certificate's organizational-unit Team ID BEFORE signing, then emits the
// same attached, DER-encoded CMS SignedData (SHA-256, full chain) that
// `security cms -D` and `openssl cms -verify` already verify.

import Foundation
import Security

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("sign-release-manifest: " + message + "\n").utf8))
    exit(1)
}

var options: [String: String] = [:]
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let key = arguments.removeFirst()
    guard key.hasPrefix("--"), !arguments.isEmpty else {
        die("usage: --identity LABEL --team-id TEAMID --input FILE --output FILE")
    }
    options[String(key.dropFirst(2))] = arguments.removeFirst()
}
guard let identityLabel = options["identity"], let expectedTeamID = options["team-id"],
      let inputPath = options["input"], let outputPath = options["output"] else {
    die("usage: --identity LABEL --team-id TEAMID --input FILE --output FILE")
}
guard expectedTeamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
    die("team id must be ten characters: \(expectedTeamID)")
}
guard let content = FileManager.default.contents(atPath: inputPath), !content.isEmpty else {
    die("cannot read manifest input: \(inputPath)")
}

func organizationalUnit(of certificate: SecCertificate) -> String? {
    var error: Unmanaged<CFError>?
    guard let values = SecCertificateCopyValues(
        certificate, [kSecOIDX509V1SubjectName] as CFArray, &error
    ) as? [String: Any],
        let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
        let components = subject[kSecPropertyKeyValue as String] as? [[String: Any]]
    else { return nil }
    for component in components {
        guard let oid = component[kSecPropertyKeyLabel as String] as? String,
              oid == (kSecOIDOrganizationalUnitName as String),
              let value = component[kSecPropertyKeyValue as String] as? String
        else { continue }
        return value
    }
    return nil
}

let query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnRef as String: true,
]
var found: CFTypeRef?
let searchStatus = SecItemCopyMatching(query as CFDictionary, &found)
guard searchStatus == errSecSuccess, let identities = found as? [SecIdentity] else {
    die("no signing identity matches \(identityLabel) (keychain search status \(searchStatus))")
}

var selected: SecIdentity?
for identity in identities {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
          let cert = certificate,
          let summary = SecCertificateCopySubjectSummary(cert) as String?,
          summary == identityLabel
    else { continue }
    guard let unit = organizationalUnit(of: cert), unit == expectedTeamID else {
        die("identity \(identityLabel) does not carry Team ID \(expectedTeamID)")
    }
    guard selected == nil else { die("multiple identities match \(identityLabel); refusing to guess") }
    selected = identity
}
guard let signer = selected else {
    die("no signing identity matches \(identityLabel)")
}

var encoder: CMSEncoder?
guard CMSEncoderCreate(&encoder) == errSecSuccess, let cms = encoder else {
    die("cannot create CMS encoder")
}
guard CMSEncoderAddSigners(cms, signer) == errSecSuccess else {
    die("cannot attach signing identity")
}
guard CMSEncoderSetCertificateChainMode(cms, .chainWithRoot) == errSecSuccess else {
    die("cannot configure certificate chain inclusion")
}
guard CMSEncoderSetSignerAlgorithm(cms, kCMSEncoderDigestAlgorithmSHA256) == errSecSuccess else {
    die("cannot configure SHA-256 digest")
}
let updateStatus = content.withUnsafeBytes { buffer -> OSStatus in
    guard let base = buffer.baseAddress else { return errSecParam }
    return CMSEncoderUpdateContent(cms, base, buffer.count)
}
guard updateStatus == errSecSuccess else { die("cannot add manifest content: \(updateStatus)") }
var encoded: CFData?
guard CMSEncoderCopyEncodedContent(cms, &encoded) == errSecSuccess, let der = encoded as Data? else {
    die("CMS signing failed; ensure the Keychain is unlocked and access is approved")
}
do {
    try der.write(to: URL(fileURLWithPath: outputPath))
} catch {
    die("cannot write signature to \(outputPath): \(error.localizedDescription)")
}
print("signed \(inputPath) as \(identityLabel) [\(expectedTeamID)]")
