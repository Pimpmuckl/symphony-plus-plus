import { Search, X } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

export function DashboardSearchControl({
  value,
  onValueChange,
}: {
  value: string;
  onValueChange: (value: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const openSearch = useCallback(() => setOpen(true), []);
  const selectSearch = useCallback(() => {
    setOpen(true);
    window.requestAnimationFrame(() => {
      inputRef.current?.focus();
      inputRef.current?.select();
    });
  }, []);
  const closeSearch = useCallback(() => {
    onValueChange("");
    setOpen(false);
  }, [onValueChange]);

  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      const key = event.key.toLowerCase();
      if ((event.ctrlKey || event.metaKey) && (key === "f" || key === "k")) {
        event.preventDefault();
        selectSearch();
      } else if (open && key === "escape") {
        closeSearch();
      }
    };

    window.addEventListener("keydown", handleKeyDown, true);
    return () => window.removeEventListener("keydown", handleKeyDown, true);
  }, [closeSearch, open, selectSearch]);

  return (
    <div
      className={cn(
        "flex h-9 shrink-0 items-center overflow-hidden rounded-md border border-input bg-background/75 shadow-sm transition-[width,background-color,border-color,box-shadow] duration-200 ease-out",
        open ? "w-[min(18rem,calc(100vw-2rem))]" : "w-9",
      )}
      data-search-open={open ? "true" : "false"}
    >
      {open ? (
        <>
          <Search className="ml-2 size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
          <Input
            ref={inputRef}
            value={value}
            onChange={(event) => onValueChange(event.target.value)}
            placeholder="Search"
            aria-label="Search dashboard"
            className="h-8 border-0 bg-transparent px-2 shadow-none focus-visible:ring-0"
          />
          <Button type="button" variant="ghost" size="icon" className="button-lift mr-0.5 size-8 shrink-0" aria-label="Close search" onClick={closeSearch}>
            <X className="size-4" />
          </Button>
        </>
      ) : (
        <Button type="button" variant="ghost" size="icon" className="button-lift size-9 shrink-0" aria-label="Open search" onClick={openSearch}>
          <Search className="size-4" />
        </Button>
      )}
    </div>
  );
}
