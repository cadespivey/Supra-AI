import Link from "next/link";
import {
  GITHUB_ISSUES_URL,
  GITHUB_RELEASES_URL,
  GITHUB_REPO_URL,
} from "@/lib/constants";
import { FeedbackWarning } from "./FeedbackWarning";

const productLinks = [
  { href: "/product", label: "Overview" },
  { href: "/download", label: "Download" },
  { href: GITHUB_RELEASES_URL, label: "Releases" },
];

const trustLinks = [
  { href: "/privacy-security", label: "Privacy & Security" },
  { href: "/disclaimer", label: "Disclaimer" },
  { href: "/privacy", label: "Privacy Policy" },
  { href: "/terms", label: "Terms" },
];

function FooterLink({ href, label }: { href: string; label: string }) {
  return (
    <Link
      href={href}
      className="text-sm leading-7 text-supra-muted transition-colors hover:text-supra-gold"
    >
      {label}
    </Link>
  );
}

export function SiteFooter() {
  const year = new Date().getFullYear();

  return (
    <footer className="border-t border-supra-border bg-supra-navyDeep px-6 py-16">
      <div className="mx-auto grid max-w-6xl gap-12 lg:grid-cols-[1.3fr_2fr]">
        <div>
          <Link
            href="/"
            className="text-3xl font-bold text-supra-white transition-colors hover:text-supra-gold"
          >
            Supra AI
          </Link>
          <p className="mt-4 max-w-sm text-lg text-supra-white">
            Secure legal AI without compromise.
          </p>
          <p className="mt-2 text-xl italic text-supra-gold">See Supra.</p>
          <p className="mt-8 text-sm text-supra-muted">
            © {year} Cade Spivey. All rights reserved.
          </p>
        </div>

        <div className="grid gap-10 sm:grid-cols-3">
          <div>
            <h2 className="font-caps text-xs font-bold uppercase text-supra-white">
              Product
            </h2>
            <div className="mt-4 flex flex-col">
              {productLinks.map((link) => (
                <FooterLink key={link.href} {...link} />
              ))}
            </div>
          </div>

          <div>
            <h2 className="font-caps text-xs font-bold uppercase text-supra-white">
              Trust
            </h2>
            <div className="mt-4 flex flex-col">
              {trustLinks.map((link) => (
                <FooterLink key={link.href} {...link} />
              ))}
            </div>
          </div>

          <div>
            <h2 className="font-caps text-xs font-bold uppercase text-supra-white">
              Project
            </h2>
            <div className="mt-4 flex flex-col">
              <FooterLink href={GITHUB_REPO_URL} label="GitHub" />
            </div>
            <div className="mt-5">
              <FeedbackWarning compact />
              <Link
                href={GITHUB_ISSUES_URL}
                className="mt-4 inline-flex text-sm text-supra-gold underline-offset-4 transition hover:underline"
              >
                Issues
              </Link>
            </div>
          </div>
        </div>
      </div>
    </footer>
  );
}
