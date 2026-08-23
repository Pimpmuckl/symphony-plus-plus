defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle do
  @moduledoc false

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SymphonyPlusPlus.BaseBranch
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreePath
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeTargetRoot

  @type repo :: module()
  @type git_failure :: %{
          status: non_neg_integer(),
          stderr: String.t(),
          target_repo_root: String.t(),
          worktree_path: String.t() | nil,
          recorded_worktree_path: String.t() | nil,
          resolved_worktree_path: String.t() | nil,
          stage: String.t() | nil,
          rule: String.t() | nil,
          branch: String.t() | nil,
          base_branch: String.t() | nil,
          git_args: [String.t()]
        }
  @type lifecycle_result :: %{
          optional(:recorded_worktree_path) => String.t(),
          optional(:resolved_worktree_path) => String.t(),
          optional(:stage) => String.t(),
          optional(:rule) => String.t(),
          work_package: WorkPackage.t(),
          status: String.t(),
          worktree_path: String.t() | nil,
          branch: String.t() | nil,
          base_branch: String.t() | nil,
          repo_root: String.t() | nil,
          target_repo_root: String.t() | nil
        }
  @type cleanup_failure :: %{
          stage: String.t(),
          rule: String.t(),
          recorded_worktree_path: String.t(),
          resolved_worktree_path: String.t()
        }
  @type error ::
          Repository.error()
          | :git_not_found
          | :invalid_base_branch
          | :invalid_branch
          | :invalid_target_repo_root
          | :invalid_worktree_path
          | :recorded_worktree_missing
          | {:stale_existing_branch, map()}
          | :unsafe_worktree_path
          | :worktree_path_exists
          | :worktree_path_missing_on_disk
          | {:git_failed, non_neg_integer(), git_failure()}
          | {:path_canonicalize_failed, Path.t(), term()}
          | {:target_repo_root_conflict, Path.t(), Path.t()}
          | {:worktree_cleanup_failed, cleanup_failure()}
          | {:worktree_path_already_recorded, Path.t()}
          | {:worktree_record_failed, term()}

  @spec prepare(repo(), String.t(), map()) :: {:ok, lifecycle_result()} | {:error, error()}
  @spec prepare(repo(), String.t(), map(), keyword()) :: {:ok, lifecycle_result()} | {:error, error()}
  def prepare(repo, work_package_id, attrs, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_map(attrs) and is_list(opts) do
    with {:ok, %WorkPackage{} = work_package} <- Repository.get(repo, work_package_id),
         {:ok, target_repo_root} <- target_repo_root(attrs),
         {:ok, requested_base_branch} <- ref_name(attrs, "base_branch", :invalid_base_branch, target_repo_root, opts),
         base_branch = BaseBranch.canonicalize(requested_base_branch),
         :ok <- require_base_branch(work_package, base_branch),
         {:ok, branch} <- ref_name(attrs, "branch", :invalid_branch, target_repo_root, opts),
         {:ok, worktree_parent} <- worktree_parent(attrs, opts),
         {:ok, worktree_path} <- worktree_path(work_package, target_repo_root, branch, worktree_parent, opts),
         {:ok, worktree_path} <-
           validate_recorded_prepare_path(work_package, worktree_path, target_repo_root, branch, worktree_parent) do
      maybe_replay_prepared(repo, work_package, target_repo_root, base_branch, branch, worktree_path, opts)
    end
  end

  @spec cleanup(repo(), String.t()) :: {:ok, lifecycle_result()} | {:error, error()}
  @spec cleanup(repo(), String.t(), keyword()) :: {:ok, lifecycle_result()} | {:error, error()}
  def cleanup(repo, work_package_id, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_list(opts) do
    with {:ok, %WorkPackage{} = work_package} <- Repository.get(repo, work_package_id) do
      cleanup_recorded_worktree(repo, work_package, opts)
    end
  end

  @doc false
  @spec cleanup_obligation(WorkPackage.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def cleanup_obligation(%WorkPackage{worktree_path: worktree_path} = work_package, opts)
      when is_binary(worktree_path) and is_list(opts) do
    with {:ok, root} <- worktree_root(opts),
         {:ok, worktree_path} <- canonicalize(worktree_path),
         :ok <- require_inside_root(worktree_path, root),
         {:ok, target_repo_root} <- cleanup_obligation_target_root(work_package, worktree_path) do
      {:ok,
       %{
         worktree_path: worktree_path,
         work_package_id: work_package.id,
         target_repo_root: target_repo_root,
         cleanup_proof: cleanup_proof(work_package, worktree_path, target_repo_root)
       }}
    end
  end

  @doc false
  @spec cleanup_obligation(repo(), map(), keyword()) :: {:ok, lifecycle_result()} | {:error, error()}
  def cleanup_obligation(repo, obligation, opts) when is_atom(repo) and is_map(obligation) and is_list(opts) do
    work_package = %WorkPackage{
      id: Map.fetch!(obligation, :work_package_id),
      worktree_path: Map.fetch!(obligation, :worktree_path),
      worktree_target_repo_root: Map.fetch!(obligation, :target_repo_root),
      worktree_cleanup_proof: Map.fetch!(obligation, :cleanup_proof)
    }

    cleanup_recorded_worktree(repo, work_package, Keyword.put(opts, :detached_cleanup, true))
  end

  @spec validate_cleanup(repo(), String.t()) :: {:ok, lifecycle_result()} | {:error, error()}
  @spec validate_cleanup(repo(), String.t(), keyword()) :: {:ok, lifecycle_result()} | {:error, error()}
  def validate_cleanup(repo, work_package_id, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_list(opts) do
    with {:ok, %WorkPackage{} = work_package} <- Repository.get(repo, work_package_id) do
      validate_recorded_worktree_cleanup(work_package, opts)
    end
  end

  @spec worktree_root(keyword()) :: {:ok, Path.t()} | {:error, error()}
  def worktree_root(opts \\ []) when is_list(opts) do
    opts
    |> codex_home()
    |> then(&Path.join([&1, "worktrees", "spp_worktrees"]))
    |> canonicalize()
  end

  defp target_repo_root(attrs) do
    with {:ok, repo_root} <- target_repo_root_value(attrs),
         {:ok, repo_root} <- canonicalize(repo_root),
         true <- File.dir?(repo_root) do
      {:ok, repo_root}
    else
      false -> {:error, :invalid_target_repo_root}
      {:error, _reason} = error -> error
      :error -> {:error, :invalid_target_repo_root}
    end
  end

  defp target_repo_root_value(attrs) do
    with {:ok, target_repo_root} <- optional_string(attrs, "target_repo_root"),
         {:ok, repo_root} <- optional_string(attrs, "repo_root") do
      target_repo_root_value(target_repo_root, repo_root)
    else
      :error -> :error
    end
  end

  defp target_repo_root_value(target_repo_root, nil) when is_binary(target_repo_root), do: {:ok, target_repo_root}
  defp target_repo_root_value(nil, repo_root) when is_binary(repo_root), do: {:ok, repo_root}
  defp target_repo_root_value(nil, nil), do: :error

  defp target_repo_root_value(target_repo_root, repo_root) do
    with {:ok, target_repo_root} <- canonicalize(target_repo_root),
         {:ok, repo_root} <- canonicalize(repo_root) do
      target_repo_root_conflict(target_repo_root, repo_root)
    end
  end

  defp target_repo_root_conflict(target_repo_root, repo_root) do
    if same_path?(target_repo_root, repo_root) do
      {:ok, target_repo_root}
    else
      {:error, {:target_repo_root_conflict, target_repo_root, repo_root}}
    end
  end

  defp ref_name(attrs, key, error, repo_root, opts) do
    with {:ok, ref_name} <- required_string(attrs, key),
         :ok <- git(repo_root, ["check-ref-format", "--branch", ref_name], opts) do
      {:ok, ref_name}
    else
      :error -> {:error, error}
      {:error, {:git_failed, _status, _details}} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_base_branch(%WorkPackage{base_branch: recorded}, requested) do
    if BaseBranch.canonicalize(recorded) == requested, do: :ok, else: {:error, :invalid_base_branch}
  end

  defp worktree_parent(attrs, opts) do
    with {:ok, root} <- worktree_root(opts),
         {:ok, parent} <- optional_string(attrs, "worktree_parent") do
      resolve_worktree_parent(root, parent)
    else
      :error -> {:error, :unsafe_worktree_path}
    end
  end

  defp resolve_worktree_parent(root, nil), do: {:ok, root}

  defp resolve_worktree_parent(root, parent) do
    with {:ok, parent} <- canonicalize(parent),
         :ok <- require_inside_root(parent, root) do
      {:ok, parent}
    end
  end

  defp worktree_path(%WorkPackage{} = work_package, repo_root, branch, worktree_parent, opts) do
    with {:ok, leaf} <- worktree_leaf(work_package, repo_root, branch, worktree_parent, opts),
         candidate <- Path.join(worktree_parent, leaf),
         {:ok, candidate} <- canonicalize(candidate),
         :ok <- require_inside_root(candidate, worktree_parent) do
      {:ok, candidate}
    end
  end

  defp worktree_leaf(%WorkPackage{} = work_package, repo_root, branch, worktree_parent, opts) do
    with {:ok, leaves} <- WorktreePath.collision_worktree_leaves(repo_root, work_package.id, branch) do
      worktree_list = reserved_worktree_list(repo_root, opts)

      case Enum.find_value(leaves, &available_worktree_leaf(&1, work_package, worktree_parent, worktree_list)) do
        nil -> {:error, :worktree_path_exists}
        leaf -> {:ok, leaf}
      end
    end
  end

  defp reserved_worktree_list(repo_root, opts) do
    case git_output(repo_root, ["worktree", "list", "--porcelain"], opts) do
      {:ok, output} -> output
      {:error, _reason} -> ""
    end
  end

  defp available_worktree_leaf({leaf, _length}, %WorkPackage{} = work_package, worktree_parent, worktree_list) do
    candidate = Path.join(worktree_parent, leaf)

    path_unavailable? = File.exists?(candidate) or worktree_list_includes?(worktree_list, candidate)

    if path_unavailable? and not same_recorded_path?(work_package.worktree_path, candidate), do: nil, else: leaf
  end

  defp same_recorded_path?(recorded_path, candidate) when is_binary(recorded_path), do: same_path?(recorded_path, candidate)
  defp same_recorded_path?(_recorded_path, _candidate), do: false

  defp validate_recorded_prepare_path(%WorkPackage{worktree_path: nil}, worktree_path, _repo_root, _branch, _worktree_parent), do: {:ok, worktree_path}

  defp validate_recorded_prepare_path(%WorkPackage{worktree_path: recorded_path} = work_package, worktree_path, repo_root, branch, worktree_parent) do
    with {:ok, recorded_path} <- canonicalize(recorded_path) do
      cond do
        same_path?(recorded_path, worktree_path) ->
          {:ok, recorded_path}

        replayable_managed_prepare_path?(work_package, repo_root, branch, recorded_path, worktree_parent) ->
          {:ok, recorded_path}

        true ->
          {:error, {:worktree_path_already_recorded, recorded_path}}
      end
    end
  end

  defp maybe_replay_prepared(repo, %WorkPackage{worktree_path: recorded_path} = work_package, repo_root, base_branch, branch, worktree_path, opts)
       when is_binary(recorded_path) do
    with true <- File.dir?(worktree_path),
         :ok <- require_git_worktree(worktree_path, repo_root, opts),
         {:ok, work_package} <- ensure_recorded_target_repo_root(repo, work_package, repo_root) do
      {:ok, result(work_package, "already_prepared", worktree_path, branch, base_branch, repo_root)}
    else
      false -> {:error, :recorded_worktree_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_replay_prepared(repo, %WorkPackage{} = work_package, repo_root, base_branch, branch, worktree_path, opts) do
    if File.exists?(worktree_path) do
      {:error, :worktree_path_exists}
    else
      create_worktree(repo, work_package, repo_root, base_branch, branch, worktree_path, opts)
    end
  end

  defp create_worktree(repo, %WorkPackage{} = work_package, repo_root, base_branch, branch, worktree_path, opts) do
    git_opts = git_context_opts(opts, repo_root, worktree_path, branch, base_branch)

    with :ok <- File.mkdir_p(Path.dirname(worktree_path)),
         :ok <- fetch_remote_base(repo_root, base_branch, git_opts),
         :ok <- git(repo_root, ["worktree", "prune"], git_opts),
         {:ok, branch_exists?} <- local_branch_exists?(repo_root, branch, git_opts),
         :ok <- add_worktree(repo_root, worktree_path, base_branch, branch, branch_exists?, git_opts) do
      record_prepared_worktree(
        repo,
        work_package,
        repo_root,
        base_branch,
        branch,
        worktree_path,
        !branch_exists?,
        git_opts
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_prepared_worktree(repo, %WorkPackage{} = work_package, repo_root, base_branch, branch, worktree_path, branch_created?, opts) do
    case Repository.update(repo, work_package.id, %{
           worktree_path: worktree_path,
           worktree_target_repo_root: repo_root,
           worktree_cleanup_proof: nil
         }) do
      {:ok, updated_work_package} ->
        {:ok, result(updated_work_package, "prepared", worktree_path, branch, base_branch, repo_root)}

      {:error, reason} ->
        _ = git(repo_root, ["worktree", "remove", worktree_path], opts)
        _ = git(repo_root, ["worktree", "prune"], opts)
        _ = maybe_delete_created_branch(repo_root, branch, branch_created?, opts)
        {:error, {:worktree_record_failed, reason}}
    end
  end

  defp ensure_recorded_target_repo_root(repo, %WorkPackage{worktree_target_repo_root: nil} = work_package, repo_root) do
    Repository.update(repo, work_package.id, %{worktree_target_repo_root: repo_root})
  end

  defp ensure_recorded_target_repo_root(_repo, %WorkPackage{} = work_package, _repo_root), do: {:ok, work_package}

  defp local_branch_exists?(repo_root, branch, opts) do
    case git(repo_root, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"], opts) do
      :ok -> {:ok, true}
      {:error, {:git_failed, 1, _details}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_worktree(repo_root, worktree_path, base_branch, branch, true, opts) do
    with :ok <- require_existing_branch_matches_base(repo_root, branch, base_branch, opts) do
      add_worktree_or_existing_path_error(repo_root, ["worktree", "add", worktree_path, branch], opts)
    end
  end

  defp add_worktree(repo_root, worktree_path, base_branch, branch, false, opts) do
    git(repo_root, ["worktree", "add", "-b", branch, worktree_path, "origin/#{base_branch}"], opts)
  end

  defp add_worktree_or_existing_path_error(repo_root, args, opts) do
    case git(repo_root, args, opts) do
      {:error, {:git_failed, 128, %{stderr: stderr}} = reason} when is_binary(stderr) ->
        if String.contains?(stderr, "already used by worktree"), do: {:error, :worktree_path_exists}, else: {:error, reason}

      result ->
        result
    end
  end

  defp maybe_delete_created_branch(repo_root, branch, true, opts) do
    git(repo_root, ["branch", "-D", branch], opts)
  end

  defp maybe_delete_created_branch(_repo_root, _branch, false, _opts), do: :ok

  defp require_existing_branch_matches_base(repo_root, branch, base_branch, opts) do
    base_ref = "origin/#{base_branch}"

    with {:ok, branch_revision} <- git_revision(repo_root, branch, opts),
         {:ok, base_revision} <- git_revision(repo_root, base_ref, opts) do
      if branch_revision == base_revision do
        :ok
      else
        {:error,
         {:stale_existing_branch,
          %{
            branch: branch,
            existing_revision: branch_revision,
            base_revision: base_revision,
            base_ref: base_ref,
            remediation: "Retry without branch if this branch was explicit; otherwise choose another unused branch."
          }}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_recorded_worktree(
         repo,
         %WorkPackage{
           worktree_path: nil,
           worktree_target_repo_root: target_repo_root,
           worktree_cleanup_proof: cleanup_proof
         } = work_package,
         opts
       )
       when is_binary(target_repo_root) or is_binary(cleanup_proof) do
    with {:ok, updated_work_package} <- persist_cleanup_state(repo, work_package, cleared_worktree_attrs(), opts) do
      {:ok, result(updated_work_package, "already_clean", nil, nil, nil, nil)}
    end
  end

  defp cleanup_recorded_worktree(_repo, %WorkPackage{worktree_path: nil} = work_package, _opts) do
    {:ok, result(work_package, "already_clean", nil, nil, nil, nil)}
  end

  defp cleanup_recorded_worktree(repo, %WorkPackage{} = work_package, opts) do
    with {:ok, root} <- worktree_root(opts),
         {:ok, worktree_path} <- canonicalize(work_package.worktree_path),
         :ok <- require_inside_root(worktree_path, root),
         {:ok, work_package, opts} <- cleanup_recorded_target_repo_root_opts(repo, work_package, opts, worktree_path),
         opts <- cleanup_context_opts(recorded_target_repo_root_opts(opts, work_package), worktree_path) do
      cleanup_existing_or_missing_worktree(repo, work_package, worktree_path, opts)
    end
  end

  defp validate_recorded_worktree_cleanup(%WorkPackage{worktree_path: nil} = work_package, _opts) do
    {:ok, result(work_package, "already_clean", nil, nil, nil, nil)}
  end

  defp validate_recorded_worktree_cleanup(%WorkPackage{} = work_package, opts) do
    with {:ok, root} <- worktree_root(opts),
         {:ok, worktree_path} <- canonicalize(work_package.worktree_path),
         :ok <- require_inside_root(worktree_path, root),
         {:ok, opts} <- cleanup_validation_target_repo_root_opts(work_package, opts, worktree_path) do
      validate_existing_or_missing_worktree_cleanup(work_package, worktree_path, opts)
    end
  end

  defp cleanup_existing_or_missing_worktree(repo, %WorkPackage{} = work_package, worktree_path, opts) do
    cond do
      File.dir?(worktree_path) and not WorktreeTargetRoot.git_metadata_present?(worktree_path) ->
        cleanup_non_git_recorded_worktree_directory(repo, work_package, worktree_path, opts)

      File.dir?(worktree_path) ->
        cleanup_existing_worktree(repo, work_package, worktree_path, opts)

      File.exists?(worktree_path) ->
        {:error, :invalid_worktree_path}

      true ->
        clear_missing_recorded_worktree(repo, work_package, worktree_path, opts)
    end
  end

  defp validate_existing_or_missing_worktree_cleanup(%WorkPackage{} = work_package, worktree_path, opts) do
    cond do
      File.dir?(worktree_path) and not WorktreeTargetRoot.git_metadata_present?(worktree_path) ->
        validate_non_git_recorded_worktree_directory_cleanup(work_package, worktree_path, opts)

      File.dir?(worktree_path) ->
        validate_existing_worktree_cleanup(work_package, worktree_path, opts)

      File.exists?(worktree_path) ->
        {:error, :invalid_worktree_path}

      true ->
        validate_missing_recorded_worktree_cleanup(work_package, worktree_path, opts)
    end
  end

  defp cleanup_non_git_recorded_worktree_directory(repo, %WorkPackage{} = work_package, worktree_path, opts) do
    with {:ok, repo_root} <- cleanup_repo_root(opts),
         opts <- cleanup_context_opts(opts, repo_root, worktree_path),
         compact_owner? <- compact_worktree_owner?(work_package, repo_root, worktree_path),
         :ok <- require_missing_recorded_worktree_owner(repo_root, worktree_path, opts, compact_owner?) do
      if cleanup_proof_matches?(work_package, worktree_path, repo_root) do
        cleanup_proven_residue(repo, work_package, worktree_path, repo_root, opts)
      else
        cleanup_unproven_non_git_directory(repo, work_package, worktree_path, repo_root, opts)
      end
    end
  end

  defp cleanup_unproven_non_git_directory(repo, work_package, worktree_path, repo_root, opts) do
    with {:ok, stale_metadata_paths} <- require_removable_non_git_directory(worktree_path),
         :ok <- remove_stale_metadata_paths(stale_metadata_paths),
         :ok <- remove_empty_directory(worktree_path),
         :ok <- git(repo_root, ["worktree", "prune"], opts),
         {:ok, updated_work_package} <- persist_cleanup_state(repo, work_package, cleared_worktree_attrs(), opts) do
      {:ok, result(updated_work_package, "stale_record_cleared", nil, nil, nil, repo_root)}
    end
  end

  defp validate_non_git_recorded_worktree_directory_cleanup(%WorkPackage{} = work_package, worktree_path, opts) do
    with {:ok, repo_root} <- cleanup_repo_root(opts),
         opts <- cleanup_context_opts(opts, repo_root, worktree_path),
         compact_owner? <- compact_worktree_owner?(work_package, repo_root, worktree_path),
         :ok <- require_missing_recorded_worktree_owner(repo_root, worktree_path, opts, compact_owner?) do
      validate_owned_non_git_directory_cleanup(work_package, worktree_path, repo_root)
    end
  end

  defp validate_owned_non_git_directory_cleanup(work_package, worktree_path, repo_root) do
    if cleanup_proof_matches?(work_package, worktree_path, repo_root) do
      {:ok, cleanup_recovery_result(work_package, worktree_path, repo_root)}
    else
      with {:ok, _stale_metadata_paths} <- require_removable_non_git_directory(worktree_path) do
        {:ok, result(work_package, "stale_record_cleared", nil, nil, nil, repo_root)}
      end
    end
  end

  defp cleanup_existing_worktree(repo, %WorkPackage{} = work_package, worktree_path, opts) do
    with {:ok, repo_root} <- cleanup_repo_root(opts),
         opts <- cleanup_context_opts(opts, repo_root, worktree_path),
         :ok <- require_recorded_worktree_owner(repo_root, worktree_path, opts),
         :ok <- require_git_worktree(worktree_path, repo_root, opts),
         {:ok, work_package} <- persist_cleanup_proof(repo, work_package, worktree_path, repo_root, opts),
         opts <- cleanup_removal_context_opts(opts, work_package, worktree_path, repo_root),
         :ok <- git(repo_root, ["worktree", "remove", "--force", worktree_path], opts),
         :ok <- git(repo_root, ["worktree", "prune"], opts),
         {:ok, updated_work_package} <- persist_cleanup_state(repo, work_package, cleared_worktree_attrs(), opts) do
      {:ok, result(updated_work_package, "cleaned", worktree_path, nil, nil, repo_root)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_cleanup_proof(repo, %WorkPackage{} = work_package, worktree_path, repo_root, opts) do
    proof = cleanup_proof(work_package, worktree_path, repo_root)

    if work_package.worktree_cleanup_proof == proof do
      {:ok, work_package}
    else
      persist_cleanup_state(repo, work_package, %{worktree_cleanup_proof: proof}, opts)
    end
  end

  defp cleanup_proven_residue(repo, work_package, worktree_path, repo_root, opts) do
    with :ok <- remove_proven_residue(work_package, worktree_path),
         :ok <- git(repo_root, ["worktree", "prune"], opts),
         {:ok, updated_work_package} <- persist_cleanup_state(repo, work_package, cleared_worktree_attrs(), opts) do
      {:ok, cleanup_recovery_result(updated_work_package, worktree_path, repo_root, work_package)}
    end
  end

  defp remove_proven_residue(work_package, worktree_path) do
    case File.rm_rf(worktree_path) do
      {:ok, _removed} ->
        :ok

      {:error, _reason, failed_path} ->
        _ = File.chmod(failed_path, 0o700)

        case File.rm_rf(worktree_path) do
          {:ok, _removed} ->
            :ok

          {:error, _reason, _failed_path} ->
            {:error, {:worktree_cleanup_failed, cleanup_failure(work_package, worktree_path)}}
        end
    end
  end

  defp cleanup_failure(work_package, worktree_path) do
    %{
      stage: "residue_removal",
      rule: "durable_preflight_proof",
      recorded_worktree_path: sanitize_path(work_package.worktree_path),
      resolved_worktree_path: sanitize_path(worktree_path)
    }
  end

  defp cleanup_recovery_result(work_package, worktree_path, repo_root, proof_package \\ nil) do
    proof_package = proof_package || work_package

    result(work_package, "stale_record_cleared", nil, nil, nil, repo_root)
    |> Map.merge(%{
      stage: "residue_removal",
      rule: "durable_preflight_proof",
      recorded_worktree_path: proof_package.worktree_path,
      resolved_worktree_path: worktree_path
    })
  end

  defp validate_existing_worktree_cleanup(%WorkPackage{} = work_package, worktree_path, opts) do
    with {:ok, repo_root} <- cleanup_repo_root(opts),
         opts <- cleanup_context_opts(opts, repo_root, worktree_path),
         :ok <- require_recorded_worktree_owner(repo_root, worktree_path, opts),
         :ok <- require_git_worktree(worktree_path, repo_root, opts) do
      {:ok, result(work_package, "cleaned", worktree_path, nil, nil, repo_root)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_removable_non_git_directory(worktree_path) do
    case File.ls(worktree_path) do
      {:ok, []} ->
        {:ok, []}

      {:ok, [".git"]} ->
        dot_git = Path.join(worktree_path, ".git")

        if File.regular?(dot_git) and not WorktreeTargetRoot.git_metadata_present?(worktree_path) do
          {:ok, [dot_git]}
        else
          {:error, :invalid_worktree_path}
        end

      {:ok, _entries} ->
        {:error, :invalid_worktree_path}

      {:error, _reason} ->
        {:error, :invalid_worktree_path}
    end
  end

  defp remove_stale_metadata_paths(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :invalid_worktree_path}}
      end
    end)
  end

  defp remove_empty_directory(worktree_path) do
    case File.rmdir(worktree_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :invalid_worktree_path}
    end
  end

  defp clear_missing_recorded_worktree(repo, %WorkPackage{} = work_package, worktree_path, opts) do
    case cleanup_repo_root(opts) do
      {:ok, repo_root} ->
        with opts <- cleanup_context_opts(opts, repo_root, worktree_path),
             compact_owner? <- compact_worktree_owner?(work_package, repo_root, worktree_path),
             :ok <- require_missing_recorded_worktree_owner(repo_root, worktree_path, opts, compact_owner?),
             :ok <- git(repo_root, ["worktree", "prune"], opts) do
          clear_recorded_worktree(repo, work_package, repo_root, opts)
        end

      {:error, :invalid_target_repo_root} ->
        clear_recorded_worktree(repo, work_package, nil, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_missing_recorded_worktree_cleanup(%WorkPackage{} = work_package, worktree_path, opts) do
    case cleanup_repo_root(opts) do
      {:ok, repo_root} ->
        with opts <- cleanup_context_opts(opts, repo_root, worktree_path),
             compact_owner? <- compact_worktree_owner?(work_package, repo_root, worktree_path),
             :ok <- require_missing_recorded_worktree_owner(repo_root, worktree_path, opts, compact_owner?) do
          {:ok, result(work_package, "stale_record_cleared", nil, nil, nil, repo_root)}
        end

      {:error, :invalid_target_repo_root} ->
        {:ok, result(work_package, "stale_record_cleared", nil, nil, nil, nil)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clear_recorded_worktree(repo, work_package, repo_root, opts) do
    with {:ok, updated_work_package} <- persist_cleanup_state(repo, work_package, cleared_worktree_attrs(), opts) do
      {:ok, result(updated_work_package, "stale_record_cleared", nil, nil, nil, repo_root)}
    end
  end

  defp persist_cleanup_state(repo, work_package, attrs, opts) do
    if Keyword.get(opts, :detached_cleanup, false) do
      {:ok, struct(work_package, attrs)}
    else
      Repository.update(repo, work_package.id, attrs)
    end
  end

  defp compact_worktree_owner?(%WorkPackage{} = work_package, repo_root, worktree_path) do
    recorded_target_repo_root_matches?(work_package, repo_root) or
      WorktreeTargetRoot.target_root_matches_worktree?(repo_root, work_package, worktree_path)
  end

  defp recorded_target_repo_root_matches?(%WorkPackage{worktree_target_repo_root: target_repo_root}, repo_root) when is_binary(target_repo_root) do
    same_path?(target_repo_root, repo_root)
  end

  defp recorded_target_repo_root_matches?(%WorkPackage{}, _repo_root), do: false

  defp recorded_target_repo_root_opts(opts, %WorkPackage{worktree_target_repo_root: target_repo_root}) when is_binary(target_repo_root) do
    if Keyword.has_key?(opts, :target_repo_root) or Keyword.has_key?(opts, :repo_root) do
      opts
    else
      Keyword.put(opts, :target_repo_root, target_repo_root)
    end
  end

  defp recorded_target_repo_root_opts(opts, %WorkPackage{}), do: opts

  defp cleared_worktree_attrs,
    do: %{worktree_path: nil, worktree_target_repo_root: nil, worktree_cleanup_proof: nil}

  defp cleanup_recorded_target_repo_root_opts(_repo, %WorkPackage{worktree_target_repo_root: target_repo_root} = work_package, opts, _worktree_path)
       when is_binary(target_repo_root) do
    {:ok, work_package, opts}
  end

  defp cleanup_recorded_target_repo_root_opts(repo, %WorkPackage{} = work_package, opts, worktree_path) do
    if Keyword.has_key?(opts, :target_repo_root) or Keyword.has_key?(opts, :repo_root) do
      {:ok, work_package, opts}
    else
      target_repo_root = WorktreeTargetRoot.from_package(work_package, worktree_path)
      backfill_recorded_target_repo_root(repo, work_package, opts, target_repo_root)
    end
  end

  defp backfill_recorded_target_repo_root(repo, work_package, opts, {:ok, repo_root}) do
    with {:ok, work_package} <- ensure_recorded_target_repo_root(repo, work_package, repo_root) do
      {:ok, work_package, Keyword.put(opts, :target_repo_root, repo_root)}
    end
  end

  defp backfill_recorded_target_repo_root(_repo, work_package, opts, _result), do: {:ok, work_package, opts}

  defp cleanup_validation_target_repo_root_opts(%WorkPackage{worktree_target_repo_root: target_repo_root}, opts, _worktree_path)
       when is_binary(target_repo_root) do
    {:ok, recorded_target_repo_root_opts(opts, %WorkPackage{worktree_target_repo_root: target_repo_root})}
  end

  defp cleanup_validation_target_repo_root_opts(%WorkPackage{} = work_package, opts, worktree_path) do
    if Keyword.has_key?(opts, :target_repo_root) or Keyword.has_key?(opts, :repo_root) do
      {:ok, opts}
    else
      case WorktreeTargetRoot.from_package(work_package, worktree_path) do
        {:ok, repo_root} -> {:ok, Keyword.put(opts, :target_repo_root, repo_root)}
        _result -> {:ok, opts}
      end
    end
  end

  defp git_common_dir(path, opts) do
    with {:ok, common_dir} <- git_output(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"], opts),
         common_dir <- common_dir |> String.trim() |> first_line() do
      canonicalize(common_dir)
    end
  end

  defp require_git_worktree(worktree_path, expected_repo_root, opts) do
    with {:ok, inside_worktree} <- git_output(worktree_path, ["rev-parse", "--is-inside-work-tree"], opts),
         true <- String.trim(inside_worktree) == "true",
         {:ok, worktree_common_dir} <- git_common_dir(worktree_path, opts),
         {:ok, expected_common_dir} <- git_common_dir(expected_repo_root, opts),
         true <- same_path?(worktree_common_dir, expected_common_dir) do
      :ok
    else
      false -> {:error, :invalid_worktree_path}
      {:error, _reason} -> {:error, :invalid_worktree_path}
    end
  end

  defp require_recorded_worktree_owner(repo_root, worktree_path, opts) do
    with {:ok, output} <- git_output(repo_root, ["worktree", "list", "--porcelain"], opts) do
      if worktree_list_includes?(output, worktree_path) do
        :ok
      else
        {:error, :invalid_worktree_path}
      end
    end
  end

  defp require_missing_recorded_worktree_owner(repo_root, worktree_path, opts, compact_owner?) do
    with {:ok, output} <- git_output(repo_root, ["worktree", "list", "--porcelain"], opts) do
      known_managed_path? =
        WorktreePath.managed_path_matches_repo_hash?(repo_root, worktree_path) or
          compact_owner?

      if worktree_list_includes?(output, worktree_path) or known_managed_path? do
        :ok
      else
        {:error, :invalid_worktree_path}
      end
    end
  end

  defp worktree_list_includes?(output, expected_path) do
    output
    |> String.split(~r/\R/)
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> Enum.any?(fn "worktree " <> path -> WorktreePath.same_existing_path?(path, expected_path) end)
  end

  defp replayable_managed_prepare_path?(%WorkPackage{} = work_package, repo_root, branch, recorded_path, worktree_parent) do
    inside_root?(recorded_path, worktree_parent) and
      Enum.any?(replayable_legacy_worktree_paths(work_package, repo_root, branch, worktree_parent), &same_path?(recorded_path, &1))
  end

  defp replayable_legacy_worktree_paths(%WorkPackage{} = work_package, repo_root, branch, worktree_parent) do
    legacy_paths =
      [
        previous_compact_worktree_path(work_package, repo_root, branch, worktree_parent),
        legacy_worktree_path(work_package, repo_root, branch, worktree_parent),
        previous_worktree_path(work_package, repo_root, branch, worktree_parent)
      ]
      |> Enum.flat_map(fn
        {:ok, path} -> [path]
        {:error, _reason} -> []
      end)

    current_worktree_paths(work_package, repo_root, branch, worktree_parent) ++ legacy_paths
  end

  defp current_worktree_paths(%WorkPackage{} = work_package, repo_root, branch, worktree_parent) do
    case WorktreePath.collision_worktree_leaves(repo_root, work_package.id, branch) do
      {:ok, leaves} -> Enum.flat_map(leaves, &current_worktree_path(&1, worktree_parent))
      {:error, _reason} -> []
    end
  end

  defp current_worktree_path({leaf, _length}, worktree_parent) do
    candidate = Path.join(worktree_parent, leaf)

    with {:ok, candidate} <- canonicalize(candidate),
         :ok <- require_inside_root(candidate, worktree_parent) do
      [candidate]
    else
      _result -> []
    end
  end

  defp previous_compact_worktree_path(%WorkPackage{} = work_package, repo_root, branch, worktree_parent) do
    with {:ok, branch_segment} <- WorktreePath.previous_compact_unique_segment(branch, branch),
         {:ok, package_segment} <- WorktreePath.previous_compact_unique_segment(work_package.id, work_package.id),
         {:ok, repo_segment} <- WorktreePath.previous_compact_unique_segment(Path.basename(repo_root), repo_root),
         candidate <- Path.join([worktree_parent, repo_segment, "#{package_segment}_#{branch_segment}"]),
         {:ok, candidate} <- canonicalize(candidate),
         :ok <- require_inside_root(candidate, worktree_parent) do
      {:ok, candidate}
    end
  end

  defp legacy_worktree_path(%WorkPackage{} = work_package, repo_root, branch, worktree_parent) do
    with {:ok, branch_segment} <- WorktreePath.legacy_unique_segment(branch, branch),
         {:ok, package_segment} <- WorktreePath.safe_segment(work_package.id),
         {:ok, repo_segment} <- WorktreePath.legacy_unique_segment(Path.basename(repo_root), repo_root),
         candidate <- Path.join([worktree_parent, repo_segment, "#{package_segment}-#{branch_segment}"]),
         {:ok, candidate} <- canonicalize(candidate),
         :ok <- require_inside_root(candidate, worktree_parent) do
      {:ok, candidate}
    end
  end

  defp previous_worktree_path(%WorkPackage{} = work_package, repo_root, branch, worktree_parent) do
    with {:ok, branch_segment} <- WorktreePath.previous_unique_segment(branch, branch),
         {:ok, package_segment} <- WorktreePath.previous_unique_segment(work_package.id, work_package.id),
         {:ok, repo_segment} <- WorktreePath.previous_unique_segment(Path.basename(repo_root), repo_root),
         candidate <- Path.join([worktree_parent, repo_segment, "#{package_segment}-#{branch_segment}"]),
         {:ok, candidate} <- canonicalize(candidate),
         :ok <- require_inside_root(candidate, worktree_parent) do
      {:ok, candidate}
    end
  end

  defp fetch_remote_base(repo_root, base_branch, opts) do
    git(repo_root, ["fetch", "origin", "+refs/heads/#{base_branch}:refs/remotes/origin/#{base_branch}"], opts)
  end

  defp cleanup_repo_root(opts) do
    case Keyword.get(opts, :target_repo_root) || Keyword.get(opts, :repo_root) do
      repo_root when is_binary(repo_root) ->
        with {:ok, repo_root} <- canonicalize(repo_root),
             true <- File.dir?(repo_root) do
          {:ok, repo_root}
        else
          false -> {:error, :invalid_target_repo_root}
          {:error, _reason} = error -> error
        end

      _repo_root ->
        {:error, :invalid_target_repo_root}
    end
  end

  defp required_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: :error, else: {:ok, value}

      _other ->
        :error
    end
  end

  defp optional_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        {:ok, if(value == "", do: nil, else: value)}

      {:ok, nil} ->
        {:ok, nil}

      :error ->
        {:ok, nil}

      _other ->
        :error
    end
  end

  defp require_inside_root(path, root) do
    if inside_root?(path, root), do: :ok, else: {:error, :unsafe_worktree_path}
  end

  defp inside_root?(path, root) do
    path = comparable_path(path)
    root = comparable_path(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp same_path?(left, right), do: comparable_path(left) == comparable_path(right)

  defp cleanup_proof_matches?(%WorkPackage{worktree_cleanup_proof: proof} = work_package, worktree_path, repo_root)
       when is_binary(proof) do
    proof == cleanup_proof(work_package, worktree_path, repo_root)
  end

  defp cleanup_proof_matches?(%WorkPackage{}, _worktree_path, _repo_root), do: false

  defp cleanup_proof(%WorkPackage{} = work_package, worktree_path, repo_root) do
    ["v1" | Enum.map([work_package.worktree_path, worktree_path, repo_root], &comparable_path/1)]
    |> Enum.intersperse(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp cleanup_obligation_target_root(%WorkPackage{worktree_target_repo_root: target_repo_root}, _worktree_path)
       when is_binary(target_repo_root), do: canonicalize(target_repo_root)

  defp cleanup_obligation_target_root(%WorkPackage{} = work_package, worktree_path) do
    case WorktreeTargetRoot.from_package(work_package, worktree_path) do
      {:ok, target_repo_root} -> canonicalize(target_repo_root)
      :error -> {:error, :invalid_target_repo_root}
    end
  end

  defp comparable_path(path) do
    path =
      path
      |> Path.expand()
      |> String.replace("\\", "/")
      |> String.trim_trailing("/")

    if match?({:win32, _name}, :os.type()), do: String.downcase(path), else: path
  end

  defp codex_home(opts) do
    opts[:codex_home] || System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")
  end

  defp canonicalize(path), do: PathSafety.canonicalize(path)

  defp git(repo_root, args, opts) do
    case git_output(repo_root, args, opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_revision(repo_root, ref, opts) do
    with {:ok, output} <- git_output(repo_root, ["rev-parse", "--verify", ref], opts) do
      {:ok, output |> String.trim() |> first_line()}
    end
  end

  defp git_output(repo_root, args, opts) do
    with {:ok, git} <- git_executable(opts) do
      {output, status} = run_git(git, repo_root, args)

      if status == 0 do
        {:ok, output}
      else
        {:error, {:git_failed, status, git_failure(status, repo_root, args, output, opts)}}
      end
    end
  end

  defp run_git(git, repo_root, args) when is_function(git, 2), do: git.(repo_root, args)
  defp run_git(git, repo_root, args), do: System.cmd(git, ["-C", repo_root | args], stderr_to_stdout: true)

  defp git_context_opts(opts, target_repo_root, worktree_path, branch, base_branch) do
    Keyword.put(opts, :git_context, %{
      target_repo_root: target_repo_root,
      worktree_path: worktree_path,
      branch: branch,
      base_branch: base_branch
    })
  end

  defp cleanup_context_opts(opts, worktree_path) do
    Keyword.put(opts, :git_context, %{
      worktree_path: worktree_path
    })
  end

  defp cleanup_context_opts(opts, target_repo_root, worktree_path) do
    Keyword.put(opts, :git_context, %{
      target_repo_root: target_repo_root,
      worktree_path: worktree_path
    })
  end

  defp cleanup_removal_context_opts(opts, work_package, worktree_path, target_repo_root) do
    Keyword.put(opts, :git_context, %{
      target_repo_root: target_repo_root,
      worktree_path: worktree_path,
      recorded_worktree_path: work_package.worktree_path,
      resolved_worktree_path: worktree_path,
      stage: "git_worktree_remove",
      rule: "durable_preflight_proof"
    })
  end

  defp git_failure(status, repo_root, args, output, opts) do
    context = Keyword.get(opts, :git_context, %{})
    target_repo_root = Map.get(context, :target_repo_root, repo_root)
    worktree_path = Map.get(context, :worktree_path)
    paths = [repo_root, target_repo_root, worktree_path] |> Enum.filter(&is_binary/1) |> Enum.uniq()

    %{
      status: status,
      stderr: sanitize_git_text(output, paths),
      target_repo_root: sanitize_path(target_repo_root),
      worktree_path: sanitize_optional_path(worktree_path),
      recorded_worktree_path: sanitize_optional_path(Map.get(context, :recorded_worktree_path)),
      resolved_worktree_path: sanitize_optional_path(Map.get(context, :resolved_worktree_path)),
      stage: Map.get(context, :stage),
      rule: Map.get(context, :rule),
      branch: sanitize_optional_git_text(Map.get(context, :branch), paths),
      base_branch: sanitize_optional_git_text(Map.get(context, :base_branch), paths),
      git_args: Enum.map(args, &sanitize_git_text(&1, paths))
    }
  end

  defp sanitize_optional_git_text(nil, _paths), do: nil
  defp sanitize_optional_git_text(value, paths), do: sanitize_git_text(value, paths)

  defp sanitize_git_text(value, paths) when is_binary(value) do
    paths
    |> Enum.reduce(value, fn path, output -> String.replace(output, path, sanitize_path(path)) end)
    |> Redactor.redact_text()
    |> String.slice(0, 4_000)
  end

  defp sanitize_optional_path(nil), do: nil
  defp sanitize_optional_path(path), do: sanitize_path(path)

  defp sanitize_path(path) when is_binary(path) do
    redacted_path = Redactor.redact_text(path)

    if Enum.any?(Path.split(redacted_path), &sensitive_path_segment?/1) do
      "[REDACTED]"
    else
      redacted_path
    end
  end

  defp sensitive_path_segment?(segment) do
    Regex.match?(~r/(secret|token|password|credential|bearer|api[-_]?key)/i, segment)
  end

  defp git_executable(opts) do
    cond do
      is_function(opts[:git], 2) -> {:ok, opts[:git]}
      is_binary(opts[:git]) -> {:ok, opts[:git]}
      git = System.find_executable("git") -> {:ok, git}
      true -> {:error, :git_not_found}
    end
  end

  defp first_line(value) do
    value
    |> String.split(~r/\R/, parts: 2)
    |> hd()
  end

  defp result(work_package, status, worktree_path, branch, base_branch, repo_root) do
    %{
      work_package: work_package,
      status: status,
      worktree_path: worktree_path,
      branch: branch,
      base_branch: base_branch,
      repo_root: repo_root,
      target_repo_root: repo_root
    }
  end
end
