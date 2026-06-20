import { Section } from "./Section";

const localItems = [
  "Supra AI app",
  "Local MLX runtime",
  "Matter documents",
  "Local embeddings",
  "Source-grounded workspace",
];

export function PrivacyArchitectureDiagram() {
  return (
    <Section className="bg-supra-navyDeep">
      <div className="grid gap-12 lg:grid-cols-[0.9fr_1.1fr] lg:items-center">
        <div>
          <p className="font-caps text-xs uppercase text-supra-gold">
            Privacy architecture
          </p>
          <h2 className="mt-4 text-3xl leading-[1.15] text-supra-white">
            Legal AI should not require surrendering the file.
          </h2>
          <p className="measure mt-6 text-lg leading-[1.5] text-supra-muted">
            Supra AI is designed around a local trust boundary: your app, your
            models, your matter documents, and your generated work stay on your
            Mac. CourtListener research is the limited network exception when
            you choose to use it.
          </p>
        </div>

        <div className="rounded-md border border-supra-gold/40 p-6 sm:p-8">
          <div className="flex items-baseline justify-between border-b border-supra-border pb-4">
            <h3 className="font-caps text-xs uppercase text-supra-gold">
              Your Mac
            </h3>
            <span className="font-caps text-xs uppercase text-supra-muted">
              Local boundary
            </span>
          </div>

          <ul className="mt-2">
            {localItems.map((item) => (
              <li
                key={item}
                className="border-b border-supra-border py-3 text-supra-white"
              >
                {item}
              </li>
            ))}
          </ul>

          <div className="mt-6 flex items-center gap-4">
            <div
              aria-hidden="true"
              className="h-px flex-1 border-t border-dashed border-supra-gold/70"
            />
            <p className="font-caps text-xs uppercase text-supra-muted">
              Outside · CourtListener research only
            </p>
          </div>
        </div>
      </div>
    </Section>
  );
}
