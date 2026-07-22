import { Check, Copy, Loader2, TriangleAlert } from "lucide-react";
import type { ComponentProps } from "react";
import { useEffect, useRef, useState } from "react";

import { Button } from "@/components/ui/button";
import { copyTextToClipboard } from "@/dashboard/runtime";

type CopyState = "idle" | "copying" | "copied" | "error";

export function DetailCopyButton({ className = "button-lift size-8 shrink-0", label, text, variant = "ghost" }: {
  className?: string;
  label: string;
  text: string;
  variant?: ComponentProps<typeof Button>["variant"];
}) {
  const [state, setState] = useState<CopyState>("idle");
  const timerRef = useRef<number | null>(null);
  const copied = state === "copied";
  const title = copied ? "Copied" : state === "error" ? "Copy failed" : label;

  useEffect(
    () => () => {
      if (timerRef.current !== null) window.clearTimeout(timerRef.current);
    },
    [],
  );

  async function copyDetails() {
    if (timerRef.current !== null) window.clearTimeout(timerRef.current);
    setState("copying");

    try {
      await copyTextToClipboard(text);
      setState("copied");
    } catch {
      setState("error");
    } finally {
      timerRef.current = window.setTimeout(() => {
        setState("idle");
        timerRef.current = null;
      }, 1800);
    }
  }

  return (
    <Button
      type="button"
      size="icon"
      variant={variant}
      className={className}
      aria-label={title}
      title={title}
      onClick={() => void copyDetails()}
      disabled={state === "copying" || !text.trim()}
    >
      {state === "copying" ? <Loader2 className="size-4 animate-spin" /> : copied ? <Check className="size-4" /> : state === "error" ? <TriangleAlert className="size-4" /> : <Copy className="size-4" />}
    </Button>
  );
}
