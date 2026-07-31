import { AlertTriangle, MessageSquareText } from "lucide-react";
import { AttentionBarButton } from "./attention-bar-button";
import type { TopPanelKey } from "./runtime";
import type { AttentionButtonConfig } from "./status-rail-types";
import type { AttentionItem } from "./workstream-attention";

export function AttentionBarControls({
  openPanel,
  attentionItems,
  onToggle,
}: {
  openPanel: TopPanelKey | null;
  attentionItems: AttentionItem[];
  onToggle: (panel: TopPanelKey | null) => void;
}) {
  const guidanceCount = attentionItems.filter((item) => item.tone === "guidance").length;
  const blockerCount = attentionItems.filter((item) => item.tone === "blocked").length;
  const configs: AttentionButtonConfig[] = [
    {
      icon: <MessageSquareText className="size-6" />,
      panel: "guidance",
      title: "Human Guidance Needed",
      tone: "guidance",
      value: guidanceCount,
    },
    {
      icon: <AlertTriangle className="size-6" />,
      panel: "blockers",
      title: "Active Blockers",
      tone: blockerCount === 0 ? "blocker-clear" : "blocker",
      value: blockerCount,
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
