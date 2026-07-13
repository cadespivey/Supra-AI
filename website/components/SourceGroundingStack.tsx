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
      <div className="grid gap-x-12 gap-y-8 lg:grid-cols-[0.9fr_1.1fr] lg:items-center">
        <div>
          <p className="font-caps text-xs uppercase text-supra-gold">
            Source grounding
          </p>
          <h2 className="mt-3 text-3xl leading-[1.15] text-supra-white">
            See Supra.
          </h2>
          <p className="measure mt-4 text-lg leading-[1.5] text-supra-muted">
            In legal writing, <span className="italic">supra</span> points to
            authority already on the page. Supra AI works the same way: an answer
            remains linked to the source behind it.
          </p>
        </div>

        <div className="space-y-4">
          <StackLayer label="01" title="The answer">
            Responses read like an ordinary chat answer — clear prose, not a wall
            of hedged citations.
          </StackLayer>

          <div aria-hidden="true" className="ml-px h-3 w-px bg-supra-gold/70" />

          <StackLayer label="02" title="Its sources, right below">
            Every source behind the answer is listed beneath it, each linking to
            the exact passage of the document or opinion it came from.
          </StackLayer>
        </div>
      </div>
    </Section>
  );
}
