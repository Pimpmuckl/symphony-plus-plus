defmodule SymppV3Preview do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @node_ids %{
    root: "ptn_v3_product_tree_cockpit",
    docs: "ptn_v3_contract_and_cutover",
    backend: "ptn_v3_backend_foundation",
    cockpit: "ptn_v3_cockpit_ui",
    cutover: "ptn_v3_preview_cutover"
  }

  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          source: :string,
          target: :string,
          seed_work_request: :string
        ]
      )

    if invalid != [], do: raise("invalid options: #{inspect(invalid)}")

    source = Keyword.get_lazy(opts, :source, &default_source/0)
    target = Keyword.get_lazy(opts, :target, &default_target/0)

    snapshot_database!(source, target)
    start_repo!(target)
    migrate!()
    maybe_seed_work_request(Keyword.get(opts, :seed_work_request))

    IO.puts("preview_database=#{target}")
  end

  defp default_source do
    Path.expand("~/.agents/splusplus/symphony_plus_plus.sqlite3")
  end

  defp default_target do
    Path.expand("../tmp/v3-preview/symphony_plus_plus_v3_preview.sqlite3", File.cwd!())
  end

  defp snapshot_database!(source, target) do
    source = Path.expand(source)
    target = Path.expand(target)

    unless File.exists?(source), do: raise("source database does not exist: #{source}")

    File.mkdir_p!(Path.dirname(target))

    Enum.each([target, target <> "-wal", target <> "-shm"], fn path ->
      if File.exists?(path), do: File.rm!(path)
    end)

    {:ok, connection} = Exqlite.Sqlite3.open(source)

    try do
      :ok = Exqlite.Sqlite3.execute(connection, "VACUUM INTO '#{sqlite_string(target)}'")
    after
      :ok = Exqlite.Sqlite3.close(connection)
    end
  end

  defp sqlite_string(value), do: String.replace(value, "'", "''")

  defp start_repo!(target) do
    Application.put_env(:symphony_elixir, :sympp_repo_database, target)

    {:ok, pid} = Repo.start_link(database: target, name: Repo.process_name(target), pool_size: 1, log: false)
    Repo.put_dynamic_repo(pid)
  end

  defp migrate! do
    case WorkRequestRepository.migrate(Repo) do
      :ok -> :ok
      {:error, reason} -> raise("preview database migration failed: #{inspect(reason)}")
    end
  end

  defp maybe_seed_work_request(nil), do: :ok

  defp maybe_seed_work_request(work_request_id) do
    with {:ok, work_request} <- WorkRequestRepository.get(Repo, work_request_id),
         {:ok, work_packages} <- WorkRequestRepository.list_work_packages(Repo, work_request_id) do
      seed_nodes!(work_request)
      seed_work_package_ownership!(work_request, work_packages)
      seed_dependencies!(work_request)
      seed_revision!(work_request)
    else
      {:error, :not_found} -> raise("seed WorkRequest not found in preview database: #{work_request_id}")
      {:error, reason} -> raise("seed WorkRequest read failed: #{inspect(reason)}")
    end
  end

  defp seed_nodes!(work_request) do
    [
      %{id: @node_ids.root, title: "V3 product-tree cockpit", completion_mark: "partial", position: 1},
      %{id: @node_ids.docs, parent_id: @node_ids.root, title: "Contract and cutover plan", completion_mark: "done", position: 1},
      %{id: @node_ids.backend, parent_id: @node_ids.root, title: "Backend product-tree foundation", completion_mark: "partial", position: 2},
      %{id: @node_ids.cockpit, parent_id: @node_ids.root, title: "Collapsed WR cockpit tree", completion_mark: "partial", position: 3},
      %{id: @node_ids.cutover, parent_id: @node_ids.root, title: "Copied-DB preview and cutover", completion_mark: "partial", position: 4}
    ]
    |> Enum.each(fn attrs ->
      {:ok, _node} =
        ProductTree.create_node(
          Repo,
          Map.merge(attrs, %{
            work_request_id: work_request.id,
            node_kind: "product_plan_node",
            created_by: "v3-preview-seed"
          })
        )
    end)
  end

  defp seed_work_package_ownership!(work_request, work_packages) do
    work_packages
    |> Enum.sort_by(&(&1.sequence || 0))
    |> Enum.each(fn work_package ->
      if node_id = node_id_for_work_package(work_package) do
        {:ok, _work_package} =
          WorkRequestRepository.update_work_package(
            Repo,
            work_request.id,
            work_package.id,
            work_package.contract_revision,
            %{"product_tree_node_id" => node_id}
          )
      end
    end)
  end

  defp node_id_for_work_package(work_package) do
    title = String.downcase(work_package.title || "")

    cond do
      String.contains?(title, "contract") -> @node_ids.docs
      String.contains?(title, "persistence") -> @node_ids.backend
      String.contains?(title, "projection") -> @node_ids.backend
      String.contains?(title, "cockpit") -> @node_ids.cockpit
      String.contains?(title, "preview") -> @node_ids.cutover
      true -> nil
    end
  end

  defp seed_dependencies!(work_request) do
    [
      {@node_ids.cockpit, @node_ids.backend, "Cockpit rendering depends on the backend product-tree projection payload."},
      {@node_ids.cutover, @node_ids.cockpit, "Preview and cutover depend on the cockpit tree being inspectable."}
    ]
    |> Enum.each(fn {source_id, target_id, reason} ->
      {:ok, _edge} =
        ProductTree.create_dependency_edge(Repo, %{
          work_request_id: work_request.id,
          source_kind: "product_node",
          source_id: source_id,
          target_kind: "product_node",
          target_id: target_id,
          kind: "depends_on",
          reason: reason,
          decision_ref: %{"source" => "v3-preview-seed"},
          created_by: "v3-preview-seed"
        })
    end)
  end

  defp seed_revision!(work_request) do
    {:ok, _revision} =
      ProductTree.record_revision(Repo, work_request.id, %{
        reason: "Seed v3 preview product tree for copied-database cockpit review.",
        tree_snapshot: %{"root_node_id" => @node_ids.root},
        decision_ref: %{"source" => "v3-preview-seed"},
        created_by: "v3-preview-seed"
      })
  end
end

SymppV3Preview.run(System.argv())
