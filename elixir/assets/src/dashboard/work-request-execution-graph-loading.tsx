import { useCallback, useMemo } from "react";

import type { WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { workRequestExecutionGraphModel } from "./execution-graph/adapter";
import { WorkRequestExecutionGraph } from "./work-request-execution-graph";
import type { CardDetailSelect } from "./runtime";
import type { ContextPathPart } from "./workstream-context-path";

export default function WorkRequestExecutionGraphLoading({
  detail,
  now,
  packageById,
  onSelectCard,
  requestPath,
}: {
  detail: WorkRequestDetail;
  now?: string;
  packageById: Map<string, WorkPackageCard>;
  onSelectCard: CardDetailSelect;
  requestPath: ContextPathPart[];
}) {
  const slicesById = useMemo(() => new Map((detail.work_packages ?? []).map((slice) => [slice.id, slice])), [detail.work_packages]);
  const model = useMemo(() => workRequestExecutionGraphModel(detail, { includeHistorical: true }), [detail]);
  const selectWorkPackage = useCallback((workPackageId: string) => {
    const slice = slicesById.get(workPackageId);
    const pkg = packageById.get(slice?.work_package_id || workPackageId);
    if (slice) onSelectCard({ kind: "slice", detail, slice, pkg });
    else if (pkg) onSelectCard({ kind: "package", detail, pkg });
  }, [detail, onSelectCard, packageById, slicesById]);

  return <WorkRequestExecutionGraph model={model} now={now} onSelectWorkPackage={selectWorkPackage} contextPath={requestPath} />;
}
