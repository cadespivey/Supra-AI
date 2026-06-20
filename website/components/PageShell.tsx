import type { ReactNode } from "react";

type PageShellProps = {
  eyebrow?: string;
  title: string;
  intro: string;
  children: ReactNode;
};

export function PageShell({ eyebrow, title, intro, children }: PageShellProps) {
  return (
    <main>
      <section className="border-b border-supra-border bg-supra-navyDeep px-6 py-20 sm:py-24">
        <div className="mx-auto max-w-6xl">
          {eyebrow ? (
            <p className="font-caps text-xs uppercase text-supra-gold">
              {eyebrow}
            </p>
          ) : null}
          <h1 className="mt-4 max-w-[18ch] text-3xl leading-[1.12] text-supra-white sm:text-4xl">
            {title}
          </h1>
          <p className="measure-wide mt-6 text-xl leading-[1.5] text-supra-muted">
            {intro}
          </p>
        </div>
      </section>
      <section className="px-6 py-20 sm:py-24">
        <div className="mx-auto max-w-6xl">{children}</div>
      </section>
    </main>
  );
}
