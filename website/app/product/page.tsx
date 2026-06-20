import { PageShell } from "@/components/PageShell";

const steps = [
  {
    title: "Open a matter",
    body: "Begin inside a matter workspace that keeps research, documents, drafts, and review artifacts together.",
  },
  {
    title: "Import documents",
    body: "Bring in matter files so the workspace can analyze the material already under attorney control.",
  },
  {
    title: "Ask a legal question",
    body: "Frame a research or drafting question against the matter context and available source material.",
  },
  {
    title: "Review a source-grounded answer",
    body: "Read analysis alongside the sources and excerpts that support it before moving forward.",
  },
  {
    title: "Verify citations",
    body: "Treat citation-sensitive output as a review workflow, with correction before reliance.",
  },
  {
    title: "Draft, critique, or revise",
    body: "Turn grounded research and document context into attorney-reviewed work product.",
  },
];

export default function ProductPage() {
  return (
    <PageShell
      eyebrow="Product"
      title="How Supra AI works"
      intro="Supra AI is organized around the way legal work actually moves: matters, documents, questions, sources, verification, and drafts."
    >
      <div className="space-y-6">
        {steps.map((step, index) => (
          <article
            key={step.title}
            className="grid gap-6 rounded-2xl border border-supra-border bg-supra-navyPanel p-6 md:grid-cols-[0.9fr_1.1fr] md:items-center"
          >
            <div>
              <p className="font-caps text-xs font-bold uppercase text-supra-gold">
                Step {String(index + 1).padStart(2, "0")}
              </p>
              <h2 className="mt-3 text-3xl text-supra-white">{step.title}</h2>
              <p className="mt-4 text-base leading-7 text-supra-muted">
                {step.body}
              </p>
            </div>
            <div className="rounded-2xl border border-supra-border bg-supra-navy p-4">
              <div className="mb-4 h-3 w-28 rounded-full bg-supra-gold/45" />
              <div className="space-y-3">
                <div className="h-10 rounded-xl border border-supra-border bg-supra-navyPanelLight" />
                <div className="h-10 rounded-xl border border-supra-border bg-supra-navyPanelLight" />
                <div className="h-20 rounded-xl border border-supra-border bg-supra-navyPanel" />
              </div>
            </div>
          </article>
        ))}
      </div>
    </PageShell>
  );
}
