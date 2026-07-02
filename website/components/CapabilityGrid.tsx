import { Section } from "./Section";

const capabilities = [
  {
    title: "Source-grounded research",
    body: "Answers cite retrieved authority, never model memory. Matters with saved authorities answer from your own library first; a wider CourtListener search is always one explicit click away. Party and docket questions search real federal filings.",
  },
  {
    title: "Citation verification",
    body: "Every generated cite is checked against the retrieved source packet, and /verify resolves citations against CourtListener's live corpus — unsupported or fabricated authority is flagged or blocked before you rely on it.",
  },
  {
    title: "Document intelligence",
    body: "Import matter documents and ask questions answered only from their text — fast preliminary answers with an explicit full-file pass, and every [S#] cite opens the source at the supporting passage.",
  },
  {
    title: "Primary law from official text",
    body: "Statutory and regulatory questions ground in the official sources themselves — U.S. Code section text from GovInfo, CFR sections with effective dates from eCFR — with currency caveats whenever a source can't vouch for freshness.",
  },
  {
    title: "Matter workspace",
    body: "Organize research, drafts, documents, authorities, outputs, billing, and a full audit trail by matter — with an in-app reader for saved opinions that works offline.",
  },
  {
    title: "Legislative & regulatory tracking",
    body: "Pending bills and rulemaking relevant to a question appear as clearly-labeled tracking context — sourced from the Federal Register, Regulations.gov, OpenStates, and LegiScan — and are never passed off as citable authority.",
  },
  {
    title: "Document drafting",
    body: "Draft directly inside a matter's chat: a Draft button opens a sheet for the caption parties, client, and service recipients, then renders a downloadable Word document — open it, reveal it in Finder, or save a copy. The signature block prints the bar admission that matches the filing's court. Every recited fact traces back to the matter, and unverified citations appear as visible placeholders to review before filing.",
  },
  {
    title: "Timekeeping & billing",
    body: "ScratchPad turns a day's notes and work product into reviewable, defensible time entries with UTBMS codes — exportable to LEDES 1998B, CSV, or the clipboard. Tag an entry #Note to keep it out of billing entirely; excluded notes and their attachments never reach the billing model, and the review banner reports exactly what was left out. Nothing bills automatically; every line cites its evidence.",
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
          Supra AI combines local generation with legal research, document
          intelligence, and review workflows designed for attorneys.
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
