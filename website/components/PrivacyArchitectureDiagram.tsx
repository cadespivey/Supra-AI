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
          <p className="font-caps text-xs font-bold uppercase text-supra-gold">
            Privacy architecture
          </p>
          <h2 className="mt-4 text-4xl leading-tight text-supra-white sm:text-5xl">
            Legal AI should not require surrendering the file.
          </h2>
          <p className="mt-6 text-lg leading-8 text-supra-muted">
            Supra AI is designed around a local trust boundary: your app, your
            models, your matter documents, and your generated work stay on your
            Mac. CourtListener research is the limited network exception when
            you choose to use it.
          </p>
        </div>

        <div className="rounded-3xl border border-supra-gold/50 bg-supra-navy p-5 sm:p-7">
          <div className="flex items-center justify-between border-b border-supra-border pb-4">
            <h3 className="font-caps text-xs font-bold uppercase text-supra-gold">
              Your Mac
            </h3>
            <span className="text-sm text-supra-muted">Local boundary</span>
          </div>

          <div className="mt-6 grid gap-4 sm:grid-cols-2">
            {localItems.map((item, index) => (
              <div
                key={item}
                className={`rounded-2xl border border-supra-border bg-supra-navyPanel p-4 text-supra-white ${
                  index === 0 ? "sm:col-span-2" : ""
                }`}
              >
                {item}
              </div>
            ))}
          </div>

          <div className="mt-8 flex flex-col gap-4 sm:flex-row sm:items-center">
            <div
              aria-hidden="true"
              className="h-px flex-1 border-t border-dashed border-supra-gold"
            />
            <div className="rounded-2xl border border-supra-border bg-supra-navyDeep p-4">
              <p className="font-caps text-xs font-bold uppercase text-supra-gold">
                Outside boundary
              </p>
              <p className="mt-2 text-supra-white">
                CourtListener research only
              </p>
            </div>
          </div>
        </div>
      </div>
    </Section>
  );
}
