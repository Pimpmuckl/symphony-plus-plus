export function EmptyPanel({ title, compact = false }: { title: string; compact?: boolean }) {
  return (
    <div
      className={`dashboard-glass-surface flex items-center justify-center rounded-lg border border-dashed bg-muted/30 text-sm text-muted-foreground ${compact ? "min-h-[96px]" : "min-h-[180px]"}`}
    >
      {title}
    </div>
  );
}
