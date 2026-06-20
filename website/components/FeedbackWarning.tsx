type FeedbackWarningProps = {
  compact?: boolean;
};

export function FeedbackWarning({ compact = false }: FeedbackWarningProps) {
  return (
    <aside
      className={`rounded-2xl border border-supra-gold/35 bg-supra-navyPanel ${
        compact ? "p-4" : "p-6"
      }`}
    >
      <h2 className="font-caps text-xs font-bold uppercase text-supra-gold">
        Public feedback only.
      </h2>
      <p
        className={`mt-3 text-supra-muted ${
          compact ? "text-xs leading-6" : "text-sm leading-7"
        }`}
      >
        GitHub Issues are public. Do not include attorney-client privileged
        communications, attorney work product, confidential client information,
        personally identifying information, HIPAA-sensitive information, sealed
        material, litigation strategy, client names, matter facts, documents, or
        any other sensitive or nonpublic information.
      </p>
    </aside>
  );
}
