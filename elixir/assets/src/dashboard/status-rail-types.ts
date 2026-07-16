import type { GuidanceItem } from "@/types/dashboard";
import type * as React from "react";
import type { BlockerItem } from "./dashboard-state";
import type { CardDetailSelect, DashboardUpdateAnimations, TopPanelDirection, TopPanelKey, TopPanelPhase } from "./runtime";

export type AttentionButtonConfig = {
  icon: React.ReactNode;
  panel: TopPanelKey;
  title: string;
  tone: "guidance" | "blocker" | "blocker-clear";
  value: number;
};

export type TopPanelContentProps = {
  panel: TopPanelKey;
  interactive?: boolean;
  guidanceItems: GuidanceItem[];
  blockerItems: BlockerItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
};

export type TopPanelCarouselState = {
  visiblePanel: TopPanelKey | null;
  previousPanel: TopPanelKey | null;
  phase: TopPanelPhase;
  direction: TopPanelDirection;
  height: number | "auto";
  transitionHeights: { from: number; to: number };
};

export type TopPanelCarouselAction =
  | { type: "replace"; state: TopPanelCarouselState }
  | { type: "patch"; state: Partial<TopPanelCarouselState> };
