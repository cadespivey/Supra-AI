import type { ReactNode } from "react";
import { PageShell } from "@/components/PageShell";

const steps = [
  {
    id: "models",
    title: "Configure local models",
    body: "Assign separate local MLX models for legal reasoning, drafting, and critique, then load the runtime on device — each task runs on the model best suited to it.",
  },
  {
    id: "chat",
    title: "Start in global chat",
    body: "Open to a fresh legal prompt set and type / to pull up the command palette — /legal, /research, /draft, /critique, /verify, /ask, each with a one-line description. Search runs across chat titles, message content, and ScratchPad notes, with a leading # for an exact tag match. Move a chat into a matter when it becomes case-specific.",
  },
  {
    id: "matter",
    title: "Open a matter",
    body: "Keep matter chats, research sessions, authorities, documents, structured outputs, timekeeping, and audit history in one workspace.",
  },
  {
    id: "documents",
    title: "Import documents",
    body: "Bring in matter files for OCR, extraction, chunking, local embedding search, cited Q&A, and fact chronologies.",
  },
  {
    id: "research",
    title: "Research case law and public records",
    body: "Run research as an auditable session: approve real search queries, then make an explicit keep-or-skip decision on every result before it enters your matter's authority library. Case law and federal dockets come from CourtListener; public records come from SEC EDGAR filings, the CFPB complaint database, and NLRB labor-case records. Public records are shown as sourced filings and allegations as filed — never findings, and never passed to the model as fact.",
  },
  {
    id: "answers",
    title: "Review grounded answers",
    body: "Answers arrive fast and honestly labeled: document questions search the most relevant passages first with a full-file pass one click away, and research answers ground in your saved authorities before reaching for CourtListener. Every [S#] and [A#] citation is clickable — sources open beside the chat at the supporting passage, and opinions open in a built-in reader with the cited holding highlighted.",
  },
  {
    id: "scratchpad",
    title: "Capture your time in ScratchPad",
    body: "Jot the day's work as it happens in a running note, tagging each entry with @matter and #activity. When you're ready, ScratchPad turns those notes into polished, UTBMS-coded billing narratives grouped by matter — each line citing the note and work product behind it. Tag an entry #Note to keep it out of billing entirely, review everything before it counts, and export to LEDES 1998B, CSV, or the clipboard.",
  },
  {
    id: "draft",
    title: "Draft, critique, or export",
    body: "Turn reviewed research and document context into attorney-edited drafts, critique passes, chronologies, and exportable work product. In a matter, the Draft button generates a downloadable Word document — a Florida Notice of Appearance today, with the signature block matched to the filing's court — to open, reveal in Finder, or save a copy of.",
  },
];

const bar = "h-2 rounded-full bg-supra-border";

function StepMockBody({ id }: { id: string }) {
  switch (id) {
    case "models":
      return (
        <div className="space-y-2">
          {[
            ["Legal reasoning", "Qwen3 30B"],
            ["Drafting", "Qwen3 Instruct"],
            ["Critique", "DeepSeek-R1"],
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
    case "chat": // history + suggestions
      return (
        <div className="grid grid-cols-[0.8fr_1.2fr] gap-3">
          <div className="space-y-2 rounded-lg border border-supra-border bg-supra-navyPanel p-2">
            <div className="rounded-md border border-supra-border bg-supra-navy px-2 py-1 text-[0.62rem] text-supra-muted">
              Search chats or #tags
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
    case "matter": // matter list
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
    case "documents": // file grid
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
    case "research": // research + public-records sources
      return (
        <div className="space-y-2">
          {[
            ["CourtListener", "Case law · dockets"],
            ["SEC EDGAR", "Company filings"],
            ["CFPB", "Consumer complaints"],
            ["NLRB", "Labor-case records"],
          ].map(([source, kind], i) => (
            <div
              key={source}
              className={`flex items-center justify-between gap-3 rounded-lg border border-supra-border px-3 py-2 ${
                i === 0 ? "bg-supra-navyPanelLight" : "bg-supra-navyPanel"
              }`}
            >
              <span className="text-[0.7rem] text-supra-white">{source}</span>
              <span className="font-caps text-[0.55rem] uppercase text-supra-muted">
                {kind}
              </span>
            </div>
          ))}
        </div>
      );
    case "answers": // source-grounded answer + citation chips
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
    case "scratchpad": // ScratchPad notes → billing entry
      return (
        <div className="space-y-2">
          {[
            ["Call w/ ", "@Smith", " re discovery plan ", "#call"],
            ["Drafted MSJ outline ", "#draft", "", ""],
          ].map((parts, i) => (
            <div
              key={i}
              className="rounded-lg border border-supra-border bg-supra-navyPanel px-3 py-2 text-[0.66rem] leading-relaxed text-supra-muted"
            >
              {parts[0]}
              {parts[1] && <span className="text-supra-gold">{parts[1]}</span>}
              {parts[2]}
              {parts[3] && <span className="text-supra-gold">{parts[3]}</span>}
            </div>
          ))}
          <div aria-hidden="true" className="ml-3 h-3 w-px bg-supra-gold/60" />
          <div className="flex items-center justify-between gap-3 rounded-lg border border-supra-gold/40 bg-supra-navyPanelLight px-3 py-2">
            <span className="truncate text-[0.66rem] text-supra-white">
              Telephone conference re: discovery
            </span>
            <span className="flex shrink-0 items-center gap-2">
              <span className="rounded-md bg-supra-navy px-1.5 py-0.5 font-caps text-[0.52rem] uppercase text-supra-gold">
                L110
              </span>
              <span className="text-[0.62rem] text-supra-muted">0.4h</span>
            </span>
          </div>
        </div>
      );
    default: // draft — document lines
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
      intro="Supra AI is organized around the way legal work actually moves: local model control, global questions, matter workspaces, documents, case-law and public-records research, source-grounded answers, timekeeping, and drafts."
    >
      <ol className="list-none space-y-10">
        {steps.map((step, index) => (
          <li
            key={step.id}
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
              <StepMockBody id={step.id} />
            </StepMock>
          </li>
        ))}
      </ol>
    </PageShell>
  );
}
