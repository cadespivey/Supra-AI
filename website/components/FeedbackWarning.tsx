type FeedbackWarningProps = {
  compact?: boolean;
};

export function FeedbackWarning({ compact = false }: FeedbackWarningProps) {
  return (
    <aside className={`border-l-2 border-supra-gold/60 ${compact ? "pl-4" : "pl-5"}`}>
      <h2 className="font-caps text-xs uppercase text-supra-gold">
        Public feedback only
      </h2>
      <p
        className={`measure text-supra-muted ${
          compact ? "mt-2 text-xs leading-[1.5]" : "mt-3 text-sm leading-[1.55]"
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
