import Link from "next/link";
import {
  GITHUB_ISSUES_URL,
  GITHUB_RELEASES_URL,
  GITHUB_REPO_URL,
} from "@/lib/constants";

const LICENSE_URL = `${GITHUB_REPO_URL}/blob/main/LICENSE`;

const productLinks = [
  { href: "/product", label: "Overview" },
  { href: "/download", label: "Download" },
  { href: GITHUB_RELEASES_URL, label: "Releases" },
];

const trustLinks = [
  { href: "/privacy-security", label: "Privacy & Security" },
  { href: "/privacy", label: "Privacy Policy" },
  { href: "/legal", label: "Terms & Disclaimer" },
];

const projectLinks = [
  { href: GITHUB_REPO_URL, label: "GitHub" },
  { href: GITHUB_ISSUES_URL, label: "Issues" },
  { href: LICENSE_URL, label: "MIT License" },
];

function FooterLink({ href, label }: { href: string; label: string }) {
  return (
    <Link href={href} className="link-quiet text-sm leading-7">
      {label}
    </Link>
  );
}

export function SiteFooter() {
  const year = new Date().getFullYear();

  return (
    <footer className="border-t border-supra-border bg-supra-navyDeep px-6 pt-16">
      <div className="mx-auto max-w-6xl">
        <div className="grid gap-12 pb-14 lg:grid-cols-[1.3fr_2fr]">
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
          </div>

          <div className="grid gap-10 sm:grid-cols-3">
            <div>
              <h2 className="font-caps text-xs uppercase text-supra-muted">
                Product
              </h2>
              <div className="mt-4 flex flex-col">
                {productLinks.map((link) => (
                  <FooterLink key={link.href} {...link} />
                ))}
              </div>
            </div>

            <div>
              <h2 className="font-caps text-xs uppercase text-supra-muted">
                Trust
              </h2>
              <div className="mt-4 flex flex-col">
                {trustLinks.map((link) => (
                  <FooterLink key={link.href} {...link} />
                ))}
              </div>
            </div>

            <div>
              <h2 className="font-caps text-xs uppercase text-supra-muted">
                Project
              </h2>
              <div className="mt-4 flex flex-col">
                {projectLinks.map((link) => (
                  <FooterLink key={link.href} {...link} />
                ))}
              </div>
            </div>
          </div>
        </div>

        <div className="border-t border-supra-border py-6">
          <p className="text-sm text-supra-muted">
            © {year} Cade Spivey. All rights reserved. Released under the{" "}
            <Link href={LICENSE_URL} className="link-quiet underline">
              MIT License
            </Link>
            .
          </p>
        </div>
      </div>
    </footer>
  );
}
