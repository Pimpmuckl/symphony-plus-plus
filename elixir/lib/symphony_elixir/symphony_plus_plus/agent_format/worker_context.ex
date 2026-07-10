defmodule SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.Toon
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @redacted "[REDACTED]"
  @payload_key_limit 20
  @sensitive_agent_suffixes [
    "_access_key",
    "_api_key",
    "_apikey",
    "_authorization",
    "_credential",
    "_handoff",
    "_password",
    "_secret",
    "_token",
    "_verifier"
  ]
  @sensitive_agent_keys MapSet.new([
                          "access_key",
                          "api_key",
                          "apikey",
                          "authorization",
                          "aws_access_key_id",
                          "bearer",
                          "claim_lease_id",
                          "claim_secret",
                          "client_secret",
                          "credential",
                          "grant_verifier",
                          "handoff",
                          "password",
                          "private_key",
                          "private_payload",
                          "proof_hash",
                          "raw_secret",
                          "refresh_token",
                          "secret",
                          "secret_hash",
                          "secret_key",
                          "security_token",
                          "session_token",
                          "token",
                          "verifier",
                          "work_key",
                          "work_key_secret"
                        ])

  @type json_like :: Toon.json_like()

  @spec encode_tool_payload(map()) :: String.t()
  def encode_tool_payload(payload) when is_map(payload) do
    payload
    |> tool_agent_payload()
    |> agent_safe()
    |> encode_agent_payload()
  end

  @spec encode_virtual_file(State.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, :unknown_virtual_file}
  def encode_virtual_file(%State{} = state, file_name, opts \\ []) when is_binary(file_name) do
    with {:ok, payload} <- virtual_file_payload(state, file_name, opts) do
      {:ok, encode_agent_payload(payload)}
    end
  end

  @spec virtual_file_payload(State.t(), String.t(), keyword()) :: {:ok, map()} | {:error, :unknown_virtual_file}
  def virtual_file_payload(%State{} = state, "context.md", opts) do
    {:ok, base_payload(state, "context.md", opts) |> Map.put("work_package", work_package_context(state.work_package))}
  end

  def virtual_file_payload(%State{} = state, "task_plan.md", opts) do
    payload =
      state
      |> base_payload("task_plan.md", opts)
      |> put_optional("version", Keyword.get(opts, :version))
      |> Map.put("plan_nodes", Enum.map(state.plan_nodes, &plan_node_payload/1))
      |> Map.put("omitted", %{"plan_nodes" => state.plan_nodes_omitted_count || 0})

    {:ok, payload}
  end

  def virtual_file_payload(%State{} = state, "findings.md", opts) do
    payload =
      state
      |> base_payload("findings.md", opts)
      |> Map.put("findings", Enum.map(state.findings, &finding_payload/1))
      |> Map.put("omitted", %{"findings" => state.findings_omitted_count || 0})

    {:ok, payload}
  end

  def virtual_file_payload(%State{} = state, "progress.md", opts) do
    payload =
      state
      |> base_payload("progress.md", opts)
      |> Map.put("progress_events", Enum.map(state.progress_events, &progress_event_payload/1))
      |> Map.put("omitted", %{"progress_events" => state.progress_events_omitted_count || 0})

    {:ok, payload}
  end

  def virtual_file_payload(%State{} = state, "acceptance.md", opts) do
    payload =
      state
      |> base_payload("acceptance.md", opts)
      |> Map.put(
        "acceptance",
        Enum.map(state.work_package.acceptance_criteria || [], fn criterion ->
          %{"source" => Redactor.redact_text(criterion)}
        end)
      )

    {:ok, payload}
  end

  def virtual_file_payload(%State{} = state, "review_suite.md", opts) do
    payload =
      state
      |> base_payload("review_suite.md", opts)
      |> Map.put("review_suite", review_suite_payload(state))

    {:ok, payload}
  end

  def virtual_file_payload(%State{} = state, "handoff.md", opts) do
    payload =
      state
      |> base_payload("handoff.md", opts)
      |> Map.put("acceptance", Enum.map(state.work_package.acceptance_criteria || [], &Redactor.redact_text/1))
      |> Map.put("latest_progress", state.progress_events |> Enum.take(-3) |> Enum.map(&progress_summary_payload/1))
      |> Map.put("findings", Enum.map(state.findings, &finding_summary_payload/1))
      |> Map.put("artifacts", Enum.map(state.artifacts, &artifact_payload/1))
      |> Map.put("omitted", %{
        "findings" => state.findings_omitted_count || 0,
        "progress_events" => state.progress_events_omitted_count || 0,
        "artifacts" => state.artifacts_omitted_count || 0
      })

    {:ok, payload}
  end

  def virtual_file_payload(%State{}, _file_name, _opts), do: {:error, :unknown_virtual_file}

  defp base_payload(%State{work_package: %WorkPackage{} = work_package}, file_name, opts) do
    %{
      "file" => file_name,
      "work_package_id" => work_package.id,
      "title" => Redactor.redact_text(work_package.title),
      "status" => work_package.status
    }
    |> put_optional("uri", Keyword.get(opts, :uri))
  end

  defp work_package_context(%WorkPackage{} = work_package) do
    %{
      "id" => work_package.id,
      "kind" => work_package.kind,
      "policy_template" => policy_key(work_package),
      "status" => work_package.status,
      "repo" => Redactor.redact_text(work_package.repo),
      "base_branch" => Redactor.redact_text(work_package.base_branch),
      "branch_pattern" => Redactor.redact_text(work_package.branch_pattern),
      "allowed_file_globs" => Enum.map(work_package.allowed_file_globs || [], &Redactor.redact_text/1),
      "parent_id" => Redactor.redact_text(work_package.parent_id),
      "owner_id" => Redactor.redact_text(work_package.owner_id),
      "product_description" => Redactor.redact_text(work_package.product_description),
      "engineering_scope" => Redactor.redact_text(work_package.engineering_scope)
    }
  end

  defp review_suite_payload(%State{work_package: %WorkPackage{} = work_package} = state) do
    case Templates.expand(policy_key(work_package)) do
      {:ok, template} ->
        template = effective_review_policy(state, template)

        %{
          "policy_template" => template.template,
          "required_gates" => template.required_gates,
          "readiness_requirements" => template.readiness_requirements,
          "required_review_profiles" => review_suite_required_profiles(state, template),
          "optional_review_profiles" => template.review_suite.optional
        }

      {:error, :unknown_policy_template} ->
        %{"policy_template" => policy_key(work_package), "error" => "unknown_policy_template"}
    end
  end

  defp effective_review_policy(%State{review_suite_required_profiles: profiles}, template) when is_list(profiles) do
    ReviewProfiles.apply_required_profiles(template, profiles)
  end

  defp effective_review_policy(%State{}, template), do: template

  defp review_suite_required_profiles(%State{review_suite_required_profiles: profiles}, _template) when is_list(profiles), do: redacted_profiles(profiles)
  defp review_suite_required_profiles(%State{}, template), do: template.review_suite.required

  defp redacted_profiles(profiles), do: Redactor.redact_output(profiles)

  defp plan_node_payload(%PlanNode{} = plan_node) do
    %{
      "id" => plan_node.id,
      "title" => Redactor.redact_text(plan_node.title),
      "status" => plan_node.status,
      "body" => Redactor.redact_text(plan_node.body)
    }
  end

  defp finding_payload(%Finding{} = finding) do
    %{
      "id" => finding.id,
      "title" => Redactor.redact_text(finding.title),
      "severity" => finding.severity,
      "body" => Redactor.redact_text(finding.body),
      "created_at" => timestamp(finding.created_at)
    }
  end

  defp finding_summary_payload(%Finding{} = finding) do
    %{
      "id" => finding.id,
      "title" => Redactor.redact_text(finding.title),
      "severity" => finding.severity,
      "created_at" => timestamp(finding.created_at)
    }
  end

  defp progress_event_payload(%ProgressEvent{} = event) do
    %{
      "id" => event.id,
      "summary" => Redactor.redact_text(event.summary),
      "status" => Redactor.redact_text(event.status),
      "body" => Redactor.redact_text(event.body),
      "actor_id" => Redactor.redact_text(event.actor_id),
      "actor_type" => Redactor.redact_text(event.actor_type),
      "created_at" => timestamp(event.created_at),
      "payload" => payload_overview(event.payload || %{})
    }
  end

  defp progress_summary_payload(%ProgressEvent{} = event) do
    %{
      "id" => event.id,
      "summary" => Redactor.redact_text(event.summary),
      "status" => Redactor.redact_text(event.status),
      "created_at" => timestamp(event.created_at)
    }
  end

  defp artifact_payload(%Artifact{} = artifact) do
    %{
      "id" => artifact.id,
      "path" => Redactor.redact_text(artifact.path),
      "title" => Redactor.redact_text(artifact.title),
      "kind" => artifact.kind,
      "uri" => Redactor.redact_text(artifact.uri),
      "metadata" => payload_overview(artifact.metadata || %{})
    }
  end

  defp tool_agent_payload(%{"progress_event" => %{} = event} = payload) do
    Map.put(payload, "progress_event", Map.update(event, "payload", payload_overview(%{}), &payload_overview/1))
  end

  defp tool_agent_payload(payload), do: payload

  defp payload_overview(%{} = payload) do
    key_count = map_size(payload)
    sensitive_key_count = payload |> Map.keys() |> Enum.count(&sensitive_agent_key?(to_string(&1)))

    %{
      "type" => "object",
      "key_count" => key_count,
      "sensitive_key_count" => sensitive_key_count,
      "omitted_keys" => max(key_count - @payload_key_limit, 0)
    }
  end

  defp payload_overview(values) when is_list(values) do
    %{"type" => "list", "item_count" => length(values)}
  end

  defp payload_overview(nil), do: %{"type" => "null"}
  defp payload_overview(value) when is_boolean(value), do: %{"type" => "boolean"}
  defp payload_overview(value) when is_number(value), do: %{"type" => "number"}
  defp payload_overview(value) when is_binary(value), do: %{"type" => "string"}
  defp payload_overview(_value), do: %{"type" => "other"}

  defp agent_safe(value) do
    value
    |> Redactor.redact_output()
    |> redact_agent_sensitive_values()
  end

  defp redact_agent_sensitive_values(%{} = map) do
    Map.new(map, fn {key, value} ->
      key = to_string(key)
      value = if sensitive_agent_key?(key), do: @redacted, else: redact_agent_sensitive_values(value)
      {key, value}
    end)
  end

  defp redact_agent_sensitive_values(values) when is_list(values), do: Enum.map(values, &redact_agent_sensitive_values/1)
  defp redact_agent_sensitive_values(value), do: value

  defp sensitive_agent_key?(key) do
    normalized =
      key
      |> camel_to_snake()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    MapSet.member?(@sensitive_agent_keys, normalized) or
      Enum.any?(@sensitive_agent_suffixes, &String.ends_with?(normalized, &1))
  end

  defp encode_agent_payload(payload) do
    Toon.encode(payload)
  rescue
    ArgumentError ->
      Toon.encode(%{"format" => "compact_json_fallback", "json" => Jason.encode!(payload)})
  end

  defp policy_key(%WorkPackage{policy_template: policy_template}) when is_binary(policy_template) and policy_template != "" do
    policy_template
  end

  defp policy_key(%WorkPackage{kind: kind}), do: kind

  defp put_optional(payload, _key, nil), do: payload
  defp put_optional(payload, key, value), do: Map.put(payload, key, value)

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp(nil), do: nil

  defp camel_to_snake(key) do
    key
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
  end
end
