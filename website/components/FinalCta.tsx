import Link from "next/link";
import { Section } from "./Section";

export function FinalCta() {
  return (
    <Section>
      <div className="mx-auto max-w-2xl text-center">
        <h2 className="text-3xl leading-[1.15] text-supra-white sm:text-4xl">
          Secure legal AI without compromise.
          <span className="block pt-3 italic text-supra-gold">See Supra.</span>
        </h2>
        <Link href="/download" className="link mt-8 inline-block text-lg">
          Download for macOS →
        </Link>
      </div>
    </Section>
  );
}
