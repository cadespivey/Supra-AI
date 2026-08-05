import type { Metadata } from "next";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import "./globals.css";

export const metadata: Metadata = {
  title: "Supra AI | Local Legal AI for macOS",
  description:
    "Supra AI is a legal research, writing, and timekeeping assistant for macOS — with on-device generation and document processing, named-provider research, source-grounded answers, citation verification, and attorney review.",
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
    <html lang="en">
      <body>
        <SiteHeader />
        {children}
        <SiteFooter />
      </body>
    </html>
  );
}
