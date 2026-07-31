import { AnimatedTopGrid } from "@/components/dashboard/motion";
import { AttentionPreviewCard } from "./attention-preview-card";
import { EmptyPanel } from "./empty-panel";
import type { TopPanelContentProps } from "./status-rail-types";
import { TopTray } from "./top-tray";
import { attentionLocationForItem } from "./workstream-attention";

export function TopPanelContent({
  panel,
  interactive = true,
  now,
  attentionItems,
  requestDetails,
  onJumpToAttention,
  onSelectAttention,
  updateAnimations,
}: TopPanelContentProps) {
  const items = attentionItems.filter((item) => item.tone === (panel === "guidance" ? "guidance" : "blocked"));

  if (panel === "guidance") {
    return (
      <TopTray title="Decisions and input needed to keep work moving">
        {items.length === 0 ? (
          <EmptyPanel title="No human guidance needed" compact />
        ) : (
          <AnimatedTopGrid className="top-tray-preview-grid grid gap-3">
            {items.slice(0, 6).map((item, index) => (
              <AttentionPreviewCard
                key={item.key}
                item={item}
                index={index}
                location={attentionLocationForItem(item, requestDetails)}
                onJump={interactive ? onJumpToAttention : undefined}
                onSelect={interactive ? () => onSelectAttention({ items: [item] }) : undefined}
                motion={updateAnimations.motionFor(item.key)}
              />
            ))}
          </AnimatedTopGrid>
        )}
      </TopTray>
    );
  }

  return (
    <TopTray title="Blocked packages and dependency waits">
      {items.length === 0 ? (
        <EmptyPanel title="No active blockers" compact />
      ) : (
        <AnimatedTopGrid className="top-tray-preview-grid grid gap-3">
          {items.map((item, index) => (
            <AttentionPreviewCard
              key={item.key}
              item={item}
              index={index}
              location={attentionLocationForItem(item, requestDetails)}
              now={now}
              onJump={interactive ? onJumpToAttention : undefined}
              onSelect={interactive ? () => onSelectAttention({ items: [item] }) : undefined}
              motion={updateAnimations.motionFor(item.key)}
            />
          ))}
        </AnimatedTopGrid>
      )}
    </TopTray>
  );
}
