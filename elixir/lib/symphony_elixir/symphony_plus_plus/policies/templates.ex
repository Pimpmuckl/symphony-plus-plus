defmodule SymphonyElixir.SymphonyPlusPlus.Policies.Templates do
  @moduledoc false

  @worker_package_policy %{
    template: "worker_package",
    constraints: %{
      expiry_seconds: nil,
      planning_depth: "package",
      terminal_readiness_status: "ready_for_merge"
    },
    required_gates: ["package_acceptance", "human_merge"]
  }

  @templates %{
    "quick_fix" => %{
      template: "quick_fix",
      constraints: %{expiry_seconds: nil, planning_depth: "brief", terminal_readiness_status: "ready_for_merge"},
      required_gates: []
    },
    "hotfix" => %{
      template: "hotfix",
      constraints: %{expiry_seconds: nil, planning_depth: "incident", terminal_readiness_status: "ready_for_merge"},
      required_gates: ["human_merge"]
    },
    "docs" => %{
      template: "docs",
      constraints: %{expiry_seconds: nil, planning_depth: "brief", terminal_readiness_status: "ready_for_merge"},
      required_gates: []
    },
    "adapter" => @worker_package_policy,
    "standard_pr" => @worker_package_policy,
    "mcp" => @worker_package_policy,
    "mcp_current_pr_state" =>
      @worker_package_policy
      |> Map.put(:kind, "mcp")
      |> Map.update!(:required_gates, &(&1 ++ ["current_pr_state"])),
    "mcp_changed_file_scope_guard" =>
      @worker_package_policy
      |> Map.put(:kind, "mcp")
      |> Map.update!(:required_gates, &(&1 ++ ["current_pr_state", "scope_guard"])),
    "skill" => @worker_package_policy,
    "hooks" => @worker_package_policy,
    "investigation" => %{
      template: "investigation",
      constraints: %{expiry_seconds: nil, planning_depth: "findings", terminal_readiness_status: "ready_for_merge"},
      required_gates: ["findings_documented"]
    }
  }

  @type template :: %{
          template: String.t(),
          constraints: %{
            expiry_seconds: pos_integer() | nil,
            planning_depth: String.t(),
            terminal_readiness_status: String.t()
          },
          required_gates: [String.t()]
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
      {:ok, template} -> Map.get(template, :kind, policy_key) == kind
      :error -> false
    end
  end

  def compatible_kind?(_kind, _policy_key), do: false

  @spec kind(String.t()) :: {:ok, String.t()} | {:error, :unknown_policy_template}
  def kind(policy_key) when is_binary(policy_key) do
    case Map.fetch(@templates, policy_key) do
      {:ok, template} -> {:ok, Map.get(template, :kind, policy_key)}
      :error -> {:error, :unknown_policy_template}
    end
  end

  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(policy_key, requested) when is_binary(policy_key) and is_binary(requested) do
    case Map.fetch(@templates, policy_key) do
      {:ok, template} -> requested in [policy_key, template.template, Map.get(template, :kind)]
      :error -> false
    end
  end
end
