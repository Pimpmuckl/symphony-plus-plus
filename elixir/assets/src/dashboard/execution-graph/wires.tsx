import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";

import type { ExecutionGraphLayoutModel, GraphOrientation } from "./model";
import { graphWireRoutes } from "./router";

type Routes = ReturnType<typeof graphWireRoutes>;
type Motion = "entering" | "leaving";
const SNAP_MS = 220;

export function GraphWires({ model, orientation }: { model: ExecutionGraphLayoutModel; orientation: GraphOrientation }) {
  const next = useMemo(() => graphWireRoutes(model, orientation), [model, orientation]);
  const signature = wireSignature(next);
  const current = useRef(next);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const [frame, setFrame] = useState<{ current: Routes; previous?: Routes; sequence: number }>({ current: next, sequence: 0 });

  useLayoutEffect(() => {
    if (wireSignature(current.current) === signature) return;
    const previous = current.current;
    current.current = next;
    clearTimeout(timer.current);
    setFrame(({ sequence }) => ({ current: next, previous, sequence: sequence + 1 }));
    timer.current = setTimeout(() => setFrame((value) => ({ ...value, previous: undefined })), SNAP_MS);
  }, [next, signature]);
  useEffect(() => () => clearTimeout(timer.current), []);

  return (
    <svg className="execution-graph__wires" width={model.width} height={model.height} aria-hidden="true" role="presentation" focusable="false">
      <WireLayer key={`current-${frame.sequence}`} routes={frame.current} motion={frame.previous ? "entering" : undefined} />
      {frame.previous ? <WireLayer key={`previous-${frame.sequence}`} routes={frame.previous} motion="leaving" /> : null}
    </svg>
  );
}

function WireLayer({ routes, motion }: { routes: Routes; motion?: Motion }) {
  return (
    <g className="execution-graph__wire-layer" data-motion={motion}>
      {routes.paths.map((route) => <path key={route.key} className={`execution-graph__edge${route.bundle ? " execution-graph__edge--bundle" : ""}`} data-edge={route.edge} data-state={route.state} data-route="orthogonal" data-bundle={route.bundle ? "true" : undefined} data-intent-count={route.intentCount} d={route.path} />)}
      {routes.gates.map((gate) => <g key={gate.key} className="execution-graph__join" data-join-for={gate.targetKey} data-progress={`${gate.satisfied}/${gate.required}`} data-state={gate.state}><path className="execution-graph__join-trunk" data-state={gate.state} d={gate.path} /><text className="execution-graph__join-label" x={gate.label.x} y={gate.label.y} textAnchor={gate.label.anchor}>{gate.satisfied === gate.required ? "✓" : `${gate.satisfied}/${gate.required}`}</text></g>)}
    </g>
  );
}

function wireSignature(routes: Routes) {
  return JSON.stringify([routes.paths.map(({ key, path, state }) => [key, path, state]), routes.gates.map(({ key, path, state }) => [key, path, state])]);
}
