defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.MergeReconciler do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Client, DefaultClient, HttpClient, PullRequest}
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{PullRequestArtifact, PullRequestProgress}
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryReconciler

  @operator_actor %{grant_role: "architect", capabilities: ["architect:lifecycle.transition"]}
  @operator_source_tool "operator_sync_prs"

  @type repo :: module()
  @type result :: map()

  @spec reconcile(repo(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(repo, opts \\ []) when is_atom(repo) and is_list(opts) do
    client = Keyword.get(opts, :client, github_client())
    client_opts = Keyword.drop(opts, [:client])

    with :ok <- validate_periodic_auth(client, opts),
         {:ok, work_packages} <- WorkPackageRepository.list(repo) do
      work_packages
      |> Enum.filter(&merge_ready_candidate?/1)
      |> Enum.flat_map(&reconcile_work_package_result(repo, &1, client, client_opts))
      |> summary()
      |> then(&{:ok, &1})
    else
      {:skip, reason} -> {:ok, skipped_summary(reason)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reconcile_work_package(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_work_package(repo, work_package_id, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_list(opts) do
    client = Keyword.get(opts, :client, terminal_github_client())
    client_opts = Keyword.drop(opts, [:client, :pr_payload])
    pr_payload = Keyword.get(opts, :pr_payload)

    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package.id) do
      if terminal_candidate?(work_package) do
        fetch_and_reconcile_terminal(repo, work_package, state.progress_events, pr_payload, client, client_opts)
      else
        {:ok, error_result(work_package, %{}, :not_merge_ready)}
      end
    end
  end

  defp reconcile_work_package_result(repo, work_package, client, client_opts) do
    case reconcile_work_package(repo, work_package, client, client_opts) do
      :ignore -> []
      result -> [result]
    end
  end

  defp reconcile_work_package(repo, %WorkPackage{} = work_package, client, client_opts) do
    with {:ok, state} <- PlanningRepository.get_state(repo, work_package.id),
         {:ok, pr_context} <- current_pr_context(state.progress_events) do
      fetch_and_reconcile(repo, work_package, pr_context, client, client_opts)
    else
      {:error, :missing_attached_pr} -> :ignore
      {:error, reason} -> error_result(work_package, nil, reason)
    end
  end

  defp merge_ready_candidate?(%WorkPackage{status: status, kind: kind}) when status in ["ready_for_merge", "ready_for_human_merge"] do
    kind in StateMachine.dispatchable_kinds()
  end

  defp merge_ready_candidate?(%WorkPackage{}), do: false

  defp terminal_candidate?(%WorkPackage{status: "merged", kind: kind}), do: kind in StateMachine.dispatchable_kinds()
  defp terminal_candidate?(%WorkPackage{} = work_package), do: merge_ready_candidate?(work_package)

  defp fetch_and_reconcile_terminal(repo, %WorkPackage{} = work_package, progress_events, pr_payload, client, client_opts) do
    with {:ok, pr_context} <- terminal_pr_context(progress_events, pr_payload),
         {:ok, metadata} <- Client.fetch_pull_request(client, pr_context.ref, client_opts),
         {:ok, payload} <- PullRequest.metadata(metadata, pr_context.ref, nil) do
      payload = Map.put(payload, "source_tool", "sync_pr")

      case merged_payload_validation(work_package, pr_context, payload) do
        :ok -> reconcile_verified_terminal_merge(repo, work_package, progress_events, payload, metadata)
        {:error, reason, extras} -> {:ok, skipped_result(work_package, payload, reason, extras)}
      end
    else
      {:error, reason} -> {:ok, error_result(work_package, %{}, reason)}
    end
  end

  defp reconcile_verified_terminal_merge(repo, %WorkPackage{status: "merged"} = work_package, progress_events, payload, metadata) do
    with :ok <- validate_strong_merge_evidence(payload),
         :ok <- existing_merge_evidence(progress_events, work_package, payload) do
      result =
        work_package
        |> base_result(payload)
        |> Map.merge(%{
          status: "already_merged",
          reason: "github_pr_merge_already_recorded",
          before_status: "merged",
          after_status: "merged",
          merged_at: Map.get(metadata, "merged_at"),
          merge_commit_sha: Map.get(metadata, "merge_commit_sha")
        })

      repo
      |> DeliveryReconciler.reconcile_work_package(work_package.id, recorded_by: @operator_source_tool)
      |> terminal_delivery_result(result)
    else
      {:error, reason} -> {:ok, error_result(work_package, payload, reason)}
    end
  end

  defp reconcile_verified_terminal_merge(repo, %WorkPackage{} = work_package, _progress_events, payload, metadata) do
    with :ok <- validate_strong_merge_evidence(payload),
         {:ok, _event} <- append_sync_snapshot(repo, work_package, payload),
         :ok <- PullRequestArtifact.upsert(repo, work_package.id, payload, metadata: %{"source_tool" => @operator_source_tool}) do
      repo
      |> reconcile_transition_delivery(work_package, transition_merged(repo, work_package, payload, metadata))
    else
      {:error, reason} -> {:ok, error_result(work_package, payload, reason)}
    end
  end

  defp reconcile_transition_delivery(repo, %WorkPackage{} = work_package, %{status: "merged"} = result) do
    repo
    |> DeliveryReconciler.reconcile_work_package(work_package.id, recorded_by: @operator_source_tool)
    |> terminal_delivery_result(result)
  end

  defp reconcile_transition_delivery(_repo, %WorkPackage{}, result), do: {:ok, result}

  defp terminal_delivery_result({:ok, delivery}, result),
    do: {:ok, Map.put(result, :delivery_reconciliation, delivery)}

  defp terminal_delivery_result({:error, reason}, result) do
    {:ok,
     result
     |> Map.put(:status, "error")
     |> Map.put(:reason, "delivery_reconciliation_failed")
     |> Map.put(:delivery_error, delivery_error_reason(reason))}
  end

  defp delivery_error_reason({:delivery_reconciliation_failed, reason}), do: error_reason(reason)
  defp delivery_error_reason(reason), do: error_reason(reason)

  defp fetch_and_reconcile(repo, %WorkPackage{} = work_package, pr_context, client, client_opts) do
    with {:ok, metadata} <- Client.fetch_pull_request(client, pr_context.ref, client_opts),
         {:ok, payload} <- PullRequest.metadata(metadata, pr_context.ref, nil) do
      payload = Map.put(payload, "source_tool", "sync_pr")

      with {:ok, _event} <- append_sync_snapshot(repo, work_package, payload),
           :ok <-
             PullRequestArtifact.upsert(repo, work_package.id, payload, metadata: %{"source_tool" => @operator_source_tool}) do
        maybe_transition_merged(repo, work_package, pr_context, payload, metadata)
      else
        {:error, reason} -> error_result(work_package, payload, reason)
      end
    else
      {:error, reason} -> error_result(work_package, pr_ref_payload(pr_context.ref), reason)
    end
  end

  defp maybe_transition_merged(repo, %WorkPackage{} = work_package, pr_context, payload, metadata) do
    case merged_payload_validation(work_package, pr_context, payload) do
      :ok ->
        transition_merged(repo, work_package, payload, metadata)

      {:error, "pr_not_merged", _extras} ->
        synced_result(work_package, payload, "pr_not_merged")

      {:error, reason, extras} ->
        skipped_result(work_package, payload, reason, extras)
    end
  end

  defp merged_payload_validation(%WorkPackage{} = work_package, pr_context, payload) do
    cond do
      not PullRequestProgress.merged?(payload) ->
        {:error, "pr_not_merged", []}

      missing_repository?(work_package, payload) ->
        {:error, "missing_repository", []}

      not repository_matches?(work_package, payload) ->
        {:error, "repository_mismatch", expected_repository: work_package.repo, actual_repository: payload["repository"]}

      missing_base_branch?(work_package, payload) ->
        {:error, "missing_base_branch", []}

      not base_branch_matches?(work_package, payload) ->
        {:error, "base_branch_mismatch", expected_base_branch: work_package.base_branch, actual_base_branch: payload["base_branch"]}

      is_nil(pr_context.expected_head_sha) ->
        {:error, "missing_head_evidence", []}

      not PullRequest.head_sha_matches?(payload["head_sha"], pr_context.expected_head_sha) ->
        {:error, "head_mismatch", expected_head_sha: pr_context.expected_head_sha, actual_head_sha: payload["head_sha"]}

      true ->
        :ok
    end
  end

  defp validate_strong_merge_evidence(payload) do
    with merged_at when is_binary(merged_at) <- clean_string(payload["merged_at"]),
         {:ok, _datetime, _offset} <- DateTime.from_iso8601(merged_at),
         merge_commit_sha when is_binary(merge_commit_sha) <- clean_string(payload["merge_commit_sha"]) do
      :ok
    else
      nil -> {:error, :missing_strong_pr_evidence}
      _invalid -> {:error, :invalid_strong_pr_evidence}
    end
  end

  defp transition_merged(repo, %WorkPackage{} = work_package, payload, metadata) do
    with :ok <- StateMachine.validate_transition(work_package, "merged", @operator_actor),
         {:ok, updated} <- transition_merged_transaction(repo, work_package, payload, metadata) do
      work_package
      |> base_result(payload)
      |> Map.merge(%{
        status: "merged",
        reason: "github_pr_merged",
        before_status: work_package.status,
        after_status: updated.status,
        merged_at: Map.get(metadata, "merged_at"),
        merge_commit_sha: Map.get(metadata, "merge_commit_sha")
      })
    else
      {:error, :stale_status} -> skipped_result(work_package, payload, "stale_status")
      {:error, reason} -> error_result(work_package, payload, reason)
    end
  end

  defp transition_merged_transaction(repo, %WorkPackage{} = work_package, payload, metadata) do
    repo
    |> transaction_with_rollback(fn -> persist_merged_transition(repo, work_package, payload, metadata) end)
    |> normalize_transaction_result()
    |> DashboardPubSub.broadcast_changed_on_success()
  end

  defp transaction_with_rollback(repo, fun) do
    repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp persist_merged_transition(repo, %WorkPackage{} = work_package, payload, metadata) do
    with {:ok, updated} <- WorkPackageRepository.update_status(repo, work_package.id, work_package.status, "merged"),
         {:ok, _event} <- append_merge_evidence(repo, work_package, updated, payload, metadata) do
      {:ok, updated}
    end
  end

  defp append_sync_snapshot(repo, %WorkPackage{} = work_package, payload) do
    PlanningRepository.append_progress_event(repo, %{
      "work_package_id" => work_package.id,
      "summary" => "GitHub PR synced by local operator",
      "status" => "pr_synced",
      "idempotency_key" => "operator_sync_pr:#{work_package.id}:#{metadata_idempotency_key(payload)}",
      "payload" => Map.put(payload, "operator_source_tool", @operator_source_tool)
    })
  end

  defp append_merge_evidence(repo, %WorkPackage{} = before_package, %WorkPackage{} = after_package, payload, metadata) do
    attrs = %{
      "work_package_id" => before_package.id,
      "summary" => "GitHub PR merge reconciled",
      "body" => "Local operator reconciled the WorkPackage status from fetched GitHub PR merge state.",
      "status" => "github_pr_merged",
      "idempotency_key" => "operator_github_merge:#{before_package.id}:#{payload["head_sha"] || payload["url"]}",
      "payload" => %{
        "type" => "github_pr_merge_reconciliation",
        "source_tool" => @operator_source_tool,
        "url" => payload["url"],
        "repository" => payload["repository"],
        "number" => payload["number"],
        "head_sha" => payload["head_sha"],
        "before_status" => before_package.status,
        "after_status" => after_package.status,
        "merged" => true,
        "merged_at" => Map.get(metadata, "merged_at"),
        "merge_commit_sha" => Map.get(metadata, "merge_commit_sha")
      }
    }

    with {:ok, event} <- PlanningRepository.append_progress_event(repo, attrs),
         :ok <- validate_merge_evidence(event, after_package, payload) do
      {:ok, event}
    end
  end

  defp existing_merge_evidence(progress_events, %WorkPackage{} = work_package, payload) do
    idempotency_key = "operator_github_merge:#{work_package.id}:#{payload["head_sha"] || payload["url"]}"

    case Enum.find(progress_events, &(&1.idempotency_key == idempotency_key)) do
      %ProgressEvent{} = event -> validate_merge_evidence(event, work_package, payload)
      nil -> {:error, :missing_merge_evidence}
    end
  end

  defp validate_merge_evidence(
         %ProgressEvent{status: "github_pr_merged", payload: %{} = event_payload},
         %WorkPackage{} = after_package,
         payload
       ) do
    event_payload = stringify_keys(event_payload)

    cond do
      event_payload["source_tool"] != @operator_source_tool -> {:error, :merge_evidence_conflict}
      event_payload["after_status"] != after_package.status -> {:error, :merge_evidence_conflict}
      clean_head_sha(event_payload["head_sha"]) != clean_head_sha(payload["head_sha"]) -> {:error, :merge_evidence_conflict}
      event_payload["repository"] != payload["repository"] -> {:error, :merge_evidence_conflict}
      event_payload["number"] != payload["number"] -> {:error, :merge_evidence_conflict}
      clean_string(event_payload["merged_at"]) != clean_string(payload["merged_at"]) -> {:error, :merge_evidence_conflict}
      clean_string(event_payload["merge_commit_sha"]) != clean_string(payload["merge_commit_sha"]) -> {:error, :merge_evidence_conflict}
      true -> :ok
    end
  end

  defp validate_merge_evidence(%ProgressEvent{}, %WorkPackage{}, _payload), do: {:error, :merge_evidence_conflict}

  defp current_pr_context(progress_events) do
    with {:ok, %{ref: ref}} <- PullRequestProgress.current_pr_state(progress_events, ["attach_pr"]) do
      {:ok,
       %{
         ref: ref,
         expected_head_sha: PullRequestProgress.expected_head_sha(progress_events, ref)
       }}
    end
  end

  defp terminal_pr_context(progress_events, pr_payload) do
    case current_pr_context(progress_events) do
      {:error, :missing_attached_pr} -> repaired_pr_context(progress_events, pr_payload)
      result -> result
    end
  end

  defp repaired_pr_context(progress_events, %{"attachment_repair" => true} = payload) do
    with {:ok, ref} <- PullRequest.parse(payload, nil) do
      {:ok, %{ref: ref, expected_head_sha: PullRequestProgress.expected_head_sha(progress_events, ref)}}
    end
  end

  defp repaired_pr_context(_progress_events, _payload), do: {:error, :missing_attached_pr}

  defp synced_result(%WorkPackage{} = work_package, payload, reason) do
    work_package
    |> base_result(payload)
    |> Map.merge(%{status: "synced", reason: reason, before_status: work_package.status, after_status: work_package.status})
  end

  defp skipped_result(%WorkPackage{} = work_package, payload, reason, extras \\ []) do
    work_package
    |> base_result(payload)
    |> Map.merge(%{status: "skipped", reason: reason, before_status: work_package.status, after_status: work_package.status})
    |> Map.merge(Map.new(extras))
  end

  defp error_result(%WorkPackage{} = work_package, payload, reason) do
    work_package
    |> base_result(payload || %{})
    |> Map.merge(%{
      status: "error",
      reason: error_reason(reason),
      before_status: work_package.status,
      after_status: work_package.status
    })
  end

  defp base_result(%WorkPackage{} = work_package, payload) do
    %{
      work_package_id: work_package.id,
      work_package_status: work_package.status,
      kind: work_package.kind,
      pr_url: payload["url"],
      repository: payload["repository"],
      number: payload["number"],
      head_sha: payload["head_sha"]
    }
  end

  defp summary(results) do
    %{
      total_count: length(results),
      synced_count: Enum.count(results, &(&1.status in ["synced", "skipped", "merged"])),
      merged_count: Enum.count(results, &(&1.status == "merged")),
      skipped_count: Enum.count(results, &(&1.status == "skipped")),
      error_count: Enum.count(results, &(&1.status == "error")),
      results: results
    }
  end

  defp skipped_summary(reason) do
    %{
      total_count: 0,
      synced_count: 0,
      merged_count: 0,
      skipped_count: 0,
      error_count: 0,
      reason: reason,
      results: []
    }
  end

  defp pr_ref_payload(ref) do
    %{
      "url" => ref.url,
      "repository" => ref.repository,
      "number" => ref.number
    }
  end

  defp metadata_idempotency_key(payload) do
    "operator:" <> Base.url_encode64(:erlang.term_to_binary(payload), padding: false)
  end

  defp error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason({reason, status}) when is_atom(reason) and is_integer(status), do: "#{reason}:#{status}"
  defp error_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason(reason), do: inspect(reason)

  defp stringify_keys(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp validate_periodic_auth(client, opts) do
    if Keyword.get(opts, :require_authenticated_client?, false) do
      validate_authenticated_client(client, opts)
    else
      :ok
    end
  end

  defp validate_authenticated_client(client, opts) do
    Code.ensure_loaded?(client)

    cond do
      function_exported?(client, :auth_status, 1) ->
        case client.auth_status(opts) do
          :ok -> :ok
          {:error, reason} -> {:skip, periodic_auth_skip_reason(reason)}
        end

      function_exported?(client, :authenticated?, 0) ->
        if client.authenticated?(), do: :ok, else: {:skip, periodic_auth_skip_reason(:github_token_required)}

      true ->
        {:skip, periodic_auth_skip_reason(:authenticated_client_required)}
    end
  end

  defp periodic_auth_skip_reason(:github_token_required), do: "github_token_required_for_periodic_sync"
  defp periodic_auth_skip_reason(:gh_unavailable), do: "gh_cli_unavailable_for_periodic_sync"
  defp periodic_auth_skip_reason(:gh_unauthorized), do: "gh_cli_auth_required_for_periodic_sync"
  defp periodic_auth_skip_reason(:github_cli_or_token_required), do: "github_cli_or_token_required_for_periodic_sync"
  defp periodic_auth_skip_reason(:authenticated_client_required), do: "authenticated_client_required_for_periodic_sync"
  defp periodic_auth_skip_reason(reason) when is_atom(reason), do: "#{reason}_for_periodic_sync"

  defp missing_base_branch?(%WorkPackage{base_branch: package_base_branch}, payload) do
    is_nil(clean_branch(package_base_branch)) or is_nil(clean_branch(payload["base_branch"]))
  end

  defp base_branch_matches?(%WorkPackage{base_branch: package_base_branch}, payload) do
    clean_branch(package_base_branch) == clean_branch(payload["base_branch"])
  end

  defp clean_head_sha(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_head_sha(_value), do: nil

  defp clean_branch(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_branch(_value), do: nil

  defp github_client do
    Application.get_env(:symphony_elixir, :sympp_github_client, HttpClient)
  end

  defp terminal_github_client do
    Application.get_env(:symphony_elixir, :sympp_github_client, DefaultClient)
  end

  defp missing_repository?(%WorkPackage{repo: package_repo}, payload) do
    is_nil(clean_repository(package_repo)) or is_nil(clean_repository(payload["repository"]))
  end

  defp repository_matches?(%WorkPackage{repo: package_repo}, payload) do
    clean_repository(package_repo) == clean_repository(payload["repository"])
  end

  defp clean_repository(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if value == "", do: nil, else: value
  end

  defp clean_repository(_value), do: nil

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil
end
