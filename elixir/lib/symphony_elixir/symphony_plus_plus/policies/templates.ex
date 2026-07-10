defmodule SymphonyElixir.SymphonyPlusPlus.Policies.Templates do
  @moduledoc false

  @worker_package_policy %{
    template: "worker_package",
    constraints: %{
      expiry_seconds: nil,
      planning_depth: "package",
      terminal_readiness_status: "ready_for_merge"
    },
    required_gates: ["package_acceptance", "focused_tests", "review_normal", "human_merge"],
    readiness_requirements: ["acceptance_criteria_met", "tests_passed", "review_normal_green"],
    review_suite: %{required: ["normal"], optional: ["deep"]}
  }

  @mcp_ci_required_policy @worker_package_policy
                          |> Map.put(:work_package_kind, "mcp")
                          |> Map.update!(:required_gates, &(&1 ++ ["ci_waiting"]))
                          |> Map.update!(:readiness_requirements, &(&1 ++ ["ci_waiting"]))
  @templates %{
    "quick_fix" => %{
      template: "quick_fix",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "brief",
        terminal_readiness_status: "ready_for_merge"
      },
      required_gates: ["focused_tests", "review_brief"],
      readiness_requirements: ["implementation_complete", "tests_passed", "review_brief_green"],
      review_suite: %{required: ["brief"], optional: ["normal"]}
    },
    "hotfix" => %{
      template: "hotfix",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "incident",
        terminal_readiness_status: "ready_for_merge"
      },
      required_gates: ["focused_tests", "review_emergency", "human_merge"],
      readiness_requirements: ["implementation_complete", "tests_passed", "review_emergency_green"],
      review_suite: %{required: ["emergency"], optional: []}
    },
    "docs" => %{
      template: "docs",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "brief",
        terminal_readiness_status: "ready_for_merge"
      },
      required_gates: ["focused_tests", "review_brief"],
      readiness_requirements: ["tests_passed", "review_brief_green"],
      review_suite: %{required: ["brief"], optional: ["normal"]}
    },
    "adapter" => %{
      template: "adapter",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_normal", "human_merge"],
      readiness_requirements: ["acceptance_criteria_met", "tests_passed", "review_normal_green"],
      review_suite: %{required: ["normal"], optional: ["deep"]}
    },
    "standard_pr" => @worker_package_policy,
    "mcp" => @worker_package_policy,
    "mcp_ci_required" => @mcp_ci_required_policy,
    "mcp_current_pr_state" => %{
      work_package_kind: "mcp",
      template: "worker_package",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_normal", "human_merge", "current_pr_state"],
      readiness_requirements: [
        "acceptance_criteria_met",
        "tests_passed",
        "review_normal_green",
        "current_pr_state"
      ],
      review_suite: %{required: ["normal"], optional: ["deep"]}
    },
    "mcp_review_suite_artifact" => %{
      work_package_kind: "mcp",
      template: "worker_package",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_normal", "human_merge", "review_suite_result"],
      readiness_requirements: [
        "acceptance_criteria_met",
        "tests_passed",
        "review_normal_green",
        "review_suite_result"
      ],
      review_suite: %{required: ["normal"], optional: ["deep"]}
    },
    "mcp_changed_file_scope_guard" => %{
      work_package_kind: "mcp",
      template: "worker_package",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_merge"
      },
      required_gates: [
        "package_acceptance",
        "focused_tests",
        "review_normal",
        "human_merge",
        "current_pr_state",
        "review_suite_result",
        "scope_guard"
      ],
      readiness_requirements: [
        "acceptance_criteria_met",
        "tests_passed",
        "review_normal_green",
        "current_pr_state",
        "review_suite_result",
        "scope_guard"
      ],
      review_suite: %{required: ["normal"], optional: ["deep"]}
    },
    "skill" => %{
      template: "worker_package",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_normal", "human_merge"],
      readiness_requirements: ["acceptance_criteria_met", "tests_passed", "review_normal_green"],
      review_suite: %{required: ["normal"], optional: ["deep"]}
    },
    "hooks" => %{
      template: "worker_package",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_normal", "human_merge"],
      readiness_requirements: ["acceptance_criteria_met", "tests_passed", "review_normal_green"],
      review_suite: %{required: ["normal"], optional: ["deep"]}
    },
    "phase_child" => %{
      template: "phase_child",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "package",
        terminal_readiness_status: "ready_for_architect_merge"
      },
      required_gates: ["package_acceptance", "focused_tests", "review_normal", "architect_merge"],
      readiness_requirements: [
        "acceptance_criteria_met",
        "tests_passed",
        "review_normal_green",
        "architect_ready"
      ],
      review_suite: %{required: ["normal"], optional: ["deep"]}
    },
    "investigation" => %{
      template: "investigation",
      constraints: %{
        expiry_seconds: nil,
        planning_depth: "findings",
        terminal_readiness_status: "ready_for_merge"
      },
      required_gates: ["findings_documented", "recommendation_artifact_recorded"],
      readiness_requirements: ["findings_complete", "recommendation_artifact_recorded"],
      review_suite: %{required: [], optional: ["brief"]}
    }
  }

  @type template :: %{
          template: String.t(),
          constraints: %{
            expiry_seconds: pos_integer() | nil,
            planning_depth: String.t(),
            terminal_readiness_status: String.t()
          },
          required_gates: [String.t()],
          readiness_requirements: [String.t()],
          review_suite: %{required: [String.t()], optional: [String.t()]}
        }

  @spec expand(String.t()) :: {:ok, template()} | {:error, :unknown_policy_template}
  def expand(kind) when is_binary(kind) do
    case Map.fetch(@templates, kind) do
      {:ok, template} -> {:ok, template}
      :error -> {:error, :unknown_policy_template}
    end
  end

  @spec resolve_key([String.t()]) ::
          {:ok, String.t(), template()} | {:error, :policy_template_mismatch | :unknown_policy_template}
  def resolve_key(templates) when is_list(templates) do
    matches =
      @templates
      |> Enum.filter(fn {key, template} ->
        Enum.all?(templates, fn requested -> requested in [key, template.template] end)
      end)

    case matches do
      [{key, template}] -> {:ok, key, template}
      [] -> unknown_or_mismatch(templates)
      _matches -> {:error, :policy_template_mismatch}
    end
  end

  defp unknown_or_mismatch(templates) do
    known? =
      Enum.all?(templates, fn requested ->
        Enum.any?(@templates, fn {key, template} -> requested in [key, template.template] end)
      end)

    if known?, do: {:error, :policy_template_mismatch}, else: {:error, :unknown_policy_template}
  end

  @spec key?(String.t()) :: boolean()
  def key?(key) when is_binary(key), do: Map.has_key?(@templates, key)

  @spec compatible_kind?(String.t(), String.t()) :: boolean()
  def compatible_kind?(kind, policy_key) when is_binary(kind) and is_binary(policy_key) do
    case Map.fetch(@templates, policy_key) do
      {:ok, template} -> Map.get(template, :work_package_kind, policy_key) == kind
      :error -> false
    end
  end

  def compatible_kind?(_kind, _policy_key), do: false

  @spec work_package_kind(String.t()) :: {:ok, String.t()} | {:error, :unknown_policy_template}
  def work_package_kind(policy_key) when is_binary(policy_key) do
    case Map.fetch(@templates, policy_key) do
      {:ok, template} -> {:ok, Map.get(template, :work_package_kind, policy_key)}
      :error -> {:error, :unknown_policy_template}
    end
  end

  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(policy_key, requested) when is_binary(policy_key) and is_binary(requested) do
    case Map.fetch(@templates, policy_key) do
      {:ok, template} -> requested in [policy_key, template.template, Map.get(template, :work_package_kind)]
      :error -> false
    end
  end
end
