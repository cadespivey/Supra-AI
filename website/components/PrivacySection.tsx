import { Section } from "./Section";

export function PrivacySection() {
  return (
    <Section className="bg-supra-navyDeep">
      <p className="font-caps text-xs uppercase text-supra-gold">
        Privacy architecture
      </p>
      <h2 className="mt-4 max-w-[24ch] text-3xl leading-[1.15] text-supra-white">
        Legal AI should not require surrendering the file.
      </h2>
      <p className="measure-wide mt-6 text-lg leading-[1.5] text-supra-muted">
        Supra AI is designed around a local trust boundary: your app, your
        models, your matter documents, and your generated work stay on your Mac.
        CourtListener research is the limited network exception when you choose
        to use it.
      </p>
    </Section>
  );
}
