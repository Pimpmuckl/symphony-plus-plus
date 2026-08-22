defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.Policy do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target
  alias SymphonyElixir.SymphonyPlusPlus.BaseBranch
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity

  @read_actions [
    :work_request_read,
    :work_package_read,
    :task_plan_read,
    :comment_list,
    :guidance_request_read,
    :delivery_board_read,
    :dashboard_read
  ]

  @worker_package_actions [
    :work_package_read,
    :work_package_update,
    :task_plan_read,
    :task_plan_update,
    :progress_append,
    :finding_append,
    :review_evidence_append,
    :blocker_report,
    :blocker_resolve,
    :blocker_unblock,
    :comment_add,
    :comment_list,
    :comment_resolve,
    :guidance_request_create,
    :guidance_request_read
  ]

  @work_package_actions [
    :work_package_update,
    :work_package_approve,
    :work_package_skip,
    :work_package_dispatch
  ]

  @architect_work_request_actions [
    :work_request_read,
    :work_request_update,
    :question_create,
    :question_answer,
    :question_close,
    :decision_record,
    :work_package_create,
    :work_package_update,
    :work_package_approve,
    :work_package_skip,
    :work_package_dispatch,
    :work_package_read,
    :work_package_repair_state,
    :task_plan_read,
    :task_plan_update,
    :progress_append,
    :finding_append,
    :review_evidence_append,
    :blocker_report,
    :blocker_resolve,
    :blocker_unblock,
    :comment_add,
    :comment_list,
    :comment_resolve,
    :external_comment_add,
    :guidance_request_create,
    :guidance_request_read,
    :guidance_request_answer,
    :guidance_request_escalate,
    :delivery_board_read,
    :delivery_reconcile_dry_run,
    :delivery_reconcile_apply,
    :delivery_closeout_record
  ]

  @operator_actions @architect_work_request_actions ++
                      [
                        :dashboard_read,
                        :dangerous_override,
                        :dangerous_rekey,
                        :dangerous_delete,
                        :dangerous_raw_repair
                      ]

  @known_actions Enum.uniq(@operator_actions ++ @worker_package_actions)
  @architect_actions Enum.uniq(@architect_work_request_actions ++ @read_actions)
  @dangerous_actions [:dangerous_override, :dangerous_rekey, :dangerous_delete, :dangerous_raw_repair]
  @operator_roles [:human_operator, :operator]

  @spec actions() :: [atom()]
  def actions, do: @known_actions

  @spec decide(Actor.t(), atom(), Target.t(), keyword()) :: Decision.t()
  def decide(%Actor{} = actor, action, %Target{} = target, opts \\ []) when is_atom(action) do
    cond do
      lifecycle_denial = Keyword.get(opts, :lifecycle_denial) ->
        Decision.lifecycle_denied(actor, action, target, lifecycle_denial)

      not Target.resolved?(target) ->
        Decision.precondition_denied(actor, action, target, target_resolution_reason(target))

      action not in @known_actions ->
        Decision.authorization_denied(actor, action, target, :unknown_action)

      true ->
        decide_resolved(actor, action, target)
    end
  end

  defp decide_resolved(%Actor{role: role} = actor, action, %Target{} = target) when role in @operator_roles do
    allow_with_scope(actor, action, target, [:ledger],
      audit: operator_audit(action, :operator),
      denied_reason: :operator_ledger_scope_required
    )
  end

  defp decide_resolved(%Actor{role: :architect} = actor, action, %Target{} = target) when action in @architect_actions do
    case required_architect_capability(actor, action) do
      :ok ->
        allow_with_scope(actor, action, target, architect_scope_types(action), legacy_reason: "outside_session_scope")

      {:error, capability} ->
        Decision.authorization_denied(actor, action, target, :insufficient_capability,
          legacy_reason: "insufficient_capability",
          requirements: [%{"capability" => capability}]
        )
    end
  end

  defp decide_resolved(%Actor{role: :worker} = actor, action, %Target{} = target) when action in @worker_package_actions do
    allow_with_scope(actor, action, target, [:work_package], legacy_reason: "outside_session_scope")
  end

  defp decide_resolved(%Actor{} = actor, action, %Target{} = target) when action in @dangerous_actions do
    if explicit_human_granted_dangerous_authority?(actor) do
      allow_with_scope(actor, action, target, [:ledger],
        audit: operator_audit(action, :explicit_human_grant),
        denied_reason: :human_granted_ledger_scope_required
      )
    else
      Decision.authorization_denied(actor, action, target, :dangerous_action_requires_operator)
    end
  end

  defp decide_resolved(%Actor{} = actor, action, %Target{} = target) do
    Decision.authorization_denied(actor, action, target, :insufficient_role)
  end

  defp architect_scope_types(action) when action in @read_actions, do: [:work_request, :work_package, :repo, :phase]
  defp architect_scope_types(:external_comment_add), do: [:work_request, :repo, :phase]
  defp architect_scope_types(action) when action in @work_package_actions, do: [:work_request, :work_package]
  defp architect_scope_types(action) when action in @worker_package_actions, do: [:work_request, :work_package]
  defp architect_scope_types(_action), do: [:work_request]

  defp required_architect_capability(%Actor{capabilities: capabilities}, action) do
    capability = architect_capability(action)

    if capability in capabilities do
      :ok
    else
      {:error, capability}
    end
  end

  defp architect_capability(:work_package_dispatch), do: "dispatch:work_request"
  defp architect_capability(:delivery_reconcile_dry_run), do: "read:work_request"
  defp architect_capability(:guidance_request_read), do: "read:guidance_request"
  defp architect_capability(action) when action in [:guidance_request_answer, :guidance_request_escalate], do: "write:guidance_request"
  defp architect_capability(action) when action in @read_actions, do: "read:work_request"
  defp architect_capability(_action), do: "write:work_request"

  defp allow_with_scope(%Actor{} = actor, action, %Target{} = target, allowed_scope_types, opts) do
    audit = Keyword.get(opts, :audit, %{})
    denied_reason = Keyword.get(opts, :denied_reason, :scope_mismatch)
    legacy_reason = Keyword.get(opts, :legacy_reason)

    case matching_scope(actor, target, allowed_scope_types) do
      %Scope{} = scope ->
        Decision.allow(actor, action, target, matched_scope: scope, audit: audit)

      nil ->
        Decision.authorization_denied(actor, action, target, denied_reason, legacy_reason: legacy_reason)
    end
  end

  defp matching_scope(%Actor{scopes: scopes}, %Target{} = target, allowed_scope_types) do
    Enum.find(scopes, fn
      %Scope{type: type} = scope -> type in allowed_scope_types and scope_matches_target?(scope, target)
    end)
  end

  defp scope_matches_target?(%Scope{type: :ledger}, %Target{}), do: true

  defp scope_matches_target?(%Scope{type: :work_request, id: scope_id}, %Target{} = target) when is_binary(scope_id) do
    target.work_request_id == scope_id or (target.type == :work_request and target.id == scope_id)
  end

  defp scope_matches_target?(%Scope{type: :work_package, id: scope_id}, %Target{} = target) when is_binary(scope_id) do
    target.work_package_id == scope_id or (target.type == :work_package and target.id == scope_id)
  end

  defp scope_matches_target?(%Scope{type: :repo, repo: repo, base_branch: base_branch}, %Target{} = target) when is_binary(repo) do
    repo_scope_matches_target?(repo, base_branch, target)
  end

  defp scope_matches_target?(%Scope{type: :phase, id: scope_id, repo: repo, base_branch: base_branch}, %Target{} = target)
       when is_binary(scope_id) and is_binary(repo) and is_binary(base_branch) do
    target.phase_id == scope_id and target.repo == repo and BaseBranch.equivalent?(target.base_branch, base_branch)
  end

  defp scope_matches_target?(%Scope{}, %Target{}), do: false

  defp repo_scope_matches_target?(repo, base_branch, %Target{} = target) do
    trusted_remotes = target.metadata |> Map.get(:repo_scope_trusted_remotes, []) |> List.wrap()

    target_primary_repo_scope_matches?(repo, base_branch, target, trusted_remotes) or
      Enum.any?(target.repo_scopes, &repo_scope_matches?(repo, base_branch, &1, trusted_remotes))
  end

  defp target_primary_repo_scope_matches?(repo, base_branch, %Target{} = target, trusted_remotes) do
    repo_scope_name_matches?(repo, target.repo, trusted_remotes) and
      (is_nil(base_branch) or BaseBranch.equivalent?(target.base_branch, base_branch))
  end

  defp repo_scope_matches?(repo, base_branch, %{repo: scope_repo, base_branch: scope_base_branch}, trusted_remotes) do
    repo_scope_name_matches?(repo, scope_repo, trusted_remotes) and
      (is_nil(base_branch) or BaseBranch.equivalent?(scope_base_branch, base_branch))
  end

  defp repo_scope_matches?(_repo, _base_branch, _scope, _trusted_remotes), do: false

  defp repo_scope_name_matches?(repo, repo, _trusted_remotes) when is_binary(repo), do: true

  defp repo_scope_name_matches?(expected_repo, actual_repo, trusted_remotes)
       when is_binary(expected_repo) and is_binary(actual_repo) do
    RepoIdentity.scope_match?(expected_repo, actual_repo, trusted_remotes: trusted_remotes)
  end

  defp repo_scope_name_matches?(_expected_repo, _actual_repo, _trusted_remotes), do: false

  defp target_resolution_reason(%Target{resolution: :not_found}), do: :target_not_found
  defp target_resolution_reason(%Target{resolution: :ambiguous}), do: :target_ambiguous
  defp target_resolution_reason(%Target{resolution: :runtime_lease_conflict}), do: :runtime_lease_conflict

  defp explicit_human_granted_dangerous_authority?(%Actor{scopes: scopes}) do
    Enum.any?(scopes, fn
      %Scope{type: :ledger, metadata: metadata} -> truthy_metadata?(metadata, :human_granted)
      %Scope{} -> false
    end)
  end

  defp truthy_metadata?(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) == true or Map.get(metadata, Atom.to_string(key)) == true
  end

  defp truthy_metadata?(_metadata, _key), do: false

  defp operator_audit(action, authority) when action in @dangerous_actions do
    %{dangerous_action: true, authority: Atom.to_string(authority)}
  end

  defp operator_audit(_action, _authority), do: %{}
end
