import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";

const sections = [
  "Not legal advice",
  "No attorney-client relationship",
  "Attorney verification required",
  "Citation and quotation review required",
  "Beta limitations",
  "Jurisdiction and procedural rules",
];

export default function DisclaimerPage() {
  return (
    <PageShell
      eyebrow="Legal"
      title="Disclaimer"
      intro="Supra AI is a legal research, drafting, and document-analysis tool for legal professionals. It is not a substitute for attorney judgment."
    >
      <div className="grid gap-5 md:grid-cols-2">
        {sections.map((section) => (
          <section
            key={section}
            className="rounded-2xl border border-supra-border bg-supra-navyPanel p-6"
          >
            <h2 className="text-2xl text-supra-white">{section}</h2>
            <p className="mt-4 text-base leading-7 text-supra-muted">
              This section is reserved for conservative review copy before
              public launch and should be confirmed by counsel.
            </p>
          </section>
        ))}
        <section className="md:col-span-2">
          <FeedbackWarning />
        </section>
      </div>
    </PageShell>
  );
}
