defmodule SymphonyElixir.SymphonyPlusPlus.Comments.Service do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.ActorResolver
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Policy
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Repository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type error ::
          Repository.error()
          | :unauthenticated
          | {:authorization_policy_denied, Decision.t()}

  @spec create(Repository.repo(), map()) :: {:ok, Comment.t()} | {:error, error()}
  def create(repo, attrs), do: Repository.create(repo, attrs)

  @spec create_for_assignment(Repository.repo(), Assignment.t(), map()) ::
          {:ok, Comment.t()} | {:error, error()}
  def create_for_assignment(repo, assignment, attrs), do: create_for_assignment(repo, assignment, attrs, [])

  @spec create_for_assignment(Repository.repo(), Assignment.t(), map(), keyword()) ::
          {:ok, Comment.t()} | {:error, error()}
  def create_for_assignment(repo, %Assignment{} = assignment, attrs, opts) when is_atom(repo) and is_map(attrs) do
    attrs = normalize_keys(attrs)

    with {:ok, target_kind} <- required_target_value(attrs, "target_kind"),
         {:ok, target_id} <- required_target_value(attrs, "target_id"),
         action = Keyword.get(opts, :action, :comment_add),
         {:ok, target} <- comment_target(repo, assignment, target_kind, target_id),
         :ok <- authorize_comment_action(assignment, action, target) do
      create(repo, attrs)
    end
  end

  def create_for_assignment(repo, _assignment, attrs, _opts) when is_atom(repo) and is_map(attrs), do: {:error, :unauthenticated}

  @spec get(Repository.repo(), String.t()) :: {:ok, Comment.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list_for_target(Repository.repo(), String.t(), String.t()) :: {:ok, [Comment.t()]} | {:error, error()}
  def list_for_target(repo, target_kind, target_id), do: Repository.list_for_target(repo, target_kind, target_id)

  @spec delete_for_targets(Repository.repo(), [Repository.target()]) :: {:ok, non_neg_integer()} | {:error, error()}
  def delete_for_targets(repo, targets), do: Repository.delete_for_targets(repo, targets)

  @spec list_for_assignment(Repository.repo(), Assignment.t(), String.t(), String.t()) ::
          {:ok, [Comment.t()]} | {:error, error()}
  def list_for_assignment(repo, %Assignment{} = assignment, target_kind, target_id)
      when is_atom(repo) and is_binary(target_kind) and is_binary(target_id) do
    with {:ok, target} <- comment_target(repo, assignment, target_kind, target_id),
         :ok <- authorize_comment_action(assignment, :comment_list, target) do
      list_for_target(repo, target_kind, target_id)
    end
  end

  def list_for_assignment(repo, _assignment, target_kind, target_id)
      when is_atom(repo) and is_binary(target_kind) and is_binary(target_id),
      do: {:error, :unauthenticated}

  @spec list_for_targets(Repository.repo(), [Repository.target()]) :: {:ok, %{Repository.target() => [Comment.t()]}} | {:error, error()}
  def list_for_targets(repo, targets), do: Repository.list_for_targets(repo, targets)

  @spec counts_for_targets(Repository.repo(), [Repository.target()]) ::
          {:ok, %{Repository.target() => %{comment_count: non_neg_integer(), open_comment_count: non_neg_integer()}}} | {:error, error()}
  def counts_for_targets(repo, targets), do: Repository.counts_for_targets(repo, targets)

  @spec resolve(Repository.repo(), String.t(), map()) :: {:ok, Comment.t()} | {:error, error()}
  def resolve(repo, id, attrs), do: Repository.resolve(repo, id, attrs)

  @spec resolve_for_assignment(Repository.repo(), Assignment.t(), String.t(), map()) ::
          {:ok, Comment.t()} | {:error, error()}
  def resolve_for_assignment(repo, %Assignment{} = assignment, id, attrs)
      when is_atom(repo) and is_binary(id) and is_map(attrs) do
    with {:ok, %Comment{} = comment} <- get(repo, id),
         {:ok, target} <- comment_target(repo, assignment, comment.target_kind, comment.target_id),
         :ok <- authorize_comment_action(assignment, :comment_resolve, target) do
      resolve(repo, id, attrs)
    else
      {:error, {:authorization_policy_denied, %Decision{}}} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def resolve_for_assignment(repo, _assignment, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs),
    do: {:error, :unauthenticated}

  defp authorize_comment_action(%Assignment{} = assignment, action, %Target{} = target) do
    decision =
      assignment
      |> ActorResolver.from_assignment(PlanningService.package_surface_actor_opts(assignment, target))
      |> Policy.decide(action, target)

    case decision do
      %Decision{allowed?: true} -> :ok
      %Decision{} = decision -> {:error, {:authorization_policy_denied, decision}}
    end
  end

  defp comment_target(repo, %Assignment{}, "work_request", target_id) do
    with {:ok, %WorkRequest{} = work_request} <- WorkRequestRepository.get(repo, target_id) do
      {:ok,
       Target.work_request(work_request.id,
         repo: work_request.repo,
         base_branch: work_request.base_branch,
         phase_id: ArchitectHandoff.phase_id_for_work_request(work_request)
       )}
    end
  end

  defp comment_target(repo, %Assignment{} = assignment, "work_package", target_id) do
    case repo.one(work_package_with_work_request_query(target_id)) do
      {%WorkPackage{} = work_package, %WorkRequest{} = work_request} ->
        opts = [
          repo: WorkPackage.repo(work_request, work_package),
          base_branch: work_package.base_branch || work_request.base_branch,
          phase_id: ArchitectHandoff.phase_id_for_work_request(work_request)
        ]

        opts =
          if assignment.grant_role == "architect" do
            Keyword.put(opts, :work_package_id, work_package.id)
          else
            opts
          end

        {:ok, Target.work_package(work_package.id, work_request.id, opts)}

      nil ->
        case repo.get(WorkPackage, target_id) do
          %WorkPackage{work_request_id: nil} = work_package ->
            {:ok,
             Target.work_package(work_package.id,
               repo: work_package.repo,
               base_branch: work_package.base_branch,
               phase_id: work_package.phase_id
             )}

          _work_package ->
            {:error, :not_found}
        end
    end
  end

  defp comment_target(_repo, %Assignment{}, _target_kind, _target_id), do: {:error, :invalid_target}

  defp work_package_with_work_request_query(target_id) do
    from(work_package in WorkPackage,
      join: work_request in WorkRequest,
      on: work_request.id == work_package.work_request_id,
      where: work_package.id == ^target_id,
      select: {work_package, work_request},
      limit: 1
    )
  end

  defp required_target_value(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :invalid_target}
    end
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
