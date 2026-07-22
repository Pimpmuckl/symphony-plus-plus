import { Bug, Gauge } from "lucide-react";
import { useEffect, useRef, useState } from "react";

export function DashboardDebugTools() {
  if (!import.meta.env.DEV || typeof window === "undefined" || new URLSearchParams(window.location.search).get("debug-motion") !== "1") return null;
  return <DashboardDebugToolsPanel />;
}

function DashboardDebugToolsPanel() {
  const [open, setOpen] = useState(false);
  const [motionScale, setMotionScale] = useState(1);
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    document.documentElement.dataset.focusMotionScale = String(motionScale);
    return () => {
      delete document.documentElement.dataset.focusMotionScale;
    };
  }, [motionScale]);

  useEffect(() => {
    if (!open) return;
    const closeOnPointer = (event: PointerEvent) => {
      if (event.target instanceof Node && !ref.current?.contains(event.target)) setOpen(false);
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopImmediatePropagation();
        setOpen(false);
      }
    };
    document.addEventListener("pointerdown", closeOnPointer);
    window.addEventListener("keydown", closeOnEscape, true);
    return () => {
      document.removeEventListener("pointerdown", closeOnPointer);
      window.removeEventListener("keydown", closeOnEscape, true);
    };
  }, [open]);

  return (
    <div ref={ref} className="dashboard-debug-tools" data-open={open ? "true" : "false"}>
      <button type="button" className="dashboard-debug-tools__trigger" aria-expanded={open} aria-controls="dashboard-debug-panel" onClick={() => setOpen((current) => !current)}>
        <Bug className="size-3.5" aria-hidden="true" />
        <span>Debug</span>
      </button>
      {open ? (
        <div id="dashboard-debug-panel" className="dashboard-debug-tools__panel">
          <div className="dashboard-debug-tools__row">
            <span className="dashboard-debug-tools__label"><Gauge className="size-3.5" aria-hidden="true" />WR motion</span>
            <div className="dashboard-debug-tools__choices" role="group" aria-label="WorkRequest animation speed">
              {[1, 5, 10].map((value) => (
                <button type="button" data-selected={motionScale === value ? "true" : undefined} aria-pressed={motionScale === value} onClick={() => setMotionScale(value)} key={value}>{value}×</button>
              ))}
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
