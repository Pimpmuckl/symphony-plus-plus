defmodule SymphonyElixir.SymphonyPlusPlus.CreateWork do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.ReviewRequirement
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ScopeConstraints

  import Ecto.Query, only: [from: 2]

  @default_kind "quick_fix"
  @required_fields ["repo", "base_branch", "title"]
  @scope_guard_gate "scope_guard"

  @type request :: map()
  @type creation :: %{
          work_package: WorkPackage.t(),
          worker_grant: map(),
          virtual_files: %{String.t() => String.t()},
          policy: Templates.template()
        }

  @type error ::
          :invalid_acceptance_criteria
          | :invalid_allowed_file_globs
          | :invalid_kind
          | :invalid_policy_template
          | :invalid_request
          | :invalid_status
          | :invalid_review_requirement
          | :sensitive_review_requirement
          | :invalid_work_package_id
          | :missing_acceptance_criteria
          | :missing_allowed_file_globs
          | :non_documentation_allowed_file_globs
          | :overbroad_allowed_file_globs
          | :parent_not_supported
          | :policy_template_mismatch
          | :kind_not_dispatchable
          | :unknown_policy_template
          | {:missing_required_field, String.t()}
          | Changeset.t()
          | WorkPackageRepository.error()
          | PlanningRepository.error()
          | AccessGrantService.error()
          | Renderer.error()

  @spec parse_request(term()) :: {:ok, request()} | {:error, error()}
  def parse_request(raw_request) when is_map(raw_request) do
    attrs = normalize_keys(raw_request)

    with {:ok, attrs} <- require_dispatchable(attrs),
         {:ok, attrs} <- normalize_required_fields(attrs),
         {:ok, attrs} <- normalize_optional_id(attrs),
         {:ok, policy_templates} <- explicit_policy_templates(attrs),
         {:ok, kind} <- normalize_kind(attrs, policy_templates),
         {:ok, policy_key, policy} <- policy_for(kind, policy_templates),
         {:ok, review_requirement} <- normalize_optional_review_requirement(attrs),
         {:ok, acceptance_criteria} <- normalize_acceptance_criteria(Map.get(attrs, "acceptance_criteria", [])),
         {:ok, allowed_file_globs} <- normalize_allowed_file_globs(Map.get(attrs, "allowed_file_globs", [])),
         :ok <- require_acceptance_criteria(policy, acceptance_criteria),
         :ok <- require_scope_guard_constraints(policy, allowed_file_globs),
         :ok <- require_docs_scope(kind, allowed_file_globs) do
      {:ok,
       attrs
       |> Map.take([
         "id",
         "repo",
         "base_branch",
         "title",
         "product_description",
         "engineering_scope",
         "branch_pattern",
         "owner_id"
       ])
       |> Map.put("kind", kind)
       |> Map.put("policy_template", policy_key)
       |> Map.put("acceptance_criteria", acceptance_criteria)
       |> Map.put("allowed_file_globs", allowed_file_globs)
       |> Map.put("parent_id", nil)
       |> Map.put("status", "ready_for_worker")
       |> maybe_put_review_requirement(review_requirement)
       |> Map.put("policy", effective_policy(policy, review_requirement))}
    end
  end

  def parse_request(_raw_request), do: {:error, :invalid_request}

  @spec create(module(), map()) :: {:ok, creation()} | {:error, error()}
  def create(repo, request) when is_atom(repo) and is_map(request) do
    with {:ok, request} <- parse_request(request) do
      create_parsed_request(repo, request)
    end
  end

  @spec activate(module(), WorkPackage.t()) :: {:ok, creation()} | {:error, error()}
  def activate(repo, %WorkPackage{status: "planned"} = work_package) when is_atom(repo) do
    with {:ok, policy} <- Templates.expand(work_package.policy_template || work_package.kind),
         policy = effective_policy(policy, work_package.review_requirement),
         {:ok, acceptance_criteria} <- normalize_acceptance_criteria(work_package.acceptance_criteria),
         {:ok, allowed_file_globs} <- normalize_allowed_file_globs(work_package.allowed_file_globs),
         :ok <- require_acceptance_criteria(policy, acceptance_criteria),
         :ok <- require_scope_guard_constraints(policy, allowed_file_globs),
         :ok <- require_docs_scope(work_package.kind, allowed_file_globs) do
      repo.transaction(fn -> activate_transaction(repo, work_package, policy) end)
      |> case do
        {:ok, creation} -> {:ok, creation}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def activate(_repo, %WorkPackage{}), do: {:error, :invalid_status}

  defp activate_transaction(repo, work_package, policy) do
    with {:ok, activated} <- WorkPackageRepository.update_status(repo, work_package.id, "planned", "ready_for_worker"),
         {:ok, activated} <- WorkPackageRepository.update(repo, activated.id, %{dispatched_at: DateTime.utc_now(:microsecond)}),
         {:ok, _scope_node} <- append_scope_plan_node(repo, activated),
         {:ok, _review_node} <- append_review_plan_node(repo, activated, policy),
         {:ok, minted} <- mint_worker_grant(repo, activated.id, policy),
         {:ok, virtual_files} <- Renderer.render_all(repo, activated.id) do
      %{
        work_package: activated,
        worker_grant: worker_grant_payload(minted),
        virtual_files: virtual_files,
        policy: policy
      }
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  @spec response_payload(creation(), keyword()) :: map()
  def response_payload(%{work_package: work_package, worker_grant: worker_grant, virtual_files: virtual_files, policy: policy}, opts \\ []) do
    worker_bootstrap = Keyword.get(opts, :worker_bootstrap)

    %{
      work_package: work_package_payload(work_package),
      worker_grant: worker_grant_payload_for_response(worker_grant),
      policy: policy_payload(policy),
      virtual_files: virtual_files
    }
    |> maybe_put_worker_bootstrap(worker_bootstrap)
  end

  @spec error_message(term()) :: String.t()
  def error_message({:missing_required_field, field}), do: "Missing required create-work field: #{field}"
  def error_message(:invalid_acceptance_criteria), do: "acceptance_criteria must be a list of nonblank strings"
  def error_message(:invalid_allowed_file_globs), do: "allowed_file_globs must be a list of nonblank strings"
  def error_message(:invalid_kind), do: "kind must be a nonblank string when provided"
  def error_message(:invalid_policy_template), do: "policy_template must be a nonblank string when provided"
  def error_message(:invalid_request), do: "Create-work request must be an object"
  def error_message(:invalid_review_requirement), do: "review_requirement must contain a non-empty type and optional args object"
  def error_message(:sensitive_review_requirement), do: "review_requirement must not contain secrets"
  def error_message(:invalid_work_package_id), do: "id must be a nonblank string when provided"
  def error_message(:missing_acceptance_criteria), do: "acceptance_criteria is required for this work kind"
  def error_message(:missing_allowed_file_globs), do: "allowed_file_globs is required for docs and scope-guard policy templates"
  def error_message(:non_documentation_allowed_file_globs), do: "docs work allowed_file_globs must be documentation-only"
  def error_message(:overbroad_allowed_file_globs), do: "allowed_file_globs cannot contain repo-wide catch-all globs"
  def error_message(:parent_not_supported), do: "Create-work does not accept parent_id"
  def error_message(:policy_template_mismatch), do: "policy_template must select the work kind policy"

  def error_message(:kind_not_dispatchable),
    do: "Create-work supports standard_pr (ordinary PR work), quick_fix, hotfix, docs, investigation, adapter, mcp (MCP server, protocol, tool, or plugin work), skill, and hooks only"

  def error_message(:unknown_policy_template), do: "No policy template exists for requested kind"
  def error_message(%Changeset{} = changeset), do: "Invalid create-work request: #{inspect(changeset.errors)}"
  def error_message(reason), do: "Failed to create work: #{inspect(reason)}"

  defp create_parsed_request(repo, request) do
    repo.transaction(fn ->
      case create_transaction(repo, request) do
        {:ok, creation} -> creation
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  @doc false
  @spec cleanup_created_work_package(module(), String.t()) :: :ok | {:error, term()}
  def cleanup_created_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    repo.transaction(fn ->
      delete_by_work_package_id(repo, AgentRun, work_package_id)
      delete_by_work_package_id(repo, Artifact, work_package_id)
      delete_by_work_package_id(repo, ProgressEvent, work_package_id)
      delete_by_work_package_id(repo, Finding, work_package_id)
      delete_by_work_package_id(repo, PlanNode, work_package_id)
      delete_by_work_package_id(repo, AccessGrant, work_package_id)

      repo.delete_all(from(work_package in WorkPackage, where: work_package.id == ^work_package_id))
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  defp delete_by_work_package_id(repo, schema, work_package_id) do
    repo.delete_all(from(row in schema, where: row.work_package_id == ^work_package_id))
  end

  defp create_transaction(repo, request) do
    policy = Map.fetch!(request, "policy")
    work_package_attrs = Map.drop(request, ["policy"])

    with {:ok, work_package} <- WorkPackageRepository.create(repo, work_package_attrs),
         {:ok, _scope_node} <- append_scope_plan_node(repo, work_package),
         {:ok, _review_node} <- append_review_plan_node(repo, work_package, policy),
         {:ok, minted} <- mint_worker_grant(repo, work_package.id, policy),
         {:ok, virtual_files} <- Renderer.render_all(repo, work_package.id) do
      {:ok,
       %{
         work_package: work_package,
         worker_grant: worker_grant_payload(minted),
         virtual_files: virtual_files,
         policy: policy
       }}
    end
  end

  defp append_scope_plan_node(repo, %WorkPackage{} = work_package) do
    PlanningRepository.append_plan_node(repo, %{
      work_package_id: work_package.id,
      title: initial_scope_title(work_package),
      body: nonblank_or(work_package.engineering_scope, "Use the engineering scope from context.md."),
      status: "pending"
    })
  end

  defp initial_scope_title(%WorkPackage{kind: "investigation"}), do: "Investigate requested scope"
  defp initial_scope_title(%WorkPackage{}), do: "Implement requested scope"

  defp append_review_plan_node(repo, %WorkPackage{} = work_package, policy) do
    PlanningRepository.append_plan_node(repo, %{
      work_package_id: work_package.id,
      title: "Complete acceptance and review gates",
      body: review_plan_body(policy, work_package.review_requirement),
      status: "pending"
    })
  end

  defp review_plan_body(policy, review_requirement) do
    [
      acceptance_plan_line(policy),
      "Required gates:",
      gates_line(policy.required_gates),
      "",
      "Review requirement:",
      review_requirement_line(review_requirement)
    ]
    |> Enum.join("\n")
  end

  defp acceptance_plan_line(%{required_gates: required_gates}) do
    if "package_acceptance" in required_gates do
      "Acceptance criteria:\n- Satisfy the package acceptance criteria in acceptance.md.\n"
    else
      ""
    end
  end

  defp gates_line([]), do: "- None."
  defp gates_line(gates), do: Enum.map_join(gates, "\n", &("- " <> &1))

  defp review_requirement_line(nil), do: "- None."
  defp review_requirement_line(requirement), do: "- " <> Jason.encode!(requirement)

  defp nonblank_or(value, fallback) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: fallback, else: value
  end

  defp nonblank_or(_value, fallback), do: fallback

  defp mint_worker_grant(repo, work_package_id, _policy) do
    AccessGrantService.mint_worker_grant(repo, work_package_id)
  end

  defp worker_grant_payload(%{grant: grant}) do
    %{
      id: grant.id,
      role: grant.grant_role,
      capabilities: grant.capabilities,
      expires_at: timestamp(grant.expires_at)
    }
  end

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(nil), do: nil

  defp worker_grant_payload_for_response(nil), do: nil

  defp worker_grant_payload_for_response(worker_grant) do
    worker_grant
    |> Map.delete(:display_key)
    |> Map.delete("display_key")
    |> Map.delete(:secret)
    |> Map.delete("secret")
    |> redact_worker_grant_verifier_material()
    |> Map.put(:secret_in_response, false)
  end

  defp redact_worker_grant_verifier_material(worker_grant) when is_map(worker_grant) do
    worker_grant
    |> Map.delete(:secret_hash)
    |> Map.delete("secret_hash")
  end

  defp maybe_put_worker_bootstrap(payload, nil), do: payload
  defp maybe_put_worker_bootstrap(payload, bootstrap), do: Map.put(payload, :worker_bootstrap, redacted_worker_bootstrap(bootstrap))

  defp redacted_worker_bootstrap(bootstrap) when is_map(bootstrap) do
    bootstrap
    |> redact_bootstrap_launch_prompt(:launch_prompt)
    |> redact_bootstrap_launch_prompt("launch_prompt")
  end

  defp redact_bootstrap_launch_prompt(bootstrap, key) do
    case Map.fetch(bootstrap, key) do
      {:ok, prompt} when is_binary(prompt) -> Map.put(bootstrap, key, Redactor.redact_text(prompt))
      _result -> bootstrap
    end
  end

  defp work_package_payload(%WorkPackage{} = work_package) do
    %{
      id: work_package.id,
      kind: work_package.kind,
      title: work_package.title,
      repo: work_package.repo,
      base_branch: work_package.base_branch,
      branch_pattern: work_package.branch_pattern,
      product_description: work_package.product_description,
      engineering_scope: work_package.engineering_scope,
      allowed_file_globs: work_package.allowed_file_globs,
      review: work_package.review_requirement,
      policy_template: work_package.policy_template,
      acceptance_criteria: work_package.acceptance_criteria,
      status: work_package.status,
      parent_id: work_package.parent_id,
      owner_id: work_package.owner_id
    }
  end

  defp policy_payload(policy) do
    %{
      template: policy.template,
      constraints: policy.constraints,
      required_gates: policy.required_gates,
      readiness_requirements: policy.readiness_requirements
    }
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp require_dispatchable(attrs) do
    if present?(Map.get(attrs, "parent_id")) do
      {:error, :parent_not_supported}
    else
      {:ok, attrs}
    end
  end

  defp normalize_required_fields(attrs) do
    Enum.reduce_while(@required_fields, {:ok, attrs}, fn field, {:ok, current_attrs} ->
      case normalize_nonblank_string(Map.get(current_attrs, field)) do
        {:ok, value} -> {:cont, {:ok, Map.put(current_attrs, field, value)}}
        {:error, :blank} -> {:halt, {:error, {:missing_required_field, field}}}
      end
    end)
  end

  defp normalize_optional_id(attrs) do
    case Map.fetch(attrs, "id") do
      :error ->
        {:ok, attrs}

      {:ok, id} ->
        case normalize_nonblank_string(id) do
          {:ok, id} -> {:ok, Map.put(attrs, "id", id)}
          {:error, :blank} -> {:error, :invalid_work_package_id}
        end
    end
  end

  defp normalize_kind(attrs, policy_templates) do
    case Map.fetch(attrs, "kind") do
      :error ->
        default_kind(policy_templates)

      {:ok, kind} ->
        case normalize_nonblank_string(kind) do
          {:ok, "phase_child"} -> {:error, :kind_not_dispatchable}
          {:ok, kind} -> ensure_dispatchable_kind(kind)
          {:error, :blank} -> {:error, :invalid_kind}
        end
    end
  end

  defp ensure_dispatchable_kind(kind) do
    if StateMachine.supported_kind?(kind) do
      {:ok, kind}
    else
      {:error, :kind_not_dispatchable}
    end
  end

  defp default_kind([]), do: {:ok, @default_kind}

  defp default_kind(policy_templates) do
    with {:ok, policy_key, policy} <- default_policy_key(policy_templates),
         {:ok, kind} <- Templates.kind(policy_key),
         :ok <- reject_phase_child_policy(policy) do
      {:ok, kind}
    end
  end

  defp default_policy_key(policy_templates) do
    case exact_policy_key(nil, policy_templates) do
      {:ok, policy_key} ->
        with {:ok, policy} <- Templates.expand(policy_key),
             true <- Enum.all?(policy_templates, &Templates.matches?(policy_key, &1)) do
          {:ok, policy_key, policy}
        else
          false -> {:error, :policy_template_mismatch}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        Templates.resolve_key(policy_templates)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp policy_for(kind, []) do
    with {:ok, policy} <- Templates.expand(kind),
         :ok <- reject_phase_child_policy(policy) do
      {:ok, kind, policy}
    else
      {:error, :unknown_policy_template} -> {:error, :unknown_policy_template}
      {:error, reason} -> {:error, reason}
    end
  end

  defp policy_for(kind, policy_templates) do
    with {:ok, policy_key, policy} <- policy_key_for(kind, policy_templates),
         :ok <- reject_phase_child_policy(policy) do
      {:ok, policy_key, policy}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp policy_key_for(kind, policy_templates) do
    case exact_policy_key(kind, policy_templates) do
      {:ok, policy_key} ->
        with {:ok, policy} <- Templates.expand(policy_key),
             true <- Templates.compatible_kind?(kind, policy_key),
             :ok <- reject_exact_policy_alias_mismatch(kind, policy_key, policy, policy_templates),
             true <- Enum.all?(policy_templates, &Templates.matches?(policy_key, &1)) do
          {:ok, policy_key, policy}
        else
          false -> {:error, :policy_template_mismatch}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        with {:ok, policy_key, policy} <- Templates.resolve_key([kind | policy_templates]),
             true <- Templates.compatible_kind?(kind, policy_key) do
          {:ok, policy_key, policy}
        else
          false -> {:error, :policy_template_mismatch}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exact_policy_key(_kind, policy_templates) do
    exact_keys = policy_templates |> Enum.filter(&Templates.key?/1) |> Enum.uniq()

    case exact_keys do
      [] -> :none
      [policy_key] -> {:ok, policy_key}
      _multiple -> exact_policy_key_with_kind_aliases(exact_keys)
    end
  end

  defp exact_policy_key_with_kind_aliases(exact_keys) do
    candidates =
      Enum.filter(exact_keys, fn policy_key ->
        case Templates.kind(policy_key) do
          {:ok, kind} -> Enum.all?(exact_keys -- [policy_key], &(&1 == kind))
          {:error, _reason} -> false
        end
      end)

    case candidates do
      [policy_key] -> {:ok, policy_key}
      _candidates -> {:error, :policy_template_mismatch}
    end
  end

  defp reject_exact_policy_alias_mismatch(kind, policy_key, policy, policy_templates) do
    template_alias = Map.get(policy, :template)

    if policy_key != kind and template_alias != policy_key and template_alias in policy_templates and
         not explicit_policy_with_alias?(policy_templates, policy_key, template_alias) do
      {:error, :policy_template_mismatch}
    else
      :ok
    end
  end

  defp explicit_policy_with_alias?(policy_templates, policy_key, template_alias) do
    with {:ok, %{template: ^template_alias}} <- Templates.expand(policy_key),
         policy_index when is_integer(policy_index) <- Enum.find_index(policy_templates, &(&1 == policy_key)),
         alias_index when is_integer(alias_index) <- Enum.find_index(policy_templates, &(&1 == template_alias)) do
      policy_index < alias_index
    else
      _reason -> false
    end
  end

  defp reject_phase_child_policy(%{template: "phase_child"}), do: {:error, :kind_not_dispatchable}
  defp reject_phase_child_policy(_policy), do: :ok

  defp explicit_policy_templates(attrs) do
    ["policy_template"]
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, templates} ->
      case normalize_policy_template(Map.get(attrs, field)) do
        {:ok, nil} -> {:cont, {:ok, templates}}
        {:ok, template} -> {:cont, {:ok, [template | templates]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, templates} -> {:ok, Enum.reverse(templates)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_policy_template(value) when is_binary(value) do
    case normalize_nonblank_string(value) do
      {:ok, value} -> {:ok, value}
      {:error, :blank} -> {:error, :invalid_policy_template}
    end
  end

  defp normalize_policy_template(nil), do: {:ok, nil}
  defp normalize_policy_template(_value), do: {:error, :invalid_policy_template}

  defp require_acceptance_criteria(%{required_gates: required_gates}, []) do
    if "package_acceptance" in required_gates do
      {:error, :missing_acceptance_criteria}
    else
      :ok
    end
  end

  defp require_acceptance_criteria(_policy, _acceptance_criteria), do: :ok

  defp require_scope_guard_constraints(%{required_gates: required_gates}, allowed_file_globs) do
    if @scope_guard_gate in required_gates do
      cond do
        allowed_file_globs == [] -> {:error, :missing_allowed_file_globs}
        Enum.any?(allowed_file_globs, &ScopeGuard.overbroad_glob?/1) -> {:error, :overbroad_allowed_file_globs}
        true -> :ok
      end
    else
      :ok
    end
  end

  defp require_docs_scope("docs", []), do: {:error, :missing_allowed_file_globs}

  defp require_docs_scope("docs", allowed_file_globs) do
    case ScopeConstraints.validate_docs_allowed_file_globs(allowed_file_globs) do
      :ok -> :ok
      {:error, _errors} -> {:error, :non_documentation_allowed_file_globs}
    end
  end

  defp require_docs_scope(_kind, _allowed_file_globs), do: :ok

  defp normalize_acceptance_criteria(criteria) when is_list(criteria) do
    criteria = Enum.map(criteria, &normalize_acceptance_criterion/1)

    if Enum.all?(criteria, &valid_acceptance_criterion?/1) do
      {:ok, criteria}
    else
      {:error, :invalid_acceptance_criteria}
    end
  end

  defp normalize_acceptance_criteria(nil), do: {:ok, []}
  defp normalize_acceptance_criteria(_criteria), do: {:error, :invalid_acceptance_criteria}

  defp normalize_allowed_file_globs(globs), do: normalize_string_list(globs, :invalid_allowed_file_globs)

  defp normalize_optional_review_requirement(attrs), do: ReviewRequirement.normalize(Map.get(attrs, "review_requirement"))

  defp effective_policy(policy, nil), do: policy

  defp effective_policy(policy, _review_requirement) do
    policy
    |> Map.update!(:required_gates, &Enum.uniq(&1 ++ ["review_complete"]))
    |> Map.update!(:readiness_requirements, &Enum.uniq(&1 ++ ["review_current_head"]))
  end

  defp maybe_put_review_requirement(request, nil), do: request
  defp maybe_put_review_requirement(request, review_requirement), do: Map.put(request, "review_requirement", review_requirement)

  defp normalize_acceptance_criterion(value) when is_binary(value), do: String.trim(value)
  defp normalize_acceptance_criterion(_value), do: :invalid

  defp valid_acceptance_criterion?(value) when is_binary(value), do: value != ""
  defp valid_acceptance_criterion?(_value), do: false

  defp normalize_string_list(nil, _error), do: {:ok, []}

  defp normalize_string_list(values, error) when is_list(values) do
    values = Enum.map(values, &normalize_acceptance_criterion/1)

    if Enum.all?(values, &valid_acceptance_criterion?/1) do
      {:ok, values}
    else
      {:error, error}
    end
  end

  defp normalize_string_list(_values, error), do: {:error, error}

  defp normalize_nonblank_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, :blank}, else: {:ok, value}
  end

  defp normalize_nonblank_string(_value), do: {:error, :blank}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true
end
