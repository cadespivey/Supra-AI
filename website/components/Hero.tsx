import Link from "next/link";
import { Section } from "./Section";

export function Hero() {
  return (
    <Section className="flex min-h-[calc(100svh-64px)] items-center py-10 sm:min-h-[calc(100vh-72px)] sm:py-14">
      <div className="mx-auto flex max-w-4xl flex-col items-center text-center">
        {/* Live type, not a raster lockup — crisp, accessible, and no baked-in
            background to mismatch the page. */}
        <span
          aria-hidden="true"
          className="text-[5.5rem] font-bold leading-none text-supra-gold sm:text-[7.5rem]"
        >
          §
        </span>
        <p className="mt-5 text-4xl text-supra-white sm:text-5xl">Supra AI</p>
        <p className="mt-4 text-lg leading-[1.4] text-supra-white sm:text-xl">
          Secure legal AI without compromise.
        </p>
        <p className="mt-1 text-lg italic text-supra-gold sm:text-xl">
          See Supra.
        </p>
        <h1 className="mt-12 max-w-2xl text-3xl leading-[1.15] text-supra-white sm:text-4xl">
          AI companies ask you to trust them with your data.
          <span className="block pt-3 italic text-supra-gold">
            With Supra AI, you don’t have to.
          </span>
        </h1>
        <p className="measure mt-6 text-lg leading-[1.5] text-supra-muted">
          Once it’s set up, Supra AI runs locally on your Mac. Your matter files,
          prompts, and generated work stay on your machine — optional
          CourtListener research is the only feature that uses the network.
        </p>
        <Link href="/download" className="link mt-7 inline-block text-lg">
          Download for macOS →
        </Link>
        <p className="mt-10 font-caps text-xs uppercase text-supra-muted">
          Runs on-device · Apple Silicon · Source-grounded
        </p>
      </div>
    </Section>
  );
}
