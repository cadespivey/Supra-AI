import { Section } from "./Section";

const capabilities = [
  {
    title: "Case-law research",
    body: "Legal answers are constrained to retained authority packets. A matter uses its saved authorities first; a wider CourtListener search is one click away. Party and docket questions can retrieve PACER/RECAP filing data.",
  },
  {
    title: "Public records search",
    body: "Search official government data alongside case law: SEC EDGAR filings (10-K, 10-Q, 8-K), the CFPB complaint database, and NLRB labor records — shown as sourced filings and allegations as filed, never findings, and never fed to the model as fact.",
  },
  {
    title: "Citation verification",
    body: "Citation labels are resolved against retained sources and material propositions receive a separate support check. Unsupported, unresolved, or fabricated authority is flagged or blocked; this is not a citator or good-law opinion.",
  },
  {
    title: "Document intelligence",
    body: "Import matter documents and ask source-scoped questions — a fast preliminary answer with a full-file pass one click away, and [S#] labels that resolve to retained source locators or force review.",
  },
  {
    title: "Primary law from official text",
    body: "Statutory and regulatory questions ground in the official text itself — U.S. Code from GovInfo, CFR with effective dates from eCFR — with a currency caveat when a source can't vouch for freshness.",
  },
  {
    title: "Timekeeping & billing",
    body: "ScratchPad captures the day as you work — quick notes tagged with @matter and #activity — then generates polished, UTBMS-coded billing narratives you review before anything counts. Tag an entry #Note to keep it out of billing entirely. Export to LEDES 1998B, CSV, or the clipboard.",
  },
  {
    title: "Matter workspace",
    body: "Organize research, drafts, documents, authorities, billing, and a full audit trail by matter — sorted by client, practice area, name, or date (or pinned and hand-ordered), with documents in nested folders and an in-app reader for saved opinions that works offline.",
  },
  {
    title: "Legislative & regulatory tracking",
    body: "Pending bills and rulemaking appear as clearly-labeled tracking context — from the Federal Register, Regulations.gov, and OpenStates — never passed off as citable authority.",
  },
  {
    title: "Document drafting",
    body: "Draft inside a matter's chat: a Draft button collects required details for a Florida Notice of Appearance or demand letter. The pre-file gate blocks rendering when required facts, authority support, or verification provenance are missing, unsupported, or unverifiable.",
  },
];

export function CapabilityGrid() {
  return (
    <Section>
      <div className="measure-wide">
        <p className="font-caps text-xs uppercase text-supra-gold">
          Capabilities
        </p>
        <h2 className="mt-4 text-3xl leading-[1.15] text-supra-white">
          Built for legal work that stays grounded.
        </h2>
        <p className="mt-6 text-lg leading-[1.5] text-supra-muted">
          Supra AI combines local generation with case-law and public-records
          research, document intelligence, drafting, timekeeping, and review
          workflows designed for attorneys.
        </p>
      </div>

      <div className="mt-14 grid gap-x-12 gap-y-10 lg:grid-cols-[0.9fr_1.3fr]">
        <div className="border-t-2 border-supra-gold/60 pt-6">
          <p className="font-caps text-xs uppercase text-supra-gold">Featured</p>
          <h3 className="mt-4 text-2xl text-supra-white">Local generation</h3>
          <p className="mt-4 text-base leading-[1.55] text-supra-muted">
            Supra AI runs models locally on Apple Silicon, so your files and
            prompts do not need to leave your Mac for generation.
          </p>
          <p className="mt-6 font-caps text-xs uppercase text-supra-muted">
            MLX runtime · Local model · On-device embeddings
          </p>
        </div>

        <dl className="grid gap-x-10 gap-y-8 sm:grid-cols-2">
          {capabilities.map((item) => (
            <div
              key={item.title}
              className="border-t border-supra-border pt-5"
            >
              <dt className="text-xl text-supra-white">{item.title}</dt>
              <dd className="mt-3 text-base leading-[1.55] text-supra-muted">
                {item.body}
              </dd>
            </div>
          ))}
        </dl>
      </div>
    </Section>
  );
}
