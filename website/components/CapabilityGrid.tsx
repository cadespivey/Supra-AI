import { Section } from "./Section";

const capabilities = [
  {
    title: "Source-grounded research",
    body: "Research workflows are designed around retrieved source material, not unsupported model memory.",
  },
  {
    title: "Citation verification",
    body: "Citation-sensitive outputs are built for review, verification, and correction before reliance.",
  },
  {
    title: "Document intelligence",
    body: "Import matter documents, extract facts, ask questions, and keep answers tied to source material.",
  },
  {
    title: "Matter workspace",
    body: "Organize research, drafts, documents, outputs, and review artifacts by matter.",
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
