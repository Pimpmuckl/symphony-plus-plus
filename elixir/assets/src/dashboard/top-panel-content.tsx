import { AnimatedTopGrid } from "@/components/dashboard/motion";
import { BlockerPreviewCard } from "./blocker-preview-card";
import { EmptyPanel } from "./empty-panel";
import { GuidancePreviewCard } from "./guidance-preview-card";
import type { TopPanelContentProps } from "./status-rail-types";
import { TopTray } from "./top-tray";
import { blockerUpdateKey, guidanceUpdateKey } from "./update-animations";

export function TopPanelContent({
  panel,
  interactive = true,
  guidanceItems,
  blockerItems,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
}: TopPanelContentProps) {
  if (panel === "guidance") {
    return (
      <TopTray title="Decisions and input needed to keep work moving">
        {guidanceItems.length === 0 ? (
          <EmptyPanel title="No human guidance needed" compact />
        ) : (
          <AnimatedTopGrid className="top-tray-preview-grid grid gap-3">
            {guidanceItems.slice(0, 6).map((item, index) => (
              <GuidancePreviewCard
                key={`${item.source}-${item.id}`}
                item={item}
                index={index}
                onSelect={onSelectGuidance}
                motion={updateAnimations.motionFor(guidanceUpdateKey(item))}
              />
            ))}
          </AnimatedTopGrid>
        )}
      </TopTray>
    );
  }

  return (
    <TopTray title="Blocked packages and dependency waits">
      {blockerItems.length === 0 ? (
        <EmptyPanel title="No active blockers" compact />
      ) : (
        <AnimatedTopGrid className="top-tray-preview-grid grid gap-3">
          {blockerItems.map((item, index) => (
            <BlockerPreviewCard
              key={item.id}
              item={item}
              index={index}
              onSelectCard={interactive ? () => onSelectCard(item.selection) : undefined}
              motion={updateAnimations.motionFor(blockerUpdateKey(item))}
            />
          ))}
        </AnimatedTopGrid>
      )}
    </TopTray>
  );
}
