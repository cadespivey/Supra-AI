import type { ReactNode } from "react";
import { Section } from "./Section";

/* eslint-disable @next/next/no-img-element */

type ShotProps = {
  label: string;
  title: string;
  image: string;
  alt: string;
  caption?: string;
  flip?: boolean;
  children: ReactNode;
};

function Shot({
  label,
  title,
  image,
  alt,
  caption = "No client data",
  flip = false,
  children,
}: ShotProps) {
  return (
    <div
      className={`grid items-center gap-10 lg:grid-cols-[0.8fr_1.2fr] ${
        flip ? "lg:[&>*:first-child]:order-2" : ""
      }`}
    >
      <div>
        <p className="font-caps text-xs uppercase text-supra-gold">{label}</p>
        <h3 className="mt-3 text-2xl leading-[1.2] text-supra-white">{title}</h3>
        <div className="mt-4 space-y-4 text-base leading-[1.55] text-supra-muted">
          {children}
        </div>
      </div>
      <figure className="min-w-0">
        <div className="overflow-hidden rounded-xl border border-supra-border bg-supra-navyDeep shadow-[0_24px_60px_-24px_rgba(0,0,0,0.7)]">
          <img
            src={image}
            alt={alt}
            loading="lazy"
            className="block h-auto w-full"
          />
        </div>
        <figcaption className="mt-3 text-center font-caps text-[11px] uppercase tracking-wide text-supra-muted">
          {caption}
        </figcaption>
      </figure>
    </div>
  );
}

export function ScreenshotShowcase() {
  return (
    <Section id="inside-the-app">
      <div className="space-y-24">
        <Shot
          label="Grounded answers"
          title="The answer up top, its sources right below."
          image="/screenshots/hero-grounded-chat.png"
          alt="A matter chat answering who the parties are, with the sources it relied on listed below the answer and the cited court filing open beside the conversation at the supporting page."
          caption="Public court records — no client data"
        >
          <p>
            Ask about your matter&rsquo;s documents and you get a normal chat
            answer — with every source it relied on listed right below it. Click
            one and the filing opens beside the conversation at the exact passage.
          </p>
          <p>
            Answers are honest about depth, too: a fast pass returns in seconds,
            labeled <span className="italic">Preliminary</span>, with a
            full-document search one click away. If the documents don&rsquo;t
            support an answer, Supra AI says so instead of improvising.
          </p>
        </Shot>

        <Shot
          label="Research workflow"
          title="Plan the search. Review every result. Keep what holds up."
          image="/screenshots/research-session.png"
          alt="A research session showing search queries and retrieved Supreme Court cases with review status badges, and a detail card for one case showing its citation, court, docket number, and excerpt."
          caption="Real case law"
          flip
        >
          <p>
            Research runs as an auditable session: queries you approve, then a
            keep-or-skip decision on every result. Each case carries its
            citation, court, date, docket, and matching excerpt.
          </p>
          <p>
            Saved authorities keep their full text on your Mac, so follow-up
            research answers from your own library first — offline — reaching the
            network only when you ask for a wider search.
          </p>
          <p>
            The same workflow reaches beyond case law to public records — SEC
            EDGAR filings, CFPB complaints, and NLRB records — each shown as a
            sourced filing, never a finding.
          </p>
        </Shot>

        <Shot
          label="Legal research"
          title="Read the opinion without leaving the app."
          image="/screenshots/opinion-reader.png"
          alt="The full text of a Supreme Court opinion open inside the app, with a Download HTML option."
          caption="Real case law"
        >
          <p>
            Any retrieved case — or{" "}
            <span className="text-supra-gold">[A#]</span> citation — opens as the
            full opinion inside the app: the court&rsquo;s own text, the cited
            passage highlighted, and a link to the case on CourtListener.
          </p>
          <p>
            Cited answers are verified against that same text: an unsupported
            cite is flagged, or the answer blocked, before you rely on it.
          </p>
        </Shot>

        <Shot
          label="Local models"
          title="The models live on your Mac — and you're in charge of them."
          image="/screenshots/models.png"
          alt="The Models tab showing registered local MLX models assigned to legal reasoning, drafting, and critique tasks, with a loaded runtime."
          flip
        >
          <p>
            Download open-weight MLX models once and assign them per task —
            reasoning for research, an instruct model for drafting, a critic for
            review. They run on your Apple Silicon; nothing leaves for a cloud
            model.
          </p>
          <p>
            That&rsquo;s the whole subscription story: hardware you own running
            models you chose, with nothing metered and no account behind it.
          </p>
        </Shot>
      </div>
    </Section>
  );
}
