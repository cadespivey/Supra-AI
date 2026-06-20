export function DraftNotice() {
  return (
    <aside className="mb-8 rounded-2xl border border-supra-gold/35 bg-supra-navyPanel p-5">
      <p className="font-caps text-xs font-bold uppercase text-supra-gold">
        Pre-launch draft
      </p>
      <p className="mt-2 text-sm leading-7 text-supra-muted">
        This page is a working draft provided for transparency during the public
        beta. It is not final, is not legal advice, and will be reviewed and
        updated before general release. The version published at launch will
        govern.
      </p>
    </aside>
  );
}
