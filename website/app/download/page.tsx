import Link from "next/link";
import type { ReactNode } from "react";
import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";
import {
  DOWNLOAD_DMG_URL,
  DOWNLOAD_ZIP_URL,
  GITHUB_ISSUES_URL,
  GITHUB_RELEASES_URL,
  GITHUB_REPO_URL,
} from "@/lib/constants";

const requirements = [
  "macOS 15+",
  "Apple Silicon Mac",
  "Local model weights",
  "Optional CourtListener API token for legal research",
];

const setupSteps = [
  "Check requirements",
  "Download the app",
  "Install local models",
  "Configure CourtListener, optional",
  "Start a matter",
];

function Panel({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="rounded-2xl border border-supra-border bg-supra-navyPanel p-6">
      <h2 className="text-2xl text-supra-white">{title}</h2>
      {children}
    </section>
  );
}

function ActionLink({
  href,
  children,
  primary = false,
}: {
  href: string;
  children: ReactNode;
  primary?: boolean;
}) {
  return (
    <Link
      href={href}
      className={`inline-flex rounded-xl border px-5 py-3 text-base transition ${
        primary
          ? "border-supra-gold bg-supra-gold text-supra-navyDeep hover:bg-supra-white"
          : "border-supra-border text-supra-white hover:border-supra-gold hover:text-supra-gold"
      }`}
    >
      {children}
    </Link>
  );
}

export default function DownloadPage() {
  return (
    <PageShell
      eyebrow="Download"
      title="Download Supra AI for macOS"
      intro="Supra AI is available as a public beta for legal professionals using Apple Silicon Macs."
    >
      <div className="grid gap-5 lg:grid-cols-2">
        <Panel title="Requirements">
          <ul className="mt-5 space-y-3">
            {requirements.map((item) => (
              <li key={item} className="flex gap-3 text-supra-muted">
                <span className="mt-2 h-1.5 w-1.5 rounded-full bg-supra-gold" />
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

        <Panel title="Download actions">
          <div className="mt-5 flex flex-wrap gap-3">
            <ActionLink href={DOWNLOAD_DMG_URL} primary>
              Download .dmg for macOS
            </ActionLink>
            <ActionLink href={DOWNLOAD_ZIP_URL}>Download .zip</ActionLink>
          </div>
          <div className="mt-6 flex flex-wrap gap-5">
            <Link
              href={GITHUB_RELEASES_URL}
              className="text-supra-gold underline-offset-4 hover:underline"
            >
              View GitHub Releases
            </Link>
            <Link
              href={GITHUB_REPO_URL}
              className="text-supra-gold underline-offset-4 hover:underline"
            >
              View Source Code
            </Link>
          </div>
        </Panel>

        <section className="p-1">
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
