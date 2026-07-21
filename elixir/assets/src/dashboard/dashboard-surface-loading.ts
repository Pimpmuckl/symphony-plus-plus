import type { DashboardPayload } from "@/types/dashboard";
import type { RefObject } from "react";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  dashboardCaughtMessage,
  isReconnectableLocalOperatorError,
  jsonHeaders,
  mergeDashboardPayload,
  operatorApiUrl,
  operatorFetch,
  readDashboardApiResponse,
  withLocalOperatorReconnect,
} from "./runtime";

export type DashboardSurface = "archived" | "solo";

export function useDashboardSurfaceLoading({
  dashboardRef,
  recordFailure,
  setDashboard,
  soloOpen,
  refreshVersion,
}: {
  dashboardRef: RefObject<DashboardPayload | null>;
  recordFailure: (message: string, immediate?: boolean, reconnectable?: boolean) => void;
  setDashboard: (dashboard: DashboardPayload | null) => void;
  soloOpen: boolean;
  refreshVersion: number;
}) {
  const [loading, setLoading] = useState<Record<DashboardSurface, boolean>>({ archived: false, solo: false });
  const requestVersions = useRef<Record<DashboardSurface, number>>({ archived: 0, solo: 0 });

  const loadSurface = useCallback(async (surface: DashboardSurface) => {
    const requestVersion = requestVersions.current[surface] + 1;
    requestVersions.current[surface] = requestVersion;
    setLoading((state) => ({ ...state, [surface]: true }));

    try {
      await withLocalOperatorReconnect(async () => {
        const response = await operatorFetch(operatorApiUrl(`/dashboard?surface=${surface}`), { headers: jsonHeaders() });
        const payload = (await readDashboardApiResponse(response, `Dashboard ${surface} data unavailable`)) as DashboardPayload;
        if (requestVersions.current[surface] !== requestVersion) return;
        setDashboard(mergeDashboardPayload(dashboardRef.current, payload));
      });
    } catch (caught) {
      if (requestVersions.current[surface] !== requestVersion) return;
      recordFailure(
        dashboardCaughtMessage(caught, `Dashboard ${surface} data unavailable`),
        false,
        isReconnectableLocalOperatorError(caught),
      );
    } finally {
      if (requestVersions.current[surface] === requestVersion) {
        setLoading((state) => ({ ...state, [surface]: false }));
      }
    }
  }, [dashboardRef, recordFailure, setDashboard]);

  const loadArchived = useCallback(() => loadSurface("archived"), [loadSurface]);

  useEffect(() => {
    let cancelled = false;
    queueMicrotask(() => {
      if (soloOpen && !cancelled) void loadSurface("solo");
    });
    return () => {
      cancelled = true;
    };
  }, [loadSurface, refreshVersion, soloOpen]);

  return {
    archivedLoading: loading.archived,
    loadArchived,
    soloLoading: loading.solo,
  };
}
