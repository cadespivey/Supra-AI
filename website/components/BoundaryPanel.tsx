type BoundaryPanelProps = {
  title: string;
  items: string[];
};

export function BoundaryPanel({ title, items }: BoundaryPanelProps) {
  return (
    <article className="rounded-2xl border border-supra-border bg-supra-navyPanel p-6">
      <h2 className="text-2xl text-supra-white">{title}</h2>
      <ul className="mt-5 space-y-3">
        {items.map((item) => (
          <li key={item} className="flex gap-3 text-supra-muted">
            <span className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-supra-gold" />
            <span>{item}</span>
          </li>
        ))}
      </ul>
    </article>
  );
}
