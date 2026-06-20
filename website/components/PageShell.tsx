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
            <p className="font-caps text-xs font-bold uppercase text-supra-gold">
              {eyebrow}
            </p>
          ) : null}
          <h1 className="mt-4 max-w-4xl text-5xl leading-tight text-supra-white sm:text-6xl">
            {title}
          </h1>
          <p className="mt-6 max-w-3xl text-lg leading-8 text-supra-muted sm:text-xl">
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
