import type { ReactNode } from "react";
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

const bar = "h-2 rounded-full bg-supra-border";

function StepMockBody({ index }: { index: number }) {
  switch (index) {
    case 0: // Open a matter — matter list
      return (
        <div className="space-y-2">
          {["Smith v. Aldridge", "Estate of Calloway", "Northwind LLC"].map(
            (matter, i) => (
              <div
                key={matter}
                className={`flex items-center gap-3 rounded-lg border border-supra-border px-3 py-2 ${
                  i === 0 ? "bg-supra-navyPanelLight" : "bg-supra-navyPanel"
                }`}
              >
                <span className="h-2 w-2 rounded-full bg-supra-gold/60" />
                <span className="text-xs text-supra-muted">{matter}</span>
              </div>
            ),
          )}
        </div>
      );
    case 1: // Import documents — file grid
      return (
        <div className="grid grid-cols-2 gap-2">
          {["Complaint.pdf", "Lease.pdf", "Exhibit-A.pdf", "Notes.docx"].map(
            (doc) => (
              <div
                key={doc}
                className="flex items-center gap-2 rounded-lg border border-supra-border bg-supra-navyPanel px-3 py-2"
              >
                <span className="h-4 w-3 shrink-0 rounded-sm border border-supra-gold/50" />
                <span className="truncate text-[0.7rem] text-supra-muted">
                  {doc}
                </span>
              </div>
            ),
          )}
        </div>
      );
    case 2: // Ask a question — prompt bar
      return (
        <div className="space-y-3">
          <div className="rounded-xl border border-supra-border bg-supra-navyPanel px-3 py-3">
            <span className="text-xs italic text-supra-muted">
              {"Is the indemnity clause enforceable here?"}
            </span>
          </div>
          <div className="flex justify-end">
            <span className="rounded-lg bg-supra-gold px-3 py-1.5 font-caps text-[0.6rem] uppercase tracking-wide text-supra-navyDeep">
              Ask
            </span>
          </div>
        </div>
      );
    case 3: // Source-grounded answer — text + citation chips
      return (
        <div className="space-y-2">
          <div className={bar} />
          <div className={`${bar} w-5/6`} />
          <div className={`${bar} w-2/3`} />
          <div className="mt-3 flex gap-2">
            <span className="rounded-full border border-supra-gold/50 px-2.5 py-1 font-caps text-[0.55rem] uppercase tracking-wide text-supra-gold">
              Source 1
            </span>
            <span className="rounded-full border border-supra-border px-2.5 py-1 font-caps text-[0.55rem] uppercase tracking-wide text-supra-muted">
              Source 2
            </span>
          </div>
        </div>
      );
    case 4: // Verify citations — checklist
      return (
        <div className="space-y-2">
          {["Citation format", "Quotation match", "Still good law"].map(
            (check, i) => (
              <div
                key={check}
                className="flex items-center gap-3 rounded-lg border border-supra-border bg-supra-navyPanel px-3 py-2"
              >
                <span
                  className={`flex h-4 w-4 items-center justify-center rounded-full text-[0.6rem] ${
                    i < 2
                      ? "bg-supra-gold text-supra-navyDeep"
                      : "border border-supra-border text-supra-muted"
                  }`}
                >
                  {i < 2 ? "✓" : ""}
                </span>
                <span className="text-[0.7rem] text-supra-muted">{check}</span>
              </div>
            ),
          )}
        </div>
      );
    default: // Draft — document lines
      return (
        <div className="space-y-2">
          <div className={`${bar} w-1/3 bg-supra-gold/50`} />
          <div className={bar} />
          <div className={bar} />
          <div className={`${bar} w-4/5`} />
          <div className={`${bar} w-2/3`} />
        </div>
      );
  }
}

function StepMock({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <div
      aria-hidden="true"
      className="rounded-2xl border border-supra-border bg-supra-navy p-4"
    >
      <div className="flex items-center gap-2 border-b border-supra-border pb-3">
        <span className="h-2.5 w-2.5 rounded-full bg-supra-border" />
        <span className="h-2.5 w-2.5 rounded-full bg-supra-border" />
        <span className="h-2.5 w-2.5 rounded-full bg-supra-gold/50" />
        <span className="ml-2 truncate font-caps text-[0.6rem] uppercase tracking-wide text-supra-muted">
          {title}
        </span>
      </div>
      <div className="mt-4">{children}</div>
    </div>
  );
}

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
            <StepMock title={step.title}>
              <StepMockBody index={index} />
            </StepMock>
          </article>
        ))}
      </div>
    </PageShell>
  );
}
