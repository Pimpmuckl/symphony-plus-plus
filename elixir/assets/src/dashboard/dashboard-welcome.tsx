import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";

export function shouldShowWelcomeDialog({
  ready,
  showWelcomeToast,
  shownThisLoad,
}: {
  ready: boolean;
  showWelcomeToast: boolean;
  shownThisLoad: boolean;
}) {
  return ready && showWelcomeToast && !shownThisLoad;
}

export function DashboardWelcomeDialog({
  openDashboardOnBoot,
  ready,
  showWelcomeToast,
  onOpenDashboardOnBootChange,
  onShowWelcomeToastChange,
}: {
  openDashboardOnBoot: boolean;
  ready: boolean;
  showWelcomeToast: boolean;
  onOpenDashboardOnBootChange: (value: boolean) => Promise<void>;
  onShowWelcomeToastChange: (value: boolean) => void;
}) {
  const [shownThisLoad, setShownThisLoad] = useState(false);
  const [dontShowAgain, setDontShowAgain] = useState(false);
  const [editedDontOpenOnBoot, setEditedDontOpenOnBoot] = useState<boolean | null>(null);
  const [error, setError] = useState<string | null>(null);
  const open = shouldShowWelcomeDialog({ ready, showWelcomeToast, shownThisLoad });
  const dontOpenOnBoot = editedDontOpenOnBoot ?? !openDashboardOnBoot;

  async function close() {
    setError(null);

    try {
      if (dontOpenOnBoot !== !openDashboardOnBoot) await onOpenDashboardOnBootChange(!dontOpenOnBoot);
      if (dontShowAgain) onShowWelcomeToastChange(false);
      setEditedDontOpenOnBoot(null);
      setShownThisLoad(true);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Setting was not saved");
    }
  }

  return (
    <Dialog open={open} onOpenChange={(nextOpen) => (!nextOpen ? void close() : undefined)}>
      <DialogContent className="dashboard-dialog-content max-w-md">
        <DialogHeader>
          <DialogTitle>Welcome!</DialogTitle>
          <DialogDescription>This is the Symphony++ Dashboard.</DialogDescription>
        </DialogHeader>

        <div className="grid gap-4 text-sm text-muted-foreground">
          <p>Here, you can see what your agents are up to, manage WorkRequests and so on.</p>
          <p>If you don't want the browser to open this automatically, you can disable that here or in settings.</p>
          <label className="flex items-center gap-3 text-foreground">
            <input type="checkbox" checked={dontShowAgain} onChange={(event) => setDontShowAgain(event.target.checked)} />
            <span>Don't show this again</span>
          </label>
          <label className="flex items-center gap-3 text-foreground">
            <input type="checkbox" checked={dontOpenOnBoot} onChange={(event) => setEditedDontOpenOnBoot(event.target.checked)} />
            <span>Don't open dashboard on boot</span>
          </label>
          {error ? <p className="text-xs text-destructive">{error}</p> : null}
        </div>

        <DialogFooter>
          <Button type="button" onClick={() => void close()}>
            Done
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
