import { Section } from "./Section";
import type { ReactNode } from "react";

function StackLayer({
  label,
  title,
  children,
}: {
  label: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <article className="border-l-2 border-supra-border pl-5">
      <p className="font-caps text-xs uppercase text-supra-gold">{label}</p>
      <h3 className="mt-2 text-xl text-supra-white">{title}</h3>
      <p className="mt-2 text-base leading-[1.55] text-supra-muted">{children}</p>
    </article>
  );
}

export function SourceGroundingStack() {
  return (
    <Section className="bg-supra-navyDeep">
      <div className="grid gap-12 lg:grid-cols-[0.9fr_1.1fr] lg:items-center">
        <div>
          <p className="font-caps text-xs uppercase text-supra-gold">
            Source grounding
          </p>
          <h2 className="mt-4 text-3xl leading-[1.15] text-supra-white">
            See Supra.
          </h2>
          <p className="measure mt-6 text-lg leading-[1.5] text-supra-muted">
            In legal writing, <span className="italic">supra</span> points back
            to authority already supplied above. Supra AI applies the same
            principle to legal AI: the answer should never be severed from the
            source that supports it.
          </p>
        </div>

        <div className="space-y-6">
          <StackLayer label="Layer 1" title="Authority above">
            Retrieved authority, document excerpts, and source material remain
            visible before the analysis that depends on them.
          </StackLayer>

          <div aria-hidden="true" className="ml-px h-6 w-px bg-supra-gold/70" />

          <StackLayer label="Layer 2" title="Answer below">
            The response is framed as analysis tied to the source packet, not as
            an unsupported assertion from model memory.
          </StackLayer>

          <div className="rule pt-6">
            <p className="font-caps text-xs uppercase text-supra-gold">
              Example
            </p>
            <p className="mt-3 text-lg italic leading-[1.5] text-supra-white">
              {"“Does the implied warranty of habitability cover this defect?”"}
            </p>
            <p className="mt-3 text-base leading-[1.55] text-supra-muted">
              Analysis grounded in the excerpts above, with each proposition
              tied to the source that supports it.
            </p>
            <p className="mt-4 font-caps text-xs uppercase text-supra-muted">
              Cited — source&nbsp;§ · matter document
            </p>
          </div>
        </div>
      </div>
    </Section>
  );
}
