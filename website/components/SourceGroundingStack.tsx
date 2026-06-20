import { Section } from "./Section";
import type { ReactNode } from "react";

function StackCard({
  label,
  title,
  children,
}: {
  label: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <article className="rounded-2xl border border-supra-border bg-supra-navyPanel p-6">
      <p className="font-caps text-xs font-bold uppercase text-supra-gold">
        {label}
      </p>
      <h3 className="mt-3 text-2xl text-supra-white">{title}</h3>
      <p className="mt-3 text-base leading-7 text-supra-muted">{children}</p>
    </article>
  );
}

export function SourceGroundingStack() {
  return (
    <Section className="bg-supra-navyDeep">
      <div className="grid gap-12 lg:grid-cols-[0.9fr_1.1fr] lg:items-center">
        <div>
          <p className="font-caps text-xs font-bold uppercase text-supra-gold">
            Source grounding
          </p>
          <h2 className="mt-4 text-4xl leading-tight text-supra-white sm:text-5xl">
            See Supra.
          </h2>
          <p className="mt-6 text-lg leading-8 text-supra-muted">
            In legal writing, supra points back to authority already supplied
            above. Supra AI applies the same principle to legal AI: the answer
            should never be severed from the source that supports it.
          </p>
        </div>

        <div className="relative space-y-4">
          <StackCard label="Layer 1" title="Authority above">
            Retrieved authority, document excerpts, and source material remain
            visible before the analysis that depends on them.
          </StackCard>

          <div
            aria-hidden="true"
            className="mx-auto h-8 w-px bg-supra-gold/70"
          />

          <StackCard label="Layer 2" title="Answer below">
            The response is framed as analysis tied to the source packet, not as
            an unsupported assertion from model memory.
          </StackCard>

          <div className="rounded-2xl border border-supra-border bg-supra-navyPanelLight p-4">
            <p className="text-base italic text-supra-muted">
              Ask a legal question, draft from a matter file, or verify a
              proposition...
            </p>
          </div>
        </div>
      </div>
    </Section>
  );
}
