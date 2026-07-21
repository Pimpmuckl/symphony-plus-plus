import type { DashboardPayload } from "@/types/dashboard";
import type { RefObject } from "react";
import { useCallback, useEffect, useState } from "react";
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
}: {
  dashboardRef: RefObject<DashboardPayload | null>;
  recordFailure: (message: string, immediate?: boolean, reconnectable?: boolean) => void;
  setDashboard: (dashboard: DashboardPayload | null) => void;
  soloOpen: boolean;
}) {
  const [loading, setLoading] = useState<Record<DashboardSurface, boolean>>({ archived: false, solo: false });

  const loadSurface = useCallback(async (surface: DashboardSurface) => {
    setLoading((state) => ({ ...state, [surface]: true }));

    try {
      await withLocalOperatorReconnect(async () => {
        const response = await operatorFetch(operatorApiUrl(`/dashboard?surface=${surface}`), { headers: jsonHeaders() });
        const payload = (await readDashboardApiResponse(response, `Dashboard ${surface} data unavailable`)) as DashboardPayload;
        setDashboard(mergeDashboardPayload(dashboardRef.current, payload));
      });
    } catch (caught) {
      recordFailure(
        dashboardCaughtMessage(caught, `Dashboard ${surface} data unavailable`),
        false,
        isReconnectableLocalOperatorError(caught),
      );
    } finally {
      setLoading((state) => ({ ...state, [surface]: false }));
    }
  }, [dashboardRef, recordFailure, setDashboard]);

  useEffect(() => {
    let cancelled = false;
    queueMicrotask(() => {
      if (soloOpen && !cancelled) void loadSurface("solo");
    });
    return () => {
      cancelled = true;
    };
  }, [loadSurface, soloOpen]);

  return {
    archivedLoading: loading.archived,
    loadArchived: () => loadSurface("archived"),
    soloLoading: loading.solo,
  };
}
