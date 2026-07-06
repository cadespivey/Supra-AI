import type { Metadata } from "next";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { equity, equityCaps } from "@/lib/fonts";
import "./globals.css";

export const metadata: Metadata = {
  title: "Supra AI | Local Legal AI for macOS",
  description:
    "Supra AI is a locally run legal research, writing, and timekeeping assistant for macOS — case-law and public-records research, source-grounded answers, citation verification, and attorney review, all on your Mac.",
  // Apex custom domain — drives canonical and Open Graph URLs.
  metadataBase: new URL("https://supralegal.ai"),
  // The favicon is provided by the app/icon.svg file convention, served from the
  // site root (no basePath).
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
