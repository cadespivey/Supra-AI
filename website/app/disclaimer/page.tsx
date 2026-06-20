import { DraftNotice } from "@/components/DraftNotice";
import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";

const sections = [
  {
    title: "Not legal advice",
    body: "Supra AI is software for legal professionals. Its outputs are research and drafting assistance, not legal advice, and must not be relied on as a substitute for the independent judgment of a licensed attorney. Nothing the app produces is a professional opinion on any matter.",
  },
  {
    title: "No attorney-client relationship",
    body: "Using Supra AI does not create an attorney-client relationship between you and Supra AI, Cade Spivey, or any contributor. The software does not represent any party and does not practice law.",
  },
  {
    title: "Attorney verification required",
    body: "Every output is intended to be reviewed, corrected, and approved by a qualified attorney before it is used, filed, or relied upon. The user remains responsible for the accuracy and appropriateness of all work product.",
  },
  {
    title: "Citation and quotation review required",
    body: "AI-generated citations and quotations can be incomplete, mismatched, or fabricated. Verify every authority, pin cite, and quotation against the original source before relying on it. CourtListener results should be confirmed against the controlling source.",
  },
  {
    title: "Beta limitations",
    body: "Supra AI is public beta software and may contain errors, omissions, or incomplete features, and its behavior may change between releases. Do not use it as the sole basis for any decision with legal or financial consequences.",
  },
  {
    title: "Jurisdiction and procedural rules",
    body: "Supra AI does not determine the law, court rules, or procedural requirements that apply to your matter. Confirm jurisdiction, current authority, filing deadlines, and local rules independently.",
  },
];

export default function DisclaimerPage() {
  return (
    <PageShell
      eyebrow="Legal"
      title="Disclaimer"
      intro="Supra AI is a legal research, drafting, and document-analysis tool for legal professionals. It is not a substitute for attorney judgment."
    >
      <DraftNotice />
      <div className="grid gap-5 md:grid-cols-2">
        {sections.map((section) => (
          <section
            key={section.title}
            className="rounded-2xl border border-supra-border bg-supra-navyPanel p-6"
          >
            <h2 className="text-2xl text-supra-white">{section.title}</h2>
            <p className="mt-4 text-base leading-7 text-supra-muted">
              {section.body}
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
