import Link from "next/link";
import { Section } from "./Section";

export function FinalCta() {
  return (
    <Section>
      <div className="mx-auto max-w-3xl text-center">
        <h2 className="text-4xl leading-tight text-supra-white sm:text-5xl">
          Secure legal AI without compromise.
          <span className="block pt-3 italic text-supra-gold">See Supra.</span>
        </h2>
        <Link
          href="/download"
          className="mt-9 inline-flex text-lg text-supra-gold underline-offset-8 transition hover:underline"
        >
          Download for macOS →
        </Link>
      </div>
    </Section>
  );
}
