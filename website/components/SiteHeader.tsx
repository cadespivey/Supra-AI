import Link from "next/link";

const navItems = [
  { href: "/product", label: "Product" },
  { href: "/privacy-security", label: "Privacy & Security" },
  { href: "/download", label: "Download", accent: true },
  { href: "/disclaimer", label: "Disclaimer" },
];

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-40 border-b border-supra-border bg-supra-navy/96 backdrop-blur-sm">
      <div className="mx-auto flex min-h-16 max-w-6xl flex-col justify-center gap-3 px-6 py-3 sm:min-h-[72px] sm:flex-row sm:items-center sm:justify-between sm:py-0">
        <Link
          href="/"
          className="text-2xl font-bold text-supra-white transition-colors hover:text-supra-gold"
        >
          Supra AI
        </Link>
        <nav aria-label="Primary navigation">
          <ul className="flex flex-wrap items-center gap-x-5 gap-y-2">
            {navItems.map((item) => (
              <li key={item.href}>
                <Link
                  href={item.href}
                  className={`font-caps text-xs uppercase text-supra-muted transition-colors hover:text-supra-gold sm:text-[0.8rem] ${
                    item.accent ? "text-supra-gold" : ""
                  }`}
                >
                  {item.label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
      </div>
    </header>
  );
}
