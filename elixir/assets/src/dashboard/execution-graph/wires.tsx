import { memo, useEffectEvent, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";

import type { ExecutionGraphLayoutModel, GraphOrientation } from "./model";
import { graphWireRoutes } from "./router";
import { wireTransitionLayers } from "./wire-morphs";

type Routes = ReturnType<typeof graphWireRoutes>;
type Motion = "entering" | "leaving";
type Bounds = { width: number; height: number };
const SNAP_MS = 220;

export const GraphWires = memo(function GraphWires({ model, orientation }: { model: ExecutionGraphLayoutModel; orientation: GraphOrientation }) {
  const next = useMemo(() => graphWireRoutes(model, orientation), [model, orientation]);
  const signature = wireSignature(next);
  const current = useRef(next);
  const bounds = useRef<Bounds>({ width: model.width, height: model.height });
  const [frame, setFrame] = useState<{ current: Routes; previous?: Routes; previousBounds?: Bounds; sequence: number }>({ current: next, sequence: 0 });

  const animate = useEffectEvent((target: Routes, targetBounds: Bounds) => {
    const previous = current.current;
    const previousBounds = bounds.current;
    current.current = target;
    bounds.current = targetBounds;
    setFrame(({ sequence }) => ({ current: target, previous, previousBounds, sequence: sequence + 1 }));
    return setTimeout(() => setFrame((value) => ({ ...value, previous: undefined, previousBounds: undefined })), SNAP_MS);
  });

  useLayoutEffect(() => {
    const nextBounds = { width: model.width, height: model.height };
    if (wireSignature(current.current) === signature) {
      bounds.current = nextBounds;
      return;
    }
    const timer = animate(next, nextBounds);
    return () => clearTimeout(timer);
  }, [model.height, model.width, next, signature]);
  const transition = frame.previous ? wireTransitionLayers(frame.previous.paths, frame.current.paths) : undefined;
  const currentRoutes = transition ? { ...frame.current, paths: transition.entering } : frame.current;

  return (
    <svg className="execution-graph__wires" width={Math.max(model.width, frame.previousBounds?.width ?? 0)} height={Math.max(model.height, frame.previousBounds?.height ?? 0)} aria-hidden="true" role="presentation" focusable="false">
      <WireLayer key={`current-${frame.sequence}`} routes={currentRoutes} motion={transition ? "entering" : undefined} />
      {frame.previous && transition ? <WireTransition key={`previous-${frame.sequence}`} from={frame.previous} to={frame.current} transition={transition} /> : null}
    </svg>
  );
});

function WireTransition({ from, to, transition }: { from: Routes; to: Routes; transition: ReturnType<typeof wireTransitionLayers> }) {
  const leaving = { paths: transition.leaving, gates: from.gates.filter((gate) => !to.gates.some((current) => current.key === gate.key)) };

  return (
    <>
      <WireLayer routes={leaving} motion="leaving" />
      <g className="execution-graph__wire-layer" data-motion="morphing" style={{ "--wire-snap-duration": `${SNAP_MS}ms` } as CSSProperties}>
        {transition.morphs.map(({ from: route, to: target }) => (
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
