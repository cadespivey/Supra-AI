import { Section } from "./Section";

const pillars = [
  {
    label: "Privacy",
    title: "Your file never leaves the building.",
    points: [
      "Generation, document indexing, embeddings, and drafting all run locally on Apple Silicon. Prompts, matter documents, and work product are never sent to a cloud model.",
      "The only network traffic is what you can point to: model downloads, the legal-data lookups described below, and the update check. Legal research requests carry search terms — never your documents.",
      "Research queries are privileged work product, so even the app's own network log redacts query terms by default.",
    ],
  },
  {
    label: "Security",
    title: "Built like it holds a client file — because it does.",
    points: [
      "Sandboxed, hardened-runtime, and notarized by Apple. The model runtime runs in a separate isolated process.",
      "Networking is default-deny: the app can only reach a short allow-list of official legal-data hosts. There is no analytics endpoint, no telemetry, and nothing phoning home.",
      "Your optional API keys live in the macOS Keychain — never in files, never bundled, never transmitted anywhere but the provider they belong to.",
    ],
  },
  {
    label: "No subscriptions",
    title: "No account. No seat license. No meter running.",
    points: [
      "Download the app and use it. There is nothing to sign up for, no monthly bill, and no per-token charge — the models run on hardware you already own.",
      "Research is built on free public legal data. A free CourtListener account unlocks case-law search; other sources need no key at all or offer free keys you control.",
      "Your data never becomes the product: there's no account to profile and no usage to mine.",
    ],
  },
];

export function PillarsSection() {
  return (
    <Section className="bg-supra-navyDeep" id="pillars">
      <div className="measure-wide">
        <p className="font-caps text-xs uppercase text-supra-gold">
          Why it&rsquo;s different
        </p>
        <h2 className="mt-4 text-3xl leading-[1.15] text-supra-white">
          Legal AI should not require surrendering the file — or renting it
          back.
        </h2>
      </div>

      <div className="mt-14 grid gap-x-10 gap-y-12 lg:grid-cols-3">
        {pillars.map((pillar) => (
          <article
            key={pillar.label}
            className="border-t-2 border-supra-gold/60 pt-6"
          >
            <p className="font-caps text-xs uppercase text-supra-gold">
              {pillar.label}
            </p>
            <h3 className="mt-3 text-xl leading-[1.3] text-supra-white">
              {pillar.title}
            </h3>
            <ul className="mt-4 space-y-3">
              {pillar.points.map((point) => (
                <li
                  key={point}
                  className="border-l border-supra-border pl-4 text-base leading-[1.55] text-supra-muted"
                >
                  {point}
                </li>
              ))}
            </ul>
          </article>
        ))}
      </div>
    </Section>
  );
}
