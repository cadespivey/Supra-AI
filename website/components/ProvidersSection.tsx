import { Section } from "./Section";

type Provider = {
  name: string;
  url: string;
  role: string;
  support?: { label: string; url: string };
};

const sources: Provider[] = [
  {
    name: "CourtListener — Free Law Project",
    url: "https://www.courtlistener.com",
    role: "Case law, oral arguments, and federal dockets (PACER/RECAP). A 501(c)(3) nonprofit that has made court records free for over a decade.",
    support: { label: "Donate to Free Law Project", url: "https://free.law/donate/" },
  },
  {
    name: "Open Legal Codes",
    url: "https://openlegalcodes.org",
    role: "A free, key-less backbone for the U.S. Code, the CFR, and all fifty states' statutes.",
  },
  {
    name: "OpenStates",
    url: "https://openstates.org",
    role: "Open data on state legislators, bills, and votes — powering state legislative tracking.",
  },
  {
    name: "GovInfo",
    url: "https://www.govinfo.gov",
    role: "Official United States Code section text.",
  },
  {
    name: "eCFR",
    url: "https://www.ecfr.gov",
    role: "Code of Federal Regulations, with effective dates.",
  },
  {
    name: "Federal Register",
    url: "https://www.federalregister.gov",
    role: "Federal rules, proposed rules, and notices.",
  },
  {
    name: "Regulations.gov",
    url: "https://www.regulations.gov",
    role: "Rulemaking dockets and public comments.",
  },
  {
    name: "SEC EDGAR",
    url: "https://www.sec.gov/edgar",
    role: "Public company filings — 10-K, 10-Q, and 8-K.",
  },
  {
    name: "CFPB",
    url: "https://www.consumerfinance.gov/data-research/consumer-complaints/",
    role: "The consumer-complaint database.",
  },
  {
    name: "NLRB",
    url: "https://www.nlrb.gov",
    role: "Labor-case records and election results.",
  },
];

export function ProvidersSection() {
  return (
    <Section id="providers">
      <div className="measure-wide">
        <p className="font-caps text-xs uppercase text-supra-gold">
          Research sources
        </p>
        <h2 className="mt-4 text-3xl leading-[1.15] text-supra-white">
          Standing on the shoulders of open law.
        </h2>
        <p className="mt-6 text-lg leading-[1.5] text-supra-muted">
          Supra AI doesn&rsquo;t resell legal data. Its case-law, statutory, and
          public-records research runs on public sources — nonprofits and
          government services making the law free to everyone.{" "}
          <span className="text-supra-white">
            If Supra AI is useful to you, please consider supporting them.
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

      <dl className="mt-14 grid gap-x-12 gap-y-8 sm:grid-cols-2">
        {sources.map((source) => (
          <div key={source.name} className="border-t border-supra-border pt-5">
            <dt className="text-lg text-supra-white">
              <a
                href={source.url}
                target="_blank"
                rel="noopener noreferrer"
                className="link"
              >
                {source.name}
              </a>
            </dt>
            <dd className="mt-2 text-base leading-[1.55] text-supra-muted">
              {source.role}
            </dd>
            {source.support && (
              <a
                href={source.support.url}
                target="_blank"
                rel="noopener noreferrer"
                className="link mt-2 inline-block text-sm"
              >
                {source.support.label} →
              </a>
            )}
          </div>
        ))}
      </dl>

      <p className="mt-12 max-w-3xl text-sm leading-[1.55] text-supra-muted">
        Legal-data requests are limited to these named hosts and logged
        locally for your audit trail, and rate-limited to stay a good citizen of
        the services that keep the law open.
      </p>
    </Section>
  );
}
