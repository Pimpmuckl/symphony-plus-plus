import * as DialogPrimitive from "@radix-ui/react-dialog";
import { X } from "lucide-react";
import * as React from "react";

import { cn } from "@/lib/utils";

const Dialog = DialogPrimitive.Root;
const DialogTrigger = DialogPrimitive.Trigger;
const DialogPortal = DialogPrimitive.Portal;
const DialogClose = DialogPrimitive.Close;
const DIALOG_SIZE_MOTION_MS = 280;
const DIALOG_RESIZE_EPSILON_PX = 3;

function DialogOverlay({ className, ref, ...props }: React.ComponentProps<typeof DialogPrimitive.Overlay>) {
  return (
    <DialogPrimitive.Overlay
      ref={ref}
      className={cn("dialog-overlay fixed inset-0 z-50", className)}
      {...props}
    />
  );
}
DialogOverlay.displayName = DialogPrimitive.Overlay.displayName;

type DialogContentProps = React.ComponentProps<typeof DialogPrimitive.Content> & {
  resizeKey?: React.Key;
};

function DialogContent({ className, children, ref, resizeKey, style, ...props }: DialogContentProps) {
  const contentRef = React.useRef<HTMLDivElement | null>(null);
  const innerRef = React.useRef<HTMLDivElement | null>(null);
  const frameRef = React.useRef<number | null>(null);
  const settleTimerRef = React.useRef<number | null>(null);
  const resizingRef = React.useRef(false);
  const queuedResizeRef = React.useRef(false);
  const measuredHeightRef = React.useRef<number | null>(null);
  const animateResizeRef = React.useRef<() => void>(() => undefined);
  const [height, setHeight] = React.useState<number | null>(null);

  const setContentRef = React.useCallback(
    (node: HTMLDivElement | null) => {
      contentRef.current = node;

      if (typeof ref === "function") {
        ref(node);
      } else if (ref) {
        ref.current = node;
      }
    },
    [ref],
  );

  const measureNaturalHeight = React.useCallback(() => {
    const content = contentRef.current;
    if (!content) return 0;

    const maxHeight = Number.parseFloat(window.getComputedStyle(content).maxHeight);
    const naturalHeight = Math.ceil(content.scrollHeight);
    return Math.min(naturalHeight, Number.isFinite(maxHeight) && maxHeight > 0 ? maxHeight : naturalHeight);
  }, []);

  const finishResize = React.useCallback(() => {
    const content = contentRef.current;
    const queuedResize = queuedResizeRef.current;

    resizingRef.current = false;

    if (queuedResize) {
      queuedResizeRef.current = false;
      measuredHeightRef.current = content ? Math.ceil(content.getBoundingClientRect().height) : measuredHeightRef.current;
      frameRef.current = window.requestAnimationFrame(() => {
        frameRef.current = null;
        animateResizeRef.current();
      });
      return;
    }

    measuredHeightRef.current = measureNaturalHeight();
    setHeight(null);
  }, [measureNaturalHeight]);

  const animateResize = React.useCallback(() => {
    const content = contentRef.current;
    if (!content || prefersReducedDialogMotion()) {
      measuredHeightRef.current = null;
      setHeight(null);
      return;
    }

    if (resizingRef.current) {
      queuedResizeRef.current = true;
      return;
    }

    const currentHeight = measuredHeightRef.current ?? Math.ceil(content.getBoundingClientRect().height);
    const nextHeight = measureNaturalHeight();
    measuredHeightRef.current = nextHeight;

    if (currentHeight <= 0 || nextHeight <= 0 || Math.abs(nextHeight - currentHeight) <= DIALOG_RESIZE_EPSILON_PX) {
      setHeight(null);
      return;
    }

    resizingRef.current = true;

    if (frameRef.current !== null) {
      window.cancelAnimationFrame(frameRef.current);
    }

    if (settleTimerRef.current !== null) {
      window.clearTimeout(settleTimerRef.current);
    }

    setHeight(currentHeight);
    frameRef.current = window.requestAnimationFrame(() => {
      setHeight(nextHeight);
      frameRef.current = null;
    });

    settleTimerRef.current = window.setTimeout(() => {
      settleTimerRef.current = null;
      finishResize();
    }, DIALOG_SIZE_MOTION_MS + 60);
  }, [finishResize, measureNaturalHeight]);

  const cancelPendingResizeFrame = React.useCallback(() => {
    if (frameRef.current !== null) {
      window.cancelAnimationFrame(frameRef.current);
      frameRef.current = null;
    }
  }, []);

  const cancelPendingSettleTimer = React.useCallback(() => {
    if (settleTimerRef.current !== null) {
      window.clearTimeout(settleTimerRef.current);
      settleTimerRef.current = null;
    }
  }, []);

  const resetResizeState = React.useCallback(() => {
    resizingRef.current = false;
    queuedResizeRef.current = false;
    measuredHeightRef.current = null;
  }, []);

  React.useEffect(() => {
    animateResizeRef.current = animateResize;
  }, [animateResize]);

  React.useLayoutEffect(() => {
    if (prefersReducedDialogMotion()) return;

    animateResize();
  }, [animateResize, resizeKey]);

  React.useEffect(() => {
    const inner = innerRef.current;
    if (!inner || typeof ResizeObserver === "undefined" || prefersReducedDialogMotion()) return;

    const observer = new ResizeObserver(() => {
      cancelPendingResizeFrame();

      frameRef.current = window.requestAnimationFrame(() => {
        animateResize();
        frameRef.current = null;
      });
    });

    observer.observe(inner);

    return () => {
      observer.disconnect();
      cancelPendingResizeFrame();
      cancelPendingSettleTimer();
      resetResizeState();
    };
  }, [animateResize, cancelPendingResizeFrame, cancelPendingSettleTimer, resetResizeState]);

  return (
    <DialogPortal>
      <DialogOverlay />
      <DialogPrimitive.Content
        ref={setContentRef}
        className={cn(
          "dialog-content fixed left-1/2 top-1/2 z-50 max-h-[88vh] w-[calc(100vw-2rem)] max-w-3xl -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-lg border bg-background p-6 shadow-dashboard focus:outline-none",
          height !== null && "dialog-content-sizing",
          className,
        )}
        style={height === null ? style : { ...style, height }}
        {...props}
      >
        <div ref={innerRef} className="dialog-content-inner">
          {children}
        </div>
        <DialogPrimitive.Close className="absolute right-4 top-4 rounded-md p-1 text-muted-foreground opacity-70 transition-opacity hover:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring">
          <X className="size-4" />
          <span className="sr-only">Close</span>
        </DialogPrimitive.Close>
      </DialogPrimitive.Content>
    </DialogPortal>
  );
}
DialogContent.displayName = DialogPrimitive.Content.displayName;

function prefersReducedDialogMotion() {
  return typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

const DialogHeader = ({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
  <div className={cn("flex flex-col space-y-2 text-left", className)} {...props} />
);
DialogHeader.displayName = "DialogHeader";

const DialogFooter = ({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
  <div className={cn("flex flex-col-reverse gap-2 sm:flex-row sm:justify-end", className)} {...props} />
);
DialogFooter.displayName = "DialogFooter";

function DialogTitle({ className, ref, ...props }: React.ComponentProps<typeof DialogPrimitive.Title>) {
  return <DialogPrimitive.Title ref={ref} className={cn("text-lg font-semibold leading-none tracking-normal", className)} {...props} />;
}
DialogTitle.displayName = DialogPrimitive.Title.displayName;

function DialogDescription({ className, ref, ...props }: React.ComponentProps<typeof DialogPrimitive.Description>) {
  return <DialogPrimitive.Description ref={ref} className={cn("text-sm text-muted-foreground", className)} {...props} />;
}
DialogDescription.displayName = DialogPrimitive.Description.displayName;

export {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogPortal,
  DialogTitle,
  DialogTrigger,
};
