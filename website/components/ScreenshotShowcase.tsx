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
  caption = "Actual app — no client data",
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
      <div className="measure-wide">
        <p className="font-caps text-xs uppercase text-supra-gold">
          Inside the app
        </p>
        <h2 className="mt-4 text-3xl leading-[1.15] text-supra-white">
          See what&rsquo;s behind the curtain before you download.
        </h2>
        <p className="mt-6 text-lg leading-[1.5] text-supra-muted">
          Every screenshot below is the real application working a demonstration
          matter built from <span className="italic">public court records</span>{" "}
          and real case law — no client data anywhere.
        </p>
      </div>

      <div className="mt-16 space-y-24">
        <Shot
          label="Grounded answers"
          title="Every assertion carries a clickable citation."
          image="/screenshots/hero-grounded-chat.png"
          alt="A matter chat answering who the parties are, citing [S2] and [S3] document sources, with the cited court filing open beside the conversation at the supporting page."
          caption="Actual app · public court records — no client data"
        >
          <p>
            Ask about your matter&rsquo;s documents and the answer is built only
            from retrieved passages — each one cited inline as{" "}
            <span className="text-supra-gold">[S2]</span>,{" "}
            <span className="text-supra-gold">[S3]</span>, and so on. Click a
            citation and the filing itself opens beside the conversation at the
            cited page.
          </p>
          <p>
            Answers are honest about their depth, too: a fast pass over the most
            relevant passages comes back in seconds, labeled{" "}
            <span className="italic">Preliminary</span>, with a full search of
            every document one click away. If the documents don&rsquo;t support
            an answer, Supra AI says so instead of improvising one.
          </p>
        </Shot>

        <Shot
          label="Research workflow"
          title="Plan the search. Review every result. Keep what holds up."
          image="/screenshots/research-session.png"
          alt="A research session showing search queries and retrieved Supreme Court cases with review status badges, and a detail card for one case showing its citation, court, docket number, and excerpt."
          caption="Actual app · real case law"
          flip
        >
          <p>
            Research runs as an auditable session: real search queries you
            approve, and an explicit review decision on every result — saved to
            the matter&rsquo;s authority library, marked potentially adverse, or
            skipped. Each case carries its citation, court, date, docket, and
            the matching excerpt.
          </p>
          <p>
            Authorities you save keep their full text on your Mac, so follow-up
            research answers from your own library first — offline — and only
            reaches for the network when you ask for a wider search.
          </p>
        </Shot>

        <Shot
          label="Legal research"
          title="Read the opinion without leaving the app."
          image="/screenshots/opinion-reader.png"
          alt="The full text of a Supreme Court opinion open inside the app, with a Download HTML option."
          caption="Actual app · real case law"
        >
          <p>
            Any retrieved case — and any{" "}
            <span className="text-supra-gold">[A#]</span> citation in a research
            answer — opens as the full opinion inside the app: the court&rsquo;s
            own text, the cited passage highlighted, a download option, and a
            one-click path to the case on CourtListener.
          </p>
          <p>
            Cited answers are verified against this same retrieved text. A cite
            the sources don&rsquo;t support is flagged — or the answer is
            blocked outright — before you ever rely on it.
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
            deep reasoning for research, an instruct model for drafting, a
            critic for review. The runtime loads them on your Apple Silicon; no
            prompt or document ever leaves for a cloud model.
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
