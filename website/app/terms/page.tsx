import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";

const sections = [
  "Use of Supra AI",
  "Public beta status",
  "No legal advice",
  "No attorney-client relationship",
  "User responsibility for verification",
  "Software availability and changes",
  "Feedback submissions",
  "No warranty",
  "Limitations",
  "Contact",
];

export default function TermsPage() {
  return (
    <PageShell
      eyebrow="Legal"
      title="Terms"
      intro="These terms are a conservative draft for review before public launch."
    >
      <div className="space-y-5">
        {sections.map((section) => (
          <section
            key={section}
            className="rounded-2xl border border-supra-border bg-supra-navyPanel p-6"
          >
            <h2 className="text-2xl text-supra-white">{section}</h2>
            <p className="mt-4 text-base leading-7 text-supra-muted">
              Placeholder terms language should remain clearly marked for review
              before publication.
            </p>
          </section>
        ))}
        <section>
          <h2 className="mb-5 text-2xl text-supra-white">
            Public GitHub Issues warning
          </h2>
          <FeedbackWarning />
        </section>
      </div>
    </PageShell>
  );
}
