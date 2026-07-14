defmodule SymphonyElixir.SymphonyPlusPlus.Planning.State do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type t :: %__MODULE__{
          work_package: WorkPackage.t(),
          plan_nodes: [PlanNode.t()] | nil,
          findings: [Finding.t()] | nil,
          progress_events: [ProgressEvent.t()] | nil,
          artifacts: [Artifact.t()] | nil,
          plan_version_material: [PlanNode.t() | map()] | nil,
          plan_nodes_omitted_count: non_neg_integer() | nil,
          findings_omitted_count: non_neg_integer() | nil,
          progress_events_omitted_count: non_neg_integer() | nil,
          artifacts_omitted_count: non_neg_integer() | nil
        }

  defstruct work_package: nil,
            plan_nodes: [],
            findings: [],
            progress_events: [],
            artifacts: [],
            plan_version_material: [],
            plan_nodes_omitted_count: nil,
            findings_omitted_count: nil,
            progress_events_omitted_count: nil,
            artifacts_omitted_count: nil
end
