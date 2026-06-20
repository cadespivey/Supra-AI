type BoundaryPanelProps = {
  title: string;
  items: string[];
};

export function BoundaryPanel({ title, items }: BoundaryPanelProps) {
  return (
    <article className="border-t border-supra-border pt-5">
      <h2 className="text-xl text-supra-white">{title}</h2>
      <ul className="mt-4 space-y-2.5">
        {items.map((item) => (
          <li
            key={item}
            className="flex gap-3 text-base leading-[1.5] text-supra-muted"
          >
            <span className="mt-2.5 h-1.5 w-1.5 shrink-0 rounded-full bg-supra-gold" />
            <span>{item}</span>
          </li>
        ))}
      </ul>
    </article>
  );
}
