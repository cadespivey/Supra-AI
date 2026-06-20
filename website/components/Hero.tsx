import Image from "next/image";
import Link from "next/link";
import heroLockup from "@/public/images/supra-ai-hero-lockup.png";
import { Section } from "./Section";

export function Hero() {
  return (
    <Section className="flex min-h-[calc(100vh-72px)] items-center py-10 sm:py-14">
      <div className="mx-auto flex max-w-4xl flex-col items-center text-center">
        {/* Static import so the basePath/assetPrefix is applied automatically. */}
        <Image
          src={heroLockup}
          alt="Supra AI. Secure legal AI without compromise. See Supra."
          priority
          unoptimized
          className="h-auto w-[80vw] max-w-[320px]"
        />
        <h1 className="mt-4 max-w-3xl text-3xl leading-tight text-supra-white sm:text-4xl">
          AI companies ask you to trust them with your data.
          <span className="block pt-3 italic text-supra-gold">
            With Supra AI, you don&apos;t have to.
          </span>
        </h1>
        <p className="mt-4 max-w-2xl text-base leading-7 text-supra-muted sm:text-lg">
          Once it&apos;s set up, Supra AI runs locally on your Mac. Your matter
          files, prompts, and generated work stay on your machine — optional
          CourtListener research is the only feature that uses the network.
        </p>
        <Link
          href="/download"
          className="mt-4 text-lg text-supra-gold underline-offset-8 transition hover:underline"
        >
          Download for macOS →
        </Link>
        <div className="mt-10 flex flex-wrap items-center justify-center gap-2">
          {[
            "Runs on-device",
            "Apple Silicon · MLX",
            "Source-grounded",
            "CourtListener optional",
          ].map((tag) => (
            <span
              key={tag}
              className="rounded-full border border-supra-border px-4 py-1.5 font-caps text-xs uppercase tracking-wide text-supra-muted"
            >
              {tag}
            </span>
          ))}
        </div>
      </div>
    </Section>
  );
}
