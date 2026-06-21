import type { ReactNode } from "react";
import { PageShell } from "@/components/PageShell";

const steps = [
  {
    title: "Configure local models",
    body: "Assign separate local MLX models for legal reasoning, high-quality research, drafting, and critique, then load the runtime on device.",
  },
  {
    title: "Start in global chat",
    body: "Open to a fresh legal prompt set, search prior global chats by title, delete stale chats, or move a chat into a matter when it becomes case-specific.",
  },
  {
    title: "Open a matter",
    body: "Keep matter chats, research sessions, authorities, documents, structured outputs, and audit history in one workspace.",
  },
  {
    title: "Import documents",
    body: "Bring in matter files for OCR, extraction, chunking, local embedding search, cited Q&A, and fact chronologies.",
  },
  {
    title: "Review grounded answers",
    body: "Run CourtListener-backed legal research or document Q&A, then inspect the sources and verification warnings before relying on the work.",
  },
  {
    title: "Draft, critique, or export",
    body: "Turn reviewed research and document context into attorney-edited drafts, critique passes, chronologies, and exportable work product.",
  },
];

const bar = "h-2 rounded-full bg-supra-border";

function StepMockBody({ index }: { index: number }) {
  switch (index) {
    case 0: // Configure local models
      return (
        <div className="space-y-2">
          {[
            ["Legal reasoning", "Qwen3 30B"],
            ["High-quality research", "DeepSeek-R1"],
            ["Drafting", "Qwen3 Instruct"],
          ].map(([role, model]) => (
            <div
              key={role}
              className="flex items-center justify-between gap-3 rounded-lg border border-supra-border bg-supra-navyPanel px-3 py-2"
            >
              <span className="text-[0.7rem] text-supra-muted">{role}</span>
              <span className="rounded-md bg-supra-navyPanelLight px-2 py-1 text-[0.62rem] text-supra-gold">
                {model}
              </span>
            </div>
          ))}
        </div>
      );
    case 1: // Start in global chat — history + suggestions
      return (
        <div className="grid grid-cols-[0.8fr_1.2fr] gap-3">
          <div className="space-y-2 rounded-lg border border-supra-border bg-supra-navyPanel p-2">
            <div className="rounded-md border border-supra-border bg-supra-navy px-2 py-1 text-[0.62rem] text-supra-muted">
              Search chats
            </div>
            {["Lease review", "Removal deadline", "Privilege memo"].map(
              (chat, i) => (
                <div
                  key={chat}
                  className={`rounded-md px-2 py-1.5 text-[0.66rem] ${
                    i === 0
                      ? "bg-supra-navyPanelLight text-supra-gold"
                      : "text-supra-muted"
                  }`}
                >
                  {chat}
                </div>
              ),
            )}
          </div>
          <div className="grid content-center gap-2">
            {["Draft objections", "Research estoppel", "Check citations", "Plan deposition"].map(
              (prompt) => (
                <div
                  key={prompt}
                  className="rounded-lg border border-supra-border bg-supra-navyPanel px-3 py-2 text-[0.66rem] text-supra-muted"
                >
                  {prompt}
                </div>
              ),
            )}
          </div>
        </div>
      );
    case 2: // Open a matter — matter list
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
    case 3: // Import documents — file grid
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
    case 4: // Source-grounded answer — text + citation chips
      return (
        <div className="space-y-2">
          <div className={bar} />
          <div className={`${bar} w-5/6`} />
          <div className={`${bar} w-2/3`} />
          <div className="mt-3 flex gap-2">
            <span className="rounded-full border border-supra-gold/50 px-2.5 py-1 font-caps text-[0.55rem] uppercase text-supra-gold">
              Source 1
            </span>
            <span className="rounded-full border border-supra-border px-2.5 py-1 font-caps text-[0.55rem] uppercase text-supra-muted">
              Source 2
            </span>
          </div>
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
      className="rounded-md border border-supra-border bg-supra-navy p-4"
    >
      <div className="flex items-center gap-2 border-b border-supra-border pb-3">
        <span className="h-2.5 w-2.5 rounded-full bg-supra-border" />
        <span className="h-2.5 w-2.5 rounded-full bg-supra-border" />
        <span className="h-2.5 w-2.5 rounded-full bg-supra-gold/50" />
        <span className="ml-2 truncate font-caps text-[0.6rem] uppercase text-supra-muted">
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
      intro="Supra AI is organized around the way legal work actually moves: local model control, global questions, matter workspaces, documents, sources, verification, and drafts."
    >
      <ol className="list-none space-y-10">
        {steps.map((step, index) => (
          <li
            key={step.title}
            className="grid gap-x-10 gap-y-6 border-t border-supra-border pt-8 md:grid-cols-[0.9fr_1.1fr] md:items-center"
          >
            <div>
              <p className="font-caps text-xs uppercase text-supra-gold">
                Step {String(index + 1).padStart(2, "0")}
              </p>
              <h2 className="mt-3 text-2xl text-supra-white">{step.title}</h2>
              <p className="measure mt-4 text-base leading-[1.55] text-supra-muted">
                {step.body}
              </p>
            </div>
            <StepMock title={step.title}>
              <StepMockBody index={index} />
            </StepMock>
          </li>
        ))}
      </ol>
    </PageShell>
  );
}
