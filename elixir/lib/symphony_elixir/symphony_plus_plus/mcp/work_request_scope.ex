defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestScope do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.ActorResolver
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Policy
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.MCP.WorktreeScope
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type repo :: module()
  @type filters :: map()
  @type scope_payload :: map()
  @type authorization_result :: :ok | {:error, term()}

  @spec scoped_work_request_filters(repo(), term(), keyword()) :: term()
  def scoped_work_request_filters(repo, %Session{} = session, opts \\ []) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, filters} <- work_request_filters_for_architect_grant(repo, session, grant),
         {:ok, scope} <- work_request_scope_payload(filters),
         {:ok, scope} <- maybe_put_handoff_phase_scope(repo, scope, grant, opts) do
      {:ok, work_request_filters_from_scope(scope), scope}
    else
      {:error, :forbidden} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp work_request_filters_for_architect_grant(repo, %Session{} = session, %AccessGrant{} = grant) do
    case frozen_work_request_filters_for_architect_grant(repo, session, grant) do
      {:ok, filters} ->
        {:ok, filters}

      {:error, reason} = error when reason in [:forbidden, :phase_scope_not_available] ->
        if missing_frozen_work_request_scope?(grant) do
          legacy_handoff_work_request_filters(repo, session, grant)
        else
          error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp frozen_work_request_filters_for_architect_grant(repo, %Session{} = session, %AccessGrant{} = grant) do
    with :ok <- require_work_request_anchor_scope(repo, session, grant) do
      Dashboard.phase_board_filters_for_grant(grant)
    end
  end

  defp legacy_handoff_work_request_filters(repo, %Session{} = session, %AccessGrant{} = grant) do
    with {:ok, true} <- ArchitectHandoff.handoff_phase_grant?(repo, grant),
         {:ok, anchor} <- architect_anchor_work_package(repo, session),
         true <- grant.work_package_id == anchor.id,
         true <- grant.phase_id == anchor.phase_id,
         {:ok, work_request} <- legacy_handoff_work_request(repo, grant, anchor),
         {:ok, repo_name} <- required_scope_value(work_request.repo),
         {:ok, base_branch} <- required_scope_value(work_request.base_branch) do
      {:ok, repo: repo_name, base_branch: base_branch}
    else
      false -> {:error, :phase_scope_not_available}
      {:ok, false} -> {:error, :phase_scope_not_available}
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_handoff_work_request(repo, %AccessGrant{} = grant, %WorkPackage{} = anchor) do
    with {:ok, repo_name} <- required_scope_value(anchor.repo),
         {:ok, base_branch} <- required_scope_value(anchor.base_branch),
         {:ok, work_requests} <- WorkRequestRepository.list(repo, %{"repo" => repo_name, "base_branch" => base_branch}) do
      case Enum.find(work_requests, &legacy_handoff_work_request?(&1, grant, anchor)) do
        %WorkRequest{} = work_request -> {:ok, work_request}
        nil -> {:error, :phase_scope_not_available}
      end
    end
  end

  defp legacy_handoff_work_request?(%WorkRequest{} = work_request, %AccessGrant{} = grant, %WorkPackage{} = anchor) do
    ArchitectHandoff.eligible_status?(work_request.status) and
      ArchitectHandoff.eligible_scope?(work_request) and
      grant.work_package_id == anchor.id and
      grant.phase_id == anchor.phase_id and
      ArchitectHandoff.anchor_id_for_work_request(work_request) == anchor.id and
      ArchitectHandoff.phase_id_for_work_request(work_request) == anchor.phase_id
  end

  @spec scoped_guidance_request_filters(repo(), term()) :: term()
  def scoped_guidance_request_filters(repo, %Session{} = session) do
    with {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         {:ok, phase_id} <- architect_phase_scope(repo, session) do
      scope = Map.put(scope, "phase_id", phase_id)

      filters =
        filters
        |> Map.put("phase_id", phase_id)
        |> maybe_put_work_request_guidance_package_ids(repo)

      {:ok, filters, scope}
    end
  end

  defp maybe_put_work_request_guidance_package_ids(%{"repo" => repo_name, "base_branch" => base_branch, "phase_id" => phase_id} = filters, repo) do
    work_package_ids =
      repo.all(
        from(work_package in WorkPackage,
          join: work_request in WorkRequest,
          on: work_request.id == work_package.work_request_id,
          where: work_request.base_branch == ^base_branch,
          where: not is_nil(work_package.id),
          select: {work_request, work_package.id}
        )
      )
      |> Enum.filter(fn {work_request, _work_package_id} ->
        ArchitectHandoff.phase_id_for_work_request(work_request) == phase_id and
          repo_scope_name_matches?(repo_name, work_request.repo, [])
      end)
      |> Enum.map(fn {_work_request, work_package_id} -> work_package_id end)
      |> Enum.uniq()

    case work_package_ids do
      [] -> filters
      ids -> Map.put(filters, "work_package_ids", ids)
    end
  end

  defp maybe_put_work_request_guidance_package_ids(filters, _repo), do: filters

  defp require_work_request_anchor_scope(repo, %Session{} = session, %AccessGrant{} = grant) do
    if architect_explicit_phase_grant?(grant) do
      require_architect_phase_anchor(repo, session, grant.phase_id)
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp missing_frozen_work_request_scope?(%AccessGrant{} = grant) do
    not filled_string?(grant.scope_repo) and not filled_string?(grant.scope_base_branch)
  end

  defp required_scope_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :phase_scope_not_available}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_scope_value(_value), do: {:error, :phase_scope_not_available}

  defp work_request_scope_payload(filters) when is_list(filters) do
    repo = Keyword.get(filters, :repo)
    base_branch = Keyword.get(filters, :base_branch)

    if filled_string?(repo) and filled_string?(base_branch) do
      {:ok, %{"repo" => String.trim(repo), "base_branch" => String.trim(base_branch)}}
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp work_request_filters_from_scope(%{"repo" => repo, "base_branch" => base_branch, "phase_id" => phase_id}) do
    %{"repo" => repo, "base_branch" => base_branch, "phase_id" => phase_id}
  end

  defp work_request_filters_from_scope(%{"repo" => repo, "base_branch" => base_branch}) do
    %{"repo" => repo, "base_branch" => base_branch}
  end

  defp maybe_put_handoff_phase_scope(repo, scope, %AccessGrant{} = grant) do
    case ArchitectHandoff.handoff_phase_grant?(repo, grant) do
      {:ok, true} -> {:ok, Map.put(scope, "phase_id", grant.phase_id)}
      {:ok, false} -> {:ok, scope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_handoff_phase_scope(repo, scope, %AccessGrant{} = grant, opts) do
    if Keyword.get(opts, :handoff_phase_scope?, true) do
      maybe_put_handoff_phase_scope(repo, scope, grant)
    else
      {:ok, scope}
    end
  end

  @spec work_request_list_filters(filters(), String.t() | nil) :: filters()
  def work_request_list_filters(filters, nil), do: filters
  def work_request_list_filters(filters, status), do: Map.put(filters, "status", status)

  @spec work_request_repository_filters(filters()) :: filters()
  def work_request_repository_filters(filters) do
    Map.take(filters, ["status"])
  end

  @spec filter_scoped_work_requests(repo(), [term()], filters(), term(), keyword()) :: term()
  def filter_scoped_work_requests(repo, work_requests, filters, %Session{} = session, opts) do
    work_request_ids = Enum.map(work_requests, & &1.id)

    with {:ok, repo_scopes_by_work_request_id} <-
           WorkRequestRepository.list_repo_scopes_by_work_request(repo, work_request_ids) do
      opts = Keyword.put(opts, :repo_scopes_by_work_request_id, repo_scopes_by_work_request_id)
      reduce_scoped_work_requests(repo, work_requests, filters, session, opts)
    end
  end

  defp reduce_scoped_work_requests(repo, work_requests, filters, session, opts) do
    Enum.reduce_while(work_requests, {:ok, []}, fn work_request, {:ok, scoped} ->
      case work_request_matches_filters?(repo, work_request, filters, opts) do
        {:ok, true} -> filter_policy_allowed_work_request(repo, session, work_request, scoped, opts)
        {:ok, false} -> {:cont, {:ok, scoped}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, scoped} -> {:ok, Enum.reverse(scoped)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp filter_policy_allowed_work_request(repo, %Session{} = session, %WorkRequest{} = work_request, scoped, opts) do
    case authorize_work_request_policy(repo, session, :work_request_read, work_request, "list_work_requests", opts) do
      :ok ->
        {:cont, {:ok, [work_request | scoped]}}

      {:error, {:authorization_policy_denied, _code, _message, %{"reason_code" => "scope_mismatch"}}} ->
        {:cont, {:ok, scoped}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  @spec maybe_put_work_request_guidance_filter(repo(), filters(), String.t() | nil) :: term()
  def maybe_put_work_request_guidance_filter(_repo, filters, nil), do: {:ok, filters}

  def maybe_put_work_request_guidance_filter(repo, filters, work_request_id) when is_binary(work_request_id) do
    with {:ok, _work_request} <- scoped_work_request(repo, work_request_id, filters, repo_scopes?: true),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(repo, work_request_id) do
      work_package_ids =
        work_packages
        |> Enum.map(& &1.id)
        |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
        |> Enum.uniq()

      {:ok, Map.put(filters, "filter_work_package_ids", work_package_ids)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec maybe_require_guidance_work_request_filter_scope(repo(), term(), String.t() | nil) :: authorization_result()
  def maybe_require_guidance_work_request_filter_scope(_repo, %Session{}, nil), do: :ok

  def maybe_require_guidance_work_request_filter_scope(repo, %Session{} = session, work_request_id) when is_binary(work_request_id) do
    authorize_work_request_tool_policy_preauthorization(repo, session, "read_work_request")
  end

  @spec authorized_work_request_scope(repo(), term(), term(), atom(), String.t(), keyword()) :: term()
  def authorized_work_request_scope(repo, %Session{} = session, work_request_id, action, tool, opts \\ []) do
    if architect_session?(session) do
      authorized_architect_work_request_scope(repo, session, work_request_id, action, tool, opts)
    else
      authorized_actor_work_request_scope(repo, session, work_request_id, action, tool)
    end
  end

  defp authorized_architect_work_request_scope(repo, %Session{} = session, work_request_id, action, tool, opts) do
    repo_scope_opts = if repo_scope_read_action?(action), do: opts, else: []

    with {:ok, filters, scope} <-
           scoped_work_request_filters(repo, session, handoff_phase_scope?: not repo_scope_read_action?(action)),
         {:ok, work_request} <-
           scoped_work_request(
             repo,
             work_request_id,
             filters,
             Keyword.put(repo_scope_opts, :repo_scopes?, repo_scope_read_action?(action))
           ),
         policy_session = read_scoped_work_request_session(repo, session, scope, action),
         :ok <-
           authorize_work_request_policy(repo, policy_session, action, work_request, tool, repo_scope_opts)
           |> mask_architect_scope_denial() do
      {:ok, work_request, filters, scope}
    end
  end

  defp authorized_actor_work_request_scope(repo, %Session{} = session, work_request_id, action, tool) do
    with {:ok, work_request} <- WorkRequestService.get(repo, work_request_id),
         :ok <- authorize_work_request_policy(repo, session, action, work_request, tool),
         {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         :ok <-
           require_work_request_scope(
             repo,
             work_request,
             filters,
             repo_scopes?: repo_scope_read_action?(action)
           ) do
      {:ok, work_request, filters, scope}
    end
  end

  @spec authorized_work_package_scope(repo(), term(), term(), term(), atom(), String.t()) :: term()
  def authorized_work_package_scope(repo, %Session{} = session, work_request_id, work_package_id, action, tool) do
    if architect_session?(session) do
      authorized_architect_work_package_scope(repo, session, work_request_id, work_package_id, action, tool)
    else
      authorized_actor_work_package_scope(repo, session, work_request_id, work_package_id, action, tool)
    end
  end

  defp authorized_architect_work_package_scope(repo, %Session{} = session, work_request_id, work_package_id, action, tool) do
    with {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         {:ok, work_request} <- scoped_work_request(repo, work_request_id, filters),
         {:ok, work_package} <- scoped_work_request_work_package(repo, work_request_id, work_package_id),
         :ok <-
           authorize_work_package_policy(session, action, work_request, work_package, tool)
           |> mask_architect_scope_denial() do
      {:ok, work_request, work_package, filters, scope}
    end
  end

  defp authorized_actor_work_package_scope(repo, %Session{} = session, work_request_id, work_package_id, action, tool) do
    with {:ok, work_request} <- WorkRequestService.get(repo, work_request_id),
         {:ok, work_package} <- WorkRequestService.get_work_package(repo, work_request_id, work_package_id),
         :ok <- authorize_work_package_policy(session, action, work_request, work_package, tool),
         {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         :ok <- require_work_request_scope(repo, work_request, filters) do
      {:ok, work_request, work_package, filters, scope}
    end
  end

  @spec authorize_work_request_list_policy(term(), scope_payload(), String.t(), keyword()) :: authorization_result()
  def authorize_work_request_list_policy(%Session{} = session, scope, tool, opts) do
    case authorize_work_request_repo_policy(session, :work_request_read, scope, tool, opts) do
      :ok ->
        :ok

      {:error, {:authorization_policy_denied, _code, _message, %{"reason_code" => "scope_mismatch"}}} = error ->
        if work_request_scoped_session?(session), do: :ok, else: error

      {:error, _reason} = error ->
        error
    end
  end

  @spec authorize_work_request_tool_policy_preauthorization(repo(), term(), String.t()) :: authorization_result()
  def authorize_work_request_tool_policy_preauthorization(repo, %Session{} = session, tool) do
    target = Target.repo("policy-preauthorization", nil)

    case authorize_policy(session, work_request_policy_action(tool), target, tool) do
      :ok ->
        :ok

      {:error, {:authorization_policy_denied, _code, _message, %{"reason_code" => "scope_mismatch"}}} ->
        with {:ok, _filters, _scope} <- scoped_work_request_filters(repo, session), do: :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp work_request_policy_action("list_work_requests"), do: :work_request_read
  defp work_request_policy_action("read_work_request"), do: :work_request_read
  defp work_request_policy_action("read_plan"), do: :work_request_read
  defp work_request_policy_action("read_delivery_board"), do: :delivery_board_read
  defp work_request_policy_action("set_work_request_status"), do: :work_request_update
  defp work_request_policy_action("ask_question"), do: :question_create
  defp work_request_policy_action("answer_question"), do: :question_answer
  defp work_request_policy_action("answer_question_and_record_decision"), do: :question_answer
  defp work_request_policy_action("close_question"), do: :question_close
  defp work_request_policy_action("record_decision"), do: :decision_record
  defp work_request_policy_action("slice_work_request"), do: :work_package_create
  defp work_request_policy_action("update_work_package"), do: :work_package_update
  defp work_request_policy_action("upsert_plan_node"), do: :work_request_update
  defp work_request_policy_action("move_plan_node"), do: :work_request_update
  defp work_request_policy_action("set_plan_node_completion"), do: :work_request_update
  defp work_request_policy_action("skip_work_package"), do: :work_package_skip
  defp work_request_policy_action("dispatch_work_package"), do: :work_package_dispatch

  defp repo_scope_read_action?(action), do: action in [:work_request_read, :delivery_board_read]

  @spec read_scoped_work_request_session(repo(), term(), scope_payload(), atom()) :: term()
  def read_scoped_work_request_session(repo, %Session{} = session, %{"repo" => repo_name, "base_branch" => base_branch}, action)
      when action in [:work_request_read, :delivery_board_read] and is_binary(repo_name) and is_binary(base_branch) do
    if handoff_work_request_read_scope?(repo, session) do
      put_assignment_scope(session, Scope.repo(repo_name, base_branch, metadata: %{source: :work_request_read_scope}))
    else
      session
    end
  end

  def read_scoped_work_request_session(_repo, %Session{} = session, _scope, _action), do: session

  defp handoff_work_request_read_scope?(repo, %Session{} = session) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, true} <- ArchitectHandoff.handoff_phase_grant?(repo, grant) do
      true
    else
      _reason -> false
    end
  end

  defp put_assignment_scope(%Session{assignment: %Assignment{} = assignment} = session, %Scope{} = scope) do
    scopes = List.wrap(assignment.scopes)

    if Enum.any?(scopes, &(assignment_scope_key(&1) == assignment_scope_key(scope))) do
      session
    else
      %{session | assignment: %{assignment | scopes: scopes ++ [scope]}}
    end
  end

  defp assignment_scope_key(%Scope{type: :repo, repo: repo, base_branch: base_branch}), do: {:repo, repo, base_branch}
  defp assignment_scope_key(%Scope{type: type, id: id}), do: {type, id}

  defp authorize_work_request_repo_policy(%Session{} = session, action, %{"repo" => repo, "base_branch" => base_branch} = scope, tool, opts) do
    target =
      Target.repo(repo, base_branch,
        phase_id: Map.get(scope, "phase_id"),
        metadata: work_request_repo_scope_metadata(opts)
      )

    authorize_policy(session, action, target, tool)
  end

  @spec authorize_work_request_policy(repo(), term(), atom(), term(), String.t(), keyword()) :: authorization_result()
  def authorize_work_request_policy(repo, %Session{} = session, action, %WorkRequest{} = work_request, tool, opts \\ []) do
    with {:ok, repo_scopes} <- work_request_repo_scope_payloads(repo, work_request, opts) do
      target =
        Target.work_request(work_request.id,
          repo: work_request.repo,
          base_branch: work_request.base_branch,
          phase_id: ArchitectHandoff.phase_id_for_work_request(work_request),
          repo_scopes: repo_scopes,
          metadata: work_request_repo_scope_metadata(opts)
        )

      authorize_policy(session, action, target, tool)
    end
  end

  defp authorize_work_package_policy(%Session{} = session, action, %WorkRequest{} = work_request, %WorkPackage{} = work_package, tool) do
    target =
      Target.work_package(work_package.id, work_request.id,
        repo: WorkPackage.repo(work_request, work_package),
        base_branch: work_package.base_branch || work_request.base_branch,
        phase_id: ArchitectHandoff.phase_id_for_work_request(work_request),
        work_package_id: work_package.id
      )

    authorize_policy(session, action, target, tool)
  end

  defp authorize_policy(%Session{} = session, action, %Target{} = target, tool) do
    with {:ok, actor} <- ActorResolver.from_session(session, actor_resolver_opts(target)) do
      actor
      |> Policy.decide(action, target)
      |> MCPError.from_decision(tool)
      |> wrap_authorization_policy_denial()
    end
  end

  defp mask_architect_scope_denial({:error, {:authorization_policy_denied, _code, _message, %{"reason_code" => "scope_mismatch"}}}) do
    {:error, :not_found}
  end

  defp mask_architect_scope_denial(result), do: result

  @spec architect_session?(term()) :: boolean()
  def architect_session?(%Session{assignment: %{grant_role: "architect"}}), do: true
  def architect_session?(%Session{}), do: false

  defp work_request_scoped_session?(%Session{assignment: %{scopes: scopes}}) when is_list(scopes) do
    Enum.any?(scopes, &match?(%Scope{type: :work_request}, &1))
  end

  @spec scoped_work_request(repo(), term(), filters(), keyword()) :: term()
  def scoped_work_request(repo, work_request_id, filters, opts \\ []) do
    with {:ok, %WorkRequest{} = work_request} <- WorkRequestService.get(repo, work_request_id),
         :ok <- require_work_request_scope(repo, work_request, filters, opts) do
      {:ok, work_request}
    else
      {:error, :forbidden} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec local_trusted_work_request_read_scope(repo(), term()) :: term()
  def local_trusted_work_request_read_scope(repo, work_request_id) do
    with {:ok, %WorkRequest{} = work_request} <- WorkRequestService.get(repo, work_request_id) do
      {:ok, work_request, %{"repo" => work_request.repo, "base_branch" => work_request.base_branch}}
    end
  end

  @spec scoped_work_request_question(repo(), term(), term()) :: term()
  def scoped_work_request_question(repo, work_request_id, question_id) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request_id) do
      case Enum.find(questions, &(&1.id == question_id)) do
        %ClarificationQuestion{} = question -> {:ok, question}
        nil -> {:error, :not_found}
      end
    end
  end

  @spec scoped_work_request_work_package(repo(), term(), term()) :: term()
  def scoped_work_request_work_package(repo, work_request_id, work_package_id) do
    WorkRequestService.get_work_package(repo, work_request_id, work_package_id)
  end

  @spec work_package_work_package_id(repo(), term(), term()) :: term()
  def work_package_work_package_id(_repo, %WorkRequest{id: work_request_id}, %WorkPackage{id: work_package_id, work_request_id: work_request_id}),
    do: {:ok, work_package_id}

  def work_package_work_package_id(_repo, %WorkRequest{}, %WorkPackage{}), do: {:error, :not_found}

  @spec scoped_delivery_board(repo(), term(), [term()], filters(), keyword()) :: term()
  def scoped_delivery_board(repo, %WorkRequest{} = work_request, work_packages, filters, opts \\ []) when is_list(work_packages) do
    {visible_work_package_ids, work_package_contexts} =
      visible_delivery_board_work_package_contexts(repo, work_request, work_packages, filters, opts)

    project_opts =
      [
        work_request: work_request,
        work_packages: work_packages,
        visible_work_package_ids: visible_work_package_ids,
        work_package_contexts: work_package_contexts,
        slice_projection: Keyword.get(opts, :slice_projection)
      ]
      |> Keyword.reject(fn {_key, value} -> is_nil(value) end)

    DeliveryBoard.project(repo, work_request.id, project_opts)
  end

  @spec visible_delivery_board_work_package_contexts(
          repo(),
          term(),
          [term()],
          filters(),
          keyword()
        ) :: {[String.t()], map()}
  def visible_delivery_board_work_package_contexts(repo, %WorkRequest{} = work_request, work_packages, filters, opts \\ []) do
    work_package_ids = Enum.map(work_packages, & &1.id)

    work_package_ids =
      repo.all(
        from(delivery in WorkPackageDelivery,
          where: delivery.work_request_id == ^work_request.id,
          where: delivery.work_package_id in ^work_package_ids,
          select: delivery.successor_work_package_id
        )
      )
      |> Enum.concat(Enum.map(work_packages, & &1.id))
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    work_package_contexts =
      work_package_ids
      |> scoped_delivery_work_packages_by_id(repo, work_request, work_packages, filters, opts)
      |> Map.new(fn {id, work_package} -> {id, %{work_package: work_package}} end)

    {Map.keys(work_package_contexts), work_package_contexts}
  end

  @spec primary_work_request_scope?(repo(), term(), filters(), keyword()) :: boolean()
  def primary_work_request_scope?(repo, %WorkRequest{} = work_request, filters, opts \\ []) do
    {:ok, matches?} = work_request_matches_primary_filters?(repo, work_request, filters, opts)
    matches?
  end

  defp delivery_work_package_visible_to_filters?(_work_package, true, _filters, _opts), do: true

  defp delivery_work_package_visible_to_filters?(%WorkPackage{} = work_package, false, filters, opts) do
    work_package_matches_filters?(work_package, filters, opts)
  end

  @spec require_scoped_delivery_work_package_visibility(
          term(),
          term(),
          term(),
          boolean(),
          filters()
        ) :: :ok | {:error, term()}
  def require_scoped_delivery_work_package_visibility(
        %WorkPackage{} = work_package,
        %WorkRequest{} = work_request,
        %WorkPackage{} = _delivery_work_package,
        primary_scope?,
        filters
      ) do
    with :ok <- require_delivery_work_package_scope(work_package, work_request) do
      require_delivery_work_package_filter_scope(work_package, primary_scope?, filters)
    end
  end

  @spec require_delivery_work_package_filter_scope(repo(), term(), term(), filters()) :: :ok | {:error, term()}
  def require_delivery_work_package_filter_scope(repo, %WorkPackage{} = work_package, %WorkRequest{} = work_request, filters) do
    primary_scope? = primary_work_request_scope?(repo, work_request, filters)
    require_delivery_work_package_filter_scope(work_package, primary_scope?, filters)
  end

  @spec require_delivery_work_package_filter_scope(term(), boolean(), filters()) :: :ok | {:error, term()}
  def require_delivery_work_package_filter_scope(%WorkPackage{} = work_package, primary_scope?, filters) do
    if delivery_work_package_visible_to_filters?(work_package, primary_scope?, filters, []) do
      :ok
    else
      {:error, :not_found}
    end
  end

  @spec require_work_request_scope(repo(), term(), filters(), keyword()) :: :ok | {:error, term()}
  def require_work_request_scope(repo, %WorkRequest{} = work_request, filters, opts \\ []) do
    match_fun = if Keyword.get(opts, :repo_scopes?, false), do: &work_request_matches_filters?/4, else: &work_request_matches_primary_filters?/4

    with {:ok, matches?} <- match_fun.(repo, work_request, filters, opts) do
      if matches?, do: :ok, else: {:error, :forbidden}
    end
  end

  @spec require_work_package_repo_scope(term(), term(), term()) :: :ok | {:error, term()}
  def require_work_package_repo_scope(%WorkPackage{} = work_package, %WorkRequest{} = work_request, %WorkPackage{}) do
    if work_package.work_request_id == work_request.id, do: :ok, else: {:error, :forbidden}
  end

  @spec require_work_package_delivery_base_scope(term(), term()) :: :ok | {:error, term()}
  def require_work_package_delivery_base_scope(%WorkPackage{base_branch: base_branch}, %WorkPackage{base_branch: base_branch}), do: :ok
  def require_work_package_delivery_base_scope(%WorkPackage{}, %WorkPackage{}), do: {:error, :forbidden}

  defp require_delivery_work_package_scope(%WorkPackage{} = work_package, %WorkRequest{} = work_request) do
    if work_package.work_request_id == work_request.id, do: :ok, else: {:error, :forbidden}
  end

  defp work_request_matches_filters?(repo, %WorkRequest{} = work_request, filters, opts) do
    with {:ok, repo_scopes} <- work_request_repo_scope_payloads(repo, work_request, opts) do
      {:ok,
       repo_scope_matches_filters?(repo_scopes, filters, opts) and
         Enum.all?(filters, fn
           {"status", status} when is_binary(status) ->
             work_request.status == status

           {"phase_id", phase_id} when is_binary(phase_id) ->
             ArchitectHandoff.phase_id_for_work_request(work_request) == phase_id

           _filter ->
             true
         end)}
    end
  end

  defp work_request_matches_primary_filters?(_repo, %WorkRequest{} = work_request, filters, opts) do
    {:ok,
     Enum.all?(filters, fn
       {"repo", repo} when is_binary(repo) -> repo_scope_name_matches?(repo, work_request.repo, opts)
       {"base_branch", base_branch} when is_binary(base_branch) -> work_request.base_branch == base_branch
       {"status", status} when is_binary(status) -> work_request.status == status
       {"phase_id", phase_id} when is_binary(phase_id) -> ArchitectHandoff.phase_id_for_work_request(work_request) == phase_id
       _filter -> true
     end)}
  end

  defp repo_scope_matches_filters?(repo_scopes, filters, opts) do
    repo = Map.get(filters, "repo")
    base_branch = Map.get(filters, "base_branch")

    cond do
      is_binary(repo) and is_binary(base_branch) ->
        Enum.any?(repo_scopes, &(repo_scope_name_matches?(repo, &1.repo, opts) and &1.base_branch == base_branch))

      is_binary(repo) ->
        Enum.any?(repo_scopes, &repo_scope_name_matches?(repo, &1.repo, opts))

      is_binary(base_branch) ->
        Enum.any?(repo_scopes, &match?(%{base_branch: ^base_branch}, &1))

      true ->
        true
    end
  end

  defp repo_scope_name_matches?(repo, repo, _opts) when is_binary(repo), do: true

  defp repo_scope_name_matches?(expected_repo, actual_repo, opts) when is_binary(expected_repo) and is_binary(actual_repo) do
    RepoIdentity.scope_match?(expected_repo, actual_repo,
      trusted_remotes: Keyword.get(opts, :repo_scope_trusted_remotes, default_repo_scope_trusted_remotes()),
      local_path_remotes?: true
    )
  end

  defp repo_scope_name_matches?(_expected_repo, _actual_repo, _opts), do: false

  @spec work_request_repo_scope_opts(term()) :: keyword()
  def work_request_repo_scope_opts(%Config{} = config) do
    [repo_scope_trusted_remotes: work_request_repo_scope_trusted_remotes(config)]
  end

  defp work_request_repo_scope_payloads(repo, %WorkRequest{} = work_request, opts) do
    repo_scopes_result =
      case Keyword.fetch(opts, :repo_scopes_by_work_request_id) do
        {:ok, repo_scopes_by_work_request_id} -> {:ok, Map.get(repo_scopes_by_work_request_id, work_request.id, [])}
        :error -> WorkRequestRepository.list_repo_scopes(repo, work_request.id)
      end

    with {:ok, repo_scopes} <- repo_scopes_result do
      {:ok,
       [%{repo: work_request.repo, base_branch: work_request.base_branch} | Enum.map(repo_scopes, &%{repo: &1.repo, base_branch: &1.base_branch})]
       |> Enum.filter(&is_binary(&1.repo))
       |> Enum.uniq_by(&{&1.repo, &1.base_branch})}
    end
  end

  defp work_package_matches_filters?(%WorkPackage{} = work_package, filters, opts) do
    Enum.all?(filters, fn
      {"repo", repo} when is_binary(repo) -> repo_scope_name_matches?(repo, work_package.repo, opts)
      {"base_branch", base_branch} when is_binary(base_branch) -> work_package.base_branch == base_branch
      _filter -> true
    end)
  end

  @spec require_live_architect_grant(repo(), term()) :: term()
  def require_live_architect_grant(repo, %Session{} = session) do
    case AccessGrantRepository.get(repo, session.assignment.grant_id) do
      {:ok, %AccessGrant{} = grant} ->
        assignment = assignment_with_live_grant_capabilities(session.assignment, grant)

        with :ok <- require_session_grant_match(assignment, grant),
             :ok <- require_live_grant(grant, DateTime.utc_now(:microsecond)),
             :ok <- require_architect_assignment(assignment) do
          {:ok, grant}
        end

      {:error, :not_found} ->
        {:error, :phase_scope_not_available}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec require_architect_phase_scope(repo(), term(), String.t()) :: :ok | {:error, term()}
  def require_architect_phase_scope(repo, %Session{} = session, phase_id) do
    case architect_phase_scope(repo, session) do
      {:ok, ^phase_id} -> :ok
      {:ok, _other_phase_id} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec architect_phase_scope(repo(), term()) :: {:ok, String.t()} | {:error, term()}
  def architect_phase_scope(repo, %Session{} = session) do
    case Session.phase_id(session) do
      phase_id when is_binary(phase_id) and phase_id != "" -> {:ok, phase_id}
      nil -> architect_session_anchor_phase_scope(repo, session)
      _phase_id -> {:error, :phase_scope_not_available}
    end
  end

  @spec require_architect_phase_anchor(repo(), term(), String.t()) :: :ok | {:error, term()}
  def require_architect_phase_anchor(repo, %Session{} = session, phase_id) when is_atom(repo) and is_binary(phase_id) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session) do
      require_architect_anchor_scope(anchor, grant, phase_id)
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp architect_explicit_phase_grant?(%AccessGrant{grant_role: "architect", phase_id: phase_id}) when is_binary(phase_id) and phase_id != "",
    do: true

  defp architect_explicit_phase_grant?(%AccessGrant{}), do: false

  defp scoped_delivery_work_packages_by_id([], _repo, %WorkRequest{}, _work_packages, _filters, _opts), do: %{}

  defp scoped_delivery_work_packages_by_id(work_package_ids, repo, %WorkRequest{} = work_request, work_packages, filters, opts) do
    primary_scope? = primary_work_request_scope?(repo, work_request, filters)
    filter_opts = if primary_scope?, do: [], else: opts

    work_packages_by_id =
      work_packages
      |> Enum.filter(&filled_string?(&1.id))
      |> Map.new(&{&1.id, &1})

    repo.all(from(work_package in WorkPackage, where: work_package.id in ^work_package_ids))
    |> Enum.filter(fn work_package ->
      case Map.fetch(work_packages_by_id, work_package.id) do
        {:ok, work_package} ->
          require_delivery_work_package_scope(work_package, work_request) == :ok and
            delivery_work_package_visible_to_filters?(work_package, primary_scope?, filters, filter_opts)

        :error ->
          false
      end
    end)
    |> Map.new(&{&1.id, &1})
  end

  defp wrap_authorization_policy_denial(:ok), do: :ok

  defp wrap_authorization_policy_denial({:error, code, message, data}) do
    {:error, {:authorization_policy_denied, code, message, data}}
  end

  defp actor_resolver_opts(%Target{} = target) do
    [
      work_request_id: target.work_request_id || target_work_request_id(target),
      repo: target.repo,
      base_branch: target.base_branch,
      phase_id: target.phase_id
    ]
  end

  defp target_work_request_id(%Target{type: :work_request, id: id}) when is_binary(id), do: id
  defp target_work_request_id(%Target{}), do: nil

  defp default_repo_scope_trusted_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp work_request_repo_scope_trusted_remotes(%Config{repo_root: repo_root} = config) when is_binary(repo_root) do
    WorktreeScope.repo_scope_trusted_remotes(config, repo_root)
  end

  defp work_request_repo_scope_trusted_remotes(%Config{}) do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp work_request_repo_scope_metadata(opts) do
    case opts |> Keyword.get(:repo_scope_trusted_remotes, []) |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] -> %{}
      trusted_remotes -> %{repo_scope_trusted_remotes: trusted_remotes}
    end
  end

  defp architect_anchor_work_package(repo, %Session{} = session) do
    case Session.work_package_id(session) do
      work_package_id when is_binary(work_package_id) -> WorkPackageRepository.get(repo, work_package_id)
      _work_package_id -> {:error, :phase_scope_not_available}
    end
  end

  defp assignment_with_live_grant_capabilities(assignment, %AccessGrant{} = grant) do
    %{assignment | capabilities: grant.capabilities || []}
  end

  defp require_session_grant_match(assignment, %AccessGrant{} = grant) do
    with {:ok, assignment_capabilities} <- comparable_capabilities(assignment.capabilities),
         {:ok, grant_capabilities} <- comparable_capabilities(grant.capabilities),
         true <- assignment.grant_id == grant.id,
         true <- assignment.work_package_id == grant.work_package_id,
         true <- assignment.phase_id == grant.phase_id,
         true <- assignment.display_key == grant.display_key,
         true <- assignment.grant_role == grant.grant_role,
         true <- assignment_capabilities == grant_capabilities,
         true <- assignment.claimed_at == grant.claimed_at,
         true <- assignment.claimed_by == grant.claimed_by do
      :ok
    else
      _mismatch -> {:error, :phase_scope_not_available}
    end
  end

  defp comparable_capabilities(capabilities) when is_list(capabilities), do: {:ok, capabilities}
  defp comparable_capabilities(nil), do: {:ok, []}

  defp require_live_grant(%AccessGrant{revoked_at: %DateTime{}}, _now), do: {:error, :assignment_revoked}

  defp require_live_grant(%AccessGrant{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      {:error, :expired}
    end
  end

  defp require_live_grant(%AccessGrant{expires_at: nil}, %DateTime{}), do: :ok

  defp architect_session_anchor_phase_scope(repo, %Session{} = session) when is_atom(repo) do
    case Session.work_package_id(session) do
      work_package_id when is_binary(work_package_id) -> architect_anchor_phase_scope(repo, work_package_id)
      _work_package_id -> {:error, :phase_scope_not_available}
    end
  end

  defp architect_session_anchor_phase_scope(_repo, %Session{}), do: {:error, :phase_scope_not_available}

  defp architect_anchor_phase_scope(repo, work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %{phase_id: phase_id}} when is_binary(phase_id) and phase_id != "" -> {:ok, phase_id}
      {:ok, _work_package} -> {:error, :phase_scope_not_available}
      {:error, _reason} -> {:error, :phase_scope_not_available}
    end
  end

  defp require_architect_anchor_scope(%WorkPackage{} = anchor, %AccessGrant{} = grant, phase_id) do
    cond do
      anchor.phase_id != phase_id ->
        {:error, :phase_scope_not_available}

      architect_explicit_phase_grant?(grant) ->
        require_frozen_anchor_scope(anchor, grant)

      true ->
        :ok
    end
  end

  defp require_frozen_anchor_scope(%WorkPackage{} = anchor, %AccessGrant{} = grant) do
    if grant.phase_id == anchor.phase_id and repo_scope_name_matches?(grant.scope_repo, anchor.repo, []) and grant.scope_base_branch == anchor.base_branch do
      :ok
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp require_architect_assignment(%{grant_role: "architect"}), do: :ok
  defp require_architect_assignment(_assignment), do: {:error, :architect_grant_required}

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""
end
