import type { ReactNode } from "react";
import { Section } from "./Section";

/* eslint-disable @next/next/no-img-element */

type ShotProps = {
  label: string;
  title: string;
  image: string;
  alt: string;
  flip?: boolean;
  children: ReactNode;
};

function Shot({ label, title, image, alt, flip = false, children }: ShotProps) {
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
          Actual app · fictitious demonstration matter — no client data
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
          Every screenshot below is the real application working a{" "}
          <span className="italic">fictitious</span> demonstration matter. The
          case law is real; the parties, clients, and documents are invented.
        </p>
      </div>

      <div className="mt-16 space-y-24">
        <Shot
          label="Grounded answers"
          title="Every assertion carries a clickable citation."
          image="/screenshots/hero-grounded-chat.png"
          alt="A matter chat answer citing [S1]–[S3] document sources, with the cited Master Services Agreement open in a side panel and the indemnification clause highlighted."
        >
          <p>
            Ask about your matter&rsquo;s documents and the answer is built only
            from retrieved passages — each one cited inline as{" "}
            <span className="text-supra-gold">[S1]</span>,{" "}
            <span className="text-supra-gold">[S2]</span>, and so on. Click a
            citation and the source opens beside the conversation, jumped to the
            exact passage with the supporting language highlighted.
          </p>
          <p>
            If the documents don&rsquo;t support an answer, Supra AI says so
            instead of improvising one.
          </p>
        </Shot>

        <Shot
          label="Legal research"
          title="Read the opinion without leaving the app."
          image="/screenshots/opinion-reader.png"
          alt="A research answer citing [A1], with the full text of Winter v. Natural Resources Defense Council open in the reader panel and the cited holding highlighted."
          flip
        >
          <p>
            Research answers cite retrieved authority as{" "}
            <span className="text-supra-gold">[A1]</span>,{" "}
            <span className="text-supra-gold">[A2]</span> — never model memory.
            Click a cite to read the full opinion in place, with the cited
            passage highlighted and a one-click path to the case on
            CourtListener.
          </p>
          <p>
            Authorities you save to a matter keep their full text on your Mac,
            so the reader — and follow-up research — work offline. New questions
            answer from your saved library first and only reach for the network
            when you ask for a wider search.
          </p>
        </Shot>

        <Shot
          label="Document intelligence"
          title="Your matter file, indexed and ready to answer."
          image="/screenshots/documents.png"
          alt="The Documents tab showing folders, tagged documents with processing status, and row actions for preview, open, move, and share."
        >
          <p>
            Import the file and Supra AI extracts, indexes, and classifies each
            document on your machine. Organize with folders and tags, preview
            with the cited page in view, open and edit in your default apps, and
            share or export in bulk when production calls for it.
          </p>
          <p>
            Answers arrive fast from the most relevant passages first, with an
            explicit full-file search one click away — the app tells you which
            pass produced what.
          </p>
        </Shot>

        <Shot
          label="Research workflow"
          title="Plan the search. Review every result. Keep what holds up."
          image="/screenshots/research-session.png"
          alt="A research session showing model-planned search queries and retrieved cases with review actions: save as authority, mark potentially adverse, skip."
          flip
        >
          <p>
            Research runs as an auditable session: the local model proposes real
            search queries, you approve them, and every result gets an explicit
            review decision — saved to the matter&rsquo;s authority library,
            flagged potentially adverse, or skipped.
          </p>
          <p>
            Generated answers are then verified against that packet. A cite the
            sources don&rsquo;t support is flagged — or the answer is blocked
            outright — before you ever rely on it.
          </p>
        </Shot>
      </div>
    </Section>
  );
}
