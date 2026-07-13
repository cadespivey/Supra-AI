import { BoundaryPanel } from "@/components/BoundaryPanel";
import { PageShell } from "@/components/PageShell";

const panels = [
  {
    title: "Local boundary",
    items: [
      "Supra AI app",
      "Local MLX runtime",
      "Matter documents",
      "Local embeddings",
      "Saved authorities & opinion text",
      "Generated work product",
      "Not sent to Supra AI for model training",
    ],
  },
  {
    title: "External research boundary",
    items: [
      "Case-law and public-records lookups initiated by you",
      "Default-deny host allow-list (courts, statutes, registers, public records)",
      "Provider-specific query fields; no attached matter documents",
      "Query terms you can see and adjust",
      "Query terms redacted in the local network log",
      "API keys stored in the macOS Keychain",
      "No general cloud generation",
    ],
  },
  {
    title: "Professional review boundary",
    items: [
      "Citation verification",
      "Attorney review",
      "Jurisdiction checks",
      "Procedural rule checks",
      "No legal advice from the software",
    ],
  },
];

export default function PrivacySecurityPage() {
  return (
    <PageShell
      eyebrow="Trust"
      title="Privacy & Security"
      intro="Supra AI is designed around local processing, limited network access, and attorney-controlled review."
    >
      <div className="grid gap-x-12 gap-y-10 sm:grid-cols-2 lg:grid-cols-3">
        {panels.map((panel) => (
          <BoundaryPanel key={panel.title} {...panel} />
        ))}
      </div>
    </PageShell>
  );
}
