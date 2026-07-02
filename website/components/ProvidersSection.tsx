import { Section } from "./Section";

type Provider = {
  name: string;
  url: string;
  role: string;
  note: string;
  support?: { label: string; url: string };
};

const nonprofits: Provider[] = [
  {
    name: "Free Law Project — CourtListener & RECAP",
    url: "https://www.courtlistener.com",
    role: "Case law, oral arguments, and federal docket (PACER/RECAP) data",
    note: "A 501(c)(3) nonprofit that has spent over a decade making court records free. Supra AI's case-law search, docket lookups, and citation verification run on CourtListener's API.",
    support: { label: "Donate to Free Law Project", url: "https://free.law/donate/" },
  },
  {
    name: "Open Legal Codes",
    url: "https://openlegalcodes.org",
    role: "United States Code, CFR, and state statutes",
    note: "A free, key-less statutory backbone covering federal and all fifty states' codes — the convenience tier behind Supra AI's statute lookups.",
  },
  {
    name: "OpenStates",
    url: "https://openstates.org",
    role: "State legislation and bill tracking",
    note: "Open data on legislators, bills, and votes across every state legislature, powering Supra AI's state legislative-developments tracking.",
  },
];

const official: Provider[] = [
  {
    name: "CourtListener API",
    url: "https://www.courtlistener.com/help/api/",
    role: "Opinions · dockets · citation lookup",
    note: "",
  },
  {
    name: "eCFR",
    url: "https://www.ecfr.gov",
    role: "Code of Federal Regulations, with effective dates",
    note: "",
  },
  {
    name: "GovInfo",
    url: "https://www.govinfo.gov",
    role: "Official United States Code section text",
    note: "",
  },
  {
    name: "Federal Register",
    url: "https://www.federalregister.gov",
    role: "Rules, proposed rules, and notices",
    note: "",
  },
  {
    name: "Regulations.gov",
    url: "https://www.regulations.gov",
    role: "Rulemaking dockets and comments",
    note: "",
  },
];

export function ProvidersSection() {
  return (
    <Section id="providers">
      <div className="measure-wide">
        <p className="font-caps text-xs uppercase text-supra-gold">
          Research providers
        </p>
        <h2 className="mt-4 text-3xl leading-[1.15] text-supra-white">
          Standing on the shoulders of open law.
        </h2>
        <p className="mt-6 text-lg leading-[1.5] text-supra-muted">
          Supra AI doesn&rsquo;t resell legal data. Its research runs on public
          sources — nonprofits and government services working to make the law
          freely accessible to everyone, not just to firms with database
          contracts. If Supra AI is useful to you, these organizations are why.{" "}
          <span className="text-supra-white">
            Please consider supporting their work.
          </span>
        </p>
      </div>

      <figure className="mt-12">
        <div className="mx-auto max-w-3xl overflow-hidden rounded-xl border border-supra-border bg-supra-navyDeep shadow-[0_24px_60px_-24px_rgba(0,0,0,0.7)]">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src="/screenshots/settings-sources.png"
            alt="The app's Legal Data Sources settings listing each connector with its key status — several marked 'Free · no key' — with keys stored in the macOS Keychain."
            loading="lazy"
            className="block h-auto w-full"
          />
        </div>
        <figcaption className="mt-3 text-center font-caps text-[11px] uppercase tracking-wide text-supra-muted">
          Every source, its cost, and its key status — inside the app
        </figcaption>
      </figure>

      <div className="mt-14 grid gap-x-10 gap-y-8 lg:grid-cols-2">
        {nonprofits.map((provider) => (
          <article
            key={provider.name}
            className="border-t border-supra-border pt-5"
          >
            <h3 className="text-xl text-supra-white">
              <a
                href={provider.url}
                target="_blank"
                rel="noopener noreferrer"
                className="link"
              >
                {provider.name}
              </a>
            </h3>
            <p className="mt-1 font-caps text-xs uppercase text-supra-gold">
              {provider.role}
            </p>
            <p className="mt-3 text-base leading-[1.55] text-supra-muted">
              {provider.note}
            </p>
            {provider.support && (
              <a
                href={provider.support.url}
                target="_blank"
                rel="noopener noreferrer"
                className="link mt-3 inline-block text-base"
              >
                {provider.support.label} →
              </a>
            )}
          </article>
        ))}
      </div>

      <div className="mt-16 border-t border-supra-border pt-8">
        <p className="font-caps text-xs uppercase text-supra-gold">
          Official government sources
        </p>
        <dl className="mt-6 grid gap-x-10 gap-y-4 sm:grid-cols-2 lg:grid-cols-3">
          {official.map((source) => (
            <div key={source.name}>
              <dt className="text-base text-supra-white">
                <a
                  href={source.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="link"
                >
                  {source.name}
                </a>
              </dt>
              <dd className="mt-1 text-sm leading-[1.5] text-supra-muted">
                {source.role}
              </dd>
            </div>
          ))}
        </dl>
        <p className="mt-8 max-w-3xl text-sm leading-[1.55] text-supra-muted">
          Every network request the app makes is limited to these hosts, logged
          locally for your audit trail, and rate-limited to be a good citizen of
          services that keep the law open.
        </p>
      </div>
    </Section>
  );
}
