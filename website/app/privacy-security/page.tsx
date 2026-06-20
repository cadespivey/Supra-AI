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
      "Generated work product",
    ],
  },
  {
    title: "External research boundary",
    items: [
      "CourtListener research when enabled",
      "Optional network access",
      "API token stored in Keychain",
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
