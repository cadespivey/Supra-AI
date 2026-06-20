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
];

export function CapabilityGrid() {
  return (
    <Section>
      <div className="max-w-3xl">
        <p className="font-caps text-xs font-bold uppercase text-supra-gold">
          Capabilities
        </p>
        <h2 className="mt-4 text-4xl leading-tight text-supra-white sm:text-5xl">
          Built for legal work that stays grounded.
        </h2>
        <p className="mt-6 text-lg leading-8 text-supra-muted">
          Supra AI combines local generation with legal research, document
          intelligence, and review workflows designed for attorneys.
        </p>
      </div>

      <div className="mt-12 grid gap-5 lg:grid-cols-[0.95fr_1.3fr]">
        <article className="rounded-2xl border border-supra-gold/40 bg-supra-navyPanelLight p-8">
          <p className="font-caps text-xs font-bold uppercase text-supra-gold">
            Featured
          </p>
          <h3 className="mt-5 text-3xl text-supra-white">Local generation</h3>
          <p className="mt-5 text-lg leading-8 text-supra-muted">
            Supra AI runs models locally on Apple Silicon, so your files and
            prompts do not need to leave your Mac for generation.
          </p>
          <div
            aria-hidden="true"
            className="mt-10 grid grid-cols-3 gap-3 border-t border-supra-border pt-6"
          >
            <div className="h-14 rounded-xl border border-supra-border bg-supra-navy" />
            <div className="h-14 rounded-xl border border-supra-border bg-supra-navy" />
            <div className="h-14 rounded-xl border border-supra-border bg-supra-navy" />
          </div>
        </article>

        <div className="grid gap-5 sm:grid-cols-2">
          {capabilities.map((item) => (
            <article
              key={item.title}
              className="rounded-2xl border border-supra-border bg-supra-navyPanel p-6"
            >
              <h3 className="text-2xl text-supra-white">{item.title}</h3>
              <p className="mt-4 text-base leading-7 text-supra-muted">
                {item.body}
              </p>
            </article>
          ))}
        </div>
      </div>
    </Section>
  );
}
