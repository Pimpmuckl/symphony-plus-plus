import type { DashboardMutationPayload, DashboardPayload } from "@/types/dashboard";
import { useCallback } from "react";

import { mutationHeaders, operatorApiUrl, operatorFetch, readDashboardApiResponse, withLocalOperatorReconnect } from "./runtime";

type OperatorSettingsPayload = {
  work_request_archive_after_days?: number;
  solo_session_delete_after_days?: number;
  open_dashboard_on_boot?: boolean;
};

type RefreshAfterMutation = (payload?: DashboardMutationPayload) => Promise<void>;

export function useDashboardOperatorSettings({
  dashboard,
  refreshAfterMutation,
}: {
  dashboard: DashboardPayload | null;
  refreshAfterMutation: RefreshAfterMutation;
}) {
  const settings = dashboard?.settings;
  const archiveAfterDays = settings?.work_request_archive_after_days ?? 14;
  const soloSessionDeleteAfterDays = settings?.solo_session_delete_after_days ?? 30;
  const openDashboardOnBoot = settings?.open_dashboard_on_boot ?? true;

  const updateOperatorSettings = useCallback(
    async (payload: OperatorSettingsPayload) => {
      await withLocalOperatorReconnect(async () => {
        const response = await operatorFetch(operatorApiUrl("/settings"), {
          method: "POST",
          headers: await mutationHeaders(),
          body: JSON.stringify(payload),
        });
        const responsePayload = (await readDashboardApiResponse(response, "Settings were not saved")) as DashboardMutationPayload;
        await refreshAfterMutation(responsePayload);
      });
    },
    [refreshAfterMutation],
  );

  const updateArchiveAfterDays = useCallback(
    (nextArchiveAfterDays: number) => updateOperatorSettings({ work_request_archive_after_days: nextArchiveAfterDays }),
    [updateOperatorSettings],
  );

  const updateSoloSessionDeleteAfterDays = useCallback(
    (nextDeleteAfterDays: number) => updateOperatorSettings({ solo_session_delete_after_days: nextDeleteAfterDays }),
    [updateOperatorSettings],
  );

  const updateOpenDashboardOnBoot = useCallback(
    (nextOpenDashboardOnBoot: boolean) => updateOperatorSettings({ open_dashboard_on_boot: nextOpenDashboardOnBoot }),
    [updateOperatorSettings],
  );

  return {
    archiveAfterDays,
    openDashboardOnBoot,
    soloSessionDeleteAfterDays,
    updateArchiveAfterDays,
    updateOpenDashboardOnBoot,
    updateSoloSessionDeleteAfterDays,
  };
}
