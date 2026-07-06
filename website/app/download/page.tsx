import Link from "next/link";
import type { ReactNode } from "react";
import { DownloadButtons } from "@/components/DownloadButtons";
import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";
import { GITHUB_ISSUES_URL, GITHUB_RELEASES_URL, GITHUB_REPO_URL } from "@/lib/constants";

const requirements = [
  "macOS 15 (Sequoia) or later",
  "Apple Silicon Mac (M1 or newer)",
  "Free disk space for local model weights",
  "Optional CourtListener API token for legal research",
];

const setupSteps = [
  "Check requirements",
  "Download and open the app",
  "Install local models on first launch",
  "Add a CourtListener token (optional)",
  "Open your first matter",
];

const formats = [
  {
    label: ".dmg",
    body: "Recommended. Opens a disk image; drag Supra AI into your Applications folder — the standard macOS install.",
  },
  {
    label: ".zip",
    body: "Unzips straight to the Supra AI app — move it into Applications yourself. Handy for scripted or managed setups.",
  },
];

function Panel({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="border-t border-supra-border pt-6">
      <h2 className="text-xl text-supra-white">{title}</h2>
      {children}
    </section>
  );
}

export default function DownloadPage() {
  return (
    <PageShell
      eyebrow="Download"
      title="Download Supra AI for macOS"
      intro="Supra AI runs on Apple Silicon Macs. Choose the format you prefer — both contain the same app."
    >
      <div className="space-y-12">
        <section className="border-t-2 border-supra-gold/60 pt-7">
          <p className="font-caps text-xs uppercase text-supra-gold">
            Get Supra AI
          </p>
          <h2 className="mt-3 text-2xl text-supra-white">Choose your download</h2>
          <div className="mt-6">
            <DownloadButtons />
          </div>

          <dl className="mt-8 grid gap-x-10 gap-y-5 sm:grid-cols-2">
            {formats.map((format) => (
              <div key={format.label}>
                <dt className="font-caps text-xs uppercase text-supra-gold">
                  {format.label}
                </dt>
                <dd className="mt-2 text-base leading-[1.55] text-supra-muted">
                  {format.body}
                </dd>
              </div>
            ))}
          </dl>

          <div className="mt-8 flex flex-wrap gap-x-8 gap-y-2">
            <Link href={GITHUB_RELEASES_URL} className="link link-ref">
              All releases &amp; changelog
            </Link>
            <Link href={GITHUB_REPO_URL} className="link link-ref">
              View source code
            </Link>
          </div>
        </section>

        <div className="grid gap-x-12 gap-y-12 lg:grid-cols-2">
          <Panel title="Requirements">
            <ul className="mt-5 space-y-3">
              {requirements.map((item) => (
                <li
                  key={item}
                  className="flex gap-3 text-base leading-[1.5] text-supra-muted"
                >
                  <span className="mt-2.5 h-1.5 w-1.5 shrink-0 rounded-full bg-supra-gold" />
                  <span>{item}</span>
                </li>
              ))}
            </ul>
          </Panel>

          <Panel title="Guided setup">
            <ol className="mt-5 space-y-3">
              {setupSteps.map((item, index) => (
                <li
                  key={item}
                  className="flex gap-4 text-base leading-[1.5] text-supra-muted"
                >
                  <span className="font-caps text-xs text-supra-gold">
                    {String(index + 1).padStart(2, "0")}
                  </span>
                  <span>{item}</span>
                </li>
              ))}
            </ol>
          </Panel>
        </div>

        <section className="border-t border-supra-border pt-6">
          <h2 className="text-xl text-supra-white">Feedback</h2>
          <div className="mt-5">
            <FeedbackWarning />
          </div>
          <Link
            href={GITHUB_ISSUES_URL}
            className="link link-ref mt-5 inline-block"
          >
            Report an issue on GitHub
          </Link>
        </section>
      </div>
    </PageShell>
  );
}
