import type { Metadata } from "next";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { equity, equityCaps } from "@/lib/fonts";
import "./globals.css";

export const metadata: Metadata = {
  title: "Supra AI | Local Legal AI for macOS",
  description:
    "Supra AI is a locally run legal AI workspace for macOS, designed for private legal research, source-grounded answers, citation verification, and attorney review.",
  // Update to https://supralegal.ai when the site moves to the apex domain.
  metadataBase: new URL("https://cadespivey.github.io/Supra-AI"),
  // The favicon is provided by the app/icon.svg file convention, which is
  // automatically prefixed with the basePath (unlike a static metadata icon).
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={`${equity.variable} ${equityCaps.variable}`}>
      <body>
        <SiteHeader />
        {children}
        <SiteFooter />
      </body>
    </html>
  );
}
