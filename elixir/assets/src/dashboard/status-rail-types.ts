import type { WorkRequestDetail } from "@/types/dashboard";
import type * as React from "react";
import type { DashboardUpdateAnimations, TopPanelDirection, TopPanelKey, TopPanelPhase } from "./runtime";
import type { AttentionItem, AttentionJumpDestination, AttentionSelect } from "./workstream-attention";

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
  now?: string;
  attentionItems: AttentionItem[];
  requestDetails: WorkRequestDetail[];
  onJumpToAttention: (destination: AttentionJumpDestination) => void;
  onSelectAttention: AttentionSelect;
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
