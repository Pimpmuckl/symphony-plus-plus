import { useCallback, useMemo } from "react";

import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { workRequestExecutionGraphModel } from "./execution-graph/adapter";
import { WorkRequestExecutionGraph } from "./work-request-execution-graph";
import type { CardDetailSelect } from "./runtime";
import type { ContextPathPart } from "./workstream-context-path";
import { groupDirectAttention, workPackageDirectAttention, type AttentionSelect } from "./workstream-attention";

export default function WorkRequestExecutionGraphLoading({
  activeBlockingEdges,
  detail,
  guidanceItems,
  now,
  packageById,
  onSelectCard,
  onSelectAttention,
  requestPath,
}: {
  activeBlockingEdges: ActiveBlockingEdge[];
  detail: WorkRequestDetail;
  guidanceItems: GuidanceItem[];
  now?: string;
  packageById: Map<string, WorkPackageCard>;
  onSelectCard: CardDetailSelect;
  onSelectAttention: AttentionSelect;
  requestPath: ContextPathPart[];
}) {
  const slicesById = useMemo(() => new Map((detail.work_packages ?? []).map((slice) => [slice.id, slice])), [detail.work_packages]);
  const model = useMemo(() => workRequestExecutionGraphModel(detail, { includeHistorical: true }), [detail]);
  const attentionTargets = useMemo(() => {
    const targets = new Map<string, ReturnType<typeof workPackageDirectAttention>>();
    for (const slice of detail.work_packages ?? []) {
      const pkg = packageById.get(slice.work_package_id || slice.id);
      targets.set(`work_package:${slice.id}`, workPackageDirectAttention(detail, slice, pkg, activeBlockingEdges, guidanceItems));
    }
    for (const group of detail.product_tree?.nodes ?? []) {
      targets.set(`group:${group.id}`, groupDirectAttention(detail, group.id, packageById, activeBlockingEdges, guidanceItems));
    }
    return new Map([...targets].filter((entry): entry is [string, NonNullable<typeof entry[1]>] => Boolean(entry[1])));
  }, [activeBlockingEdges, detail, guidanceItems, packageById]);
  const selectWorkPackage = useCallback((workPackageId: string) => {
    const slice = slicesById.get(workPackageId);
    const pkg = packageById.get(slice?.work_package_id || workPackageId);
    if (slice) onSelectCard({ kind: "slice", detail, slice, pkg });
    else if (pkg) onSelectCard({ kind: "package", detail, pkg });
  }, [detail, onSelectCard, packageById, slicesById]);
  const selectAttention = useCallback((entityKey: string) => {
    const target = attentionTargets.get(entityKey)?.target;
    if (!target) return;
    onSelectAttention(target);
  }, [attentionTargets, onSelectAttention]);

  return <WorkRequestExecutionGraph attentionByEntity={attentionTargets} model={model} now={now} onSelectAttention={selectAttention} onSelectWorkPackage={selectWorkPackage} contextPath={requestPath} />;
}
