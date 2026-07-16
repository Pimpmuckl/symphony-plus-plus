import { Sparkles } from "lucide-react";
import { triggerDashboardAnimationTest } from "@/components/dashboard/motion";

export function UpdateSimulationControls() {
  return (
    <button type="button" className="update-sim-button" onClick={triggerDashboardAnimationTest}>
      <Sparkles className="size-3.5" />
      Test animations
    </button>
  );
}
