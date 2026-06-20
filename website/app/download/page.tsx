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
    body: "Opens a disk image; drag Supra AI into your Applications folder. The standard macOS install.",
  },
  {
    label: ".zip",
    body: "Unzips straight to the Supra AI app — move it into Applications yourself. Handy for scripted or managed setups.",
  },
];

function Panel({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="rounded-2xl border border-supra-border bg-supra-navyPanel p-6">
      <h2 className="text-2xl text-supra-white">{title}</h2>
      {children}
    </section>
  );
}

export default function DownloadPage() {
  return (
    <PageShell
      eyebrow="Download"
      title="Download Supra AI for macOS"
      intro="Supra AI is a public beta for legal professionals on Apple Silicon Macs. Choose the format you prefer — both contain the same app."
    >
      <div className="grid gap-5">
        <section className="rounded-2xl border border-supra-gold/40 bg-supra-navyPanelLight p-7">
          <p className="font-caps text-xs font-bold uppercase text-supra-gold">
            Get Supra AI
          </p>
          <h2 className="mt-3 text-3xl text-supra-white">
            Choose your download
          </h2>
          <div className="mt-6">
            <DownloadButtons />
          </div>

          <div className="mt-7 grid gap-4 border-t border-supra-border pt-6 sm:grid-cols-2">
            {formats.map((format) => (
              <div key={format.label}>
                <p className="font-caps text-xs font-bold uppercase text-supra-gold">
                  {format.label}
                </p>
                <p className="mt-2 text-sm leading-7 text-supra-muted">
                  {format.body}
                </p>
              </div>
            ))}
          </div>

          <div className="mt-6 flex flex-wrap gap-5 border-t border-supra-border pt-6">
            <Link
              href={GITHUB_RELEASES_URL}
              className="text-supra-gold underline-offset-4 hover:underline"
            >
              All releases &amp; changelog
            </Link>
            <Link
              href={GITHUB_REPO_URL}
              className="text-supra-gold underline-offset-4 hover:underline"
            >
              View source code
            </Link>
          </div>
        </section>

        <div className="grid gap-5 lg:grid-cols-2">
          <Panel title="Requirements">
            <ul className="mt-5 space-y-3">
              {requirements.map((item) => (
                <li key={item} className="flex gap-3 text-supra-muted">
                  <span className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-supra-gold" />
                  <span>{item}</span>
                </li>
              ))}
            </ul>
          </Panel>

          <Panel title="Guided setup">
            <ol className="mt-5 space-y-3">
              {setupSteps.map((item, index) => (
                <li key={item} className="flex gap-3 text-supra-muted">
                  <span className="font-caps text-xs text-supra-gold">
                    {String(index + 1).padStart(2, "0")}
                  </span>
                  <span>{item}</span>
                </li>
              ))}
            </ol>
          </Panel>
        </div>

        <section>
          <h2 className="mb-5 text-2xl text-supra-white">Beta feedback</h2>
          <FeedbackWarning />
          <Link
            href={GITHUB_ISSUES_URL}
            className="mt-5 inline-flex text-supra-gold underline-offset-4 hover:underline"
          >
            Report an issue on GitHub
          </Link>
        </section>
      </div>
    </PageShell>
  );
}
