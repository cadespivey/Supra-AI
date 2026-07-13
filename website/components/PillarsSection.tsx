import { Section } from "./Section";

const pillars = [
  {
    label: "Privacy",
    title: "Your file stays local for processing.",
    points: [
      "Generation, indexing, embeddings, and drafting run locally on Apple Silicon; the app does not attach prompts, documents, or work product to cloud-generation requests.",
      "Supra AI has no cloud-generation or training backend. Local models arrive pre-trained and change when you install a provider version.",
      "Outbound paths are named and tested: provider-specific research requests, model metadata/artifact downloads, opinion downloads, and signed update checks/downloads.",
      "Research queries are privileged work product, so even the app's own network log redacts query terms by default.",
    ],
  },
  {
    label: "Security",
    title: "Built like it holds a client file — because it does.",
    points: [
      "Sandboxed, hardened-runtime, and notarized by Apple. The model runtime runs in a separate isolated process.",
      "Application research networking is default-deny and provider-scoped. The application contains no analytics or telemetry client.",
      "Release builds read optional provider credentials from the device-bound macOS Keychain and scope them to the matching provider.",
    ],
  },
  {
    label: "No subscriptions",
    title: "No account. No seat license. No meter running.",
    points: [
      "Download the app and use it. There is nothing to sign up for, no monthly bill, and no per-token charge — the models run on hardware you already own.",
      "Research is built on free public legal data. A free CourtListener account unlocks case-law search; other sources need no key at all or offer free keys you control.",
      "There is no Supra AI account, cloud work store, or usage-metering backend.",
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
