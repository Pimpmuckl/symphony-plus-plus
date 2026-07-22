import { memo, useEffectEvent, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";

import type { ExecutionGraphLayoutModel, GraphOrientation } from "./model";
import { graphWireRoutes } from "./router";
import { wireMorphs } from "./wire-morphs";

type Routes = ReturnType<typeof graphWireRoutes>;
type Motion = "entering" | "leaving";
const SNAP_MS = 220;

export const GraphWires = memo(function GraphWires({ model, orientation }: { model: ExecutionGraphLayoutModel; orientation: GraphOrientation }) {
  const next = useMemo(() => graphWireRoutes(model, orientation), [model, orientation]);
  const signature = wireSignature(next);
  const current = useRef(next);
  const [frame, setFrame] = useState<{ current: Routes; previous?: Routes; sequence: number }>({ current: next, sequence: 0 });

  const animate = useEffectEvent(() => {
    const previous = current.current;
    current.current = next;
    setFrame(({ sequence }) => ({ current: next, previous, sequence: sequence + 1 }));
    return setTimeout(() => setFrame((value) => ({ ...value, previous: undefined })), SNAP_MS);
  });

  useLayoutEffect(() => {
    if (wireSignature(current.current) === signature) return;
    const timer = animate();
    return () => clearTimeout(timer);
  }, [signature]);

  return (
    <svg className="execution-graph__wires" width={model.width} height={model.height} aria-hidden="true" role="presentation" focusable="false">
      <WireLayer key={`current-${frame.sequence}`} routes={frame.current} motion={frame.previous ? "entering" : undefined} />
      {frame.previous ? <WireTransition key={`previous-${frame.sequence}`} from={frame.previous} to={frame.current} /> : null}
    </svg>
  );
});

function WireTransition({ from, to }: { from: Routes; to: Routes }) {
  const morphs = wireMorphs(from.paths, to.paths);
  const moving = new Set(morphs.map((morph) => morph.from.key));
  const leaving = { paths: from.paths.filter((path) => !moving.has(path.key)), gates: from.gates };

  return (
    <>
      <WireLayer routes={leaving} motion="leaving" />
      <g className="execution-graph__wire-layer" data-motion="morphing" style={{ "--wire-snap-duration": `${SNAP_MS}ms` } as CSSProperties}>
        {morphs.map(({ from: route, to: target }) => (
          <path key={`${route.key}:${target.key}`} className={`execution-graph__edge${route.bundle ? " execution-graph__edge--bundle" : ""}`} data-edge={route.edge} data-state={route.state} data-route="orthogonal" data-intent-count={route.intentCount} d={route.path} style={{ "--wire-from": `path("${route.path}")`, "--wire-to": `path("${target.path}")` } as CSSProperties} />
        ))}
      </g>
    </>
  );
}

function WireLayer({ routes, motion }: { routes: Routes; motion?: Motion }) {
  return (
    <g className="execution-graph__wire-layer" data-motion={motion}>
      {routes.paths.map((route) => <path key={route.key} className={`execution-graph__edge${route.bundle ? " execution-graph__edge--bundle" : ""}`} data-edge={route.edge} data-state={route.state} data-route="orthogonal" data-bundle={route.bundle ? "true" : undefined} data-intent-count={route.intentCount} d={route.path} />)}
      {routes.paths.map((route) => route.source ? <circle key={`source:${route.key}`} className="execution-graph__source" data-state={route.state} cx={route.source.x} cy={route.source.y} r="3" /> : null)}
      {routes.gates.map((gate) => <g key={gate.key} className="execution-graph__join" data-join-for={gate.targetKey} data-progress={`${gate.satisfied}/${gate.required}`} data-state={gate.state}><path className="execution-graph__join-trunk" data-state={gate.state} d={gate.path} /><text className="execution-graph__join-label" x={gate.label.x} y={gate.label.y} textAnchor={gate.label.anchor}>{gate.satisfied === gate.required ? "✓" : `${gate.satisfied}/${gate.required}`}</text></g>)}
    </g>
  );
}

function wireSignature(routes: Routes) {
  return JSON.stringify([routes.paths.map(({ key, path, state }) => [key, path, state]), routes.gates.map(({ key, path, state }) => [key, path, state])]);
}
