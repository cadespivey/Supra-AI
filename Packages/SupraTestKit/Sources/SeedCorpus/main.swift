import Foundation
import SupraTestKit

// SeedCorpus <specsDir> <outDir> [externalDir]
// Defaults (relative to CWD = repo root): TestData/specs, TestData, and the
// iCloud Downloads folder holding the provided real case documents.
let args = CommandLine.arguments
let cwd = FileManager.default.currentDirectoryPath
let specsDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "\(cwd)/TestData/specs", isDirectory: true)
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "\(cwd)/TestData", isDirectory: true)
let externalDir = URL(fileURLWithPath: args.count > 3 ? args[3] : "\(NSHomeDirectory())/Library/Mobile Documents/com~apple~CloudDocs/Downloads", isDirectory: true)

/// Real provided documents folded into each matter, keyed by spec filename stem.
let externalByMatterKey: [String: [String]] = [
    "construction-lien": [
        "City of Gainesville v Republic Inv Corp.doc",
        "Neapolitan Enterprises LLC v City of Naples.doc",
        "Deen v Tampa Port Authority.doc",
        "policies-and-procedures-judge-herndon(68950422.1).pdf",
    ],
    "insurance-claim": [
        "Dowd v Monroe County.doc",
        "Hirt v Polk County Bd of County Comrs.doc",
    ],
    "purchase-sale": [
        "Microdecisions Inc v Skinner.doc",
    ],
]

let generator = CorpusGenerator()
let fm = FileManager.default

guard let specFiles = try? fm.contentsOfDirectory(at: specsDir, includingPropertiesForKeys: nil)
    .filter({ $0.pathExtension == "json" })
    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
    FileHandle.standardError.write(Data("No specs found in \(specsDir.path)\n".utf8))
    exit(1)
}

var generated = 0
for specURL in specFiles {
    let key = specURL.deletingPathExtension().lastPathComponent
    do {
        let spec = try MatterSpec.decode(from: try Data(contentsOf: specURL))
        let matterDir = outDir.appendingPathComponent(spec.matterName.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        try generator.write(matter: spec, to: matterDir)

        if let externals = externalByMatterKey[key] {
            let sources = externals.map { externalDir.appendingPathComponent($0) }
            try generator.copyExternal(sources, into: matterDir, folder: "Caselaw & Procedure")
        }
        print("✓ \(spec.matterName): \(spec.documents.count) docs + notes (\(key))")
        generated += 1
    } catch {
        FileHandle.standardError.write(Data("✗ \(key): \(error)\n".utf8))
    }
}

print("\nGenerated \(generated)/\(specFiles.count) matters into \(outDir.path)")
