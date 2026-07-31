import type { TopPanelKey } from "./runtime";
import { TopPanelCarousel } from "./top-panel-carousel";
import type { TopPanelContentProps } from "./status-rail-types";

export function StatusRail({
  openPanel,
  attentionItems,
  requestDetails,
  now,
  onJumpToAttention,
  onSelectAttention,
  updateAnimations,
}: Omit<TopPanelContentProps, "panel" | "interactive"> & {
  openPanel: TopPanelKey | null;
}) {
  const panelContentProps = {
    attentionItems,
    requestDetails,
    now,
    onJumpToAttention,
    onSelectAttention,
    updateAnimations,
  };

  return (
    <section className="dashboard-top-panel-anchor top-panel-inline" data-open-panel={openPanel ?? "none"}>
      <TopPanelCarousel activePanel={openPanel} {...panelContentProps} />
    </section>
  );
}
