import { AlertTriangle, MessageSquareText } from "lucide-react";
import type { GuidanceItem } from "@/types/dashboard";
import { AttentionBarButton } from "./attention-bar-button";
import type { BlockerItem } from "./dashboard-state";
import type { TopPanelKey } from "./runtime";
import type { AttentionButtonConfig } from "./status-rail-types";

export function AttentionBarControls({
  openPanel,
  guidanceItems,
  blockerItems,
  onToggle,
}: {
  openPanel: TopPanelKey | null;
  guidanceItems: GuidanceItem[];
  blockerItems: BlockerItem[];
  onToggle: (panel: TopPanelKey | null) => void;
}) {
  const configs: AttentionButtonConfig[] = [
    {
      icon: <MessageSquareText className="size-6" />,
      panel: "guidance",
      title: "Human Guidance Needed",
      tone: "guidance",
      value: guidanceItems.length,
    },
    {
      icon: <AlertTriangle className="size-6" />,
      panel: "blockers",
      title: "Active Blockers",
      tone: blockerItems.length === 0 ? "blocker-clear" : "blocker",
      value: blockerItems.length,
    },
  ];

  return (
    <div className="dashboard-attention-controls" aria-label="Dashboard attention">
      {configs.map((config) => (
        <AttentionBarButton key={config.panel} {...config} open={openPanel === config.panel} onToggle={onToggle} />
      ))}
    </div>
  );
}
