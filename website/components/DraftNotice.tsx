export function DraftNotice() {
  return (
    <aside className="mb-10 border-l-2 border-supra-gold/60 pl-5">
      <p className="font-caps text-xs uppercase text-supra-gold">
        Pre-launch draft
      </p>
      <p className="measure mt-2 text-sm leading-[1.55] text-supra-muted">
        This page is a working draft provided for transparency during the public
        beta. It is not final, is not legal advice, and will be reviewed and
        updated before general release. The version published at launch will
        govern.
      </p>
    </aside>
  );
}
