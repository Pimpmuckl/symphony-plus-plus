Code.require_file("mcp_common_helpers.exs", __DIR__)
Code.require_file("mcp_session_helpers.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPCase.HandoffHelpers do
  @moduledoc false

  import ExUnit.Assertions
  import SymphonyElixir.SymphonyPlusPlus.MCPCase.CommonHelpers
  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  @handoff_store_process_key :sympp_mcp_test_handoff_store_dir

  def windows? do
    case :os.type() do
      {:win32, _name} -> true
      _type -> false
    end
  end

  def test_handoff_store_dir do
    case Process.get(@handoff_store_process_key) do
      nil -> raise "MCP test handoff store directory was not initialized"
      store_dir -> store_dir
    end
  end

  def unique_test_handoff_store_dir do
    System.tmp_dir!()
    |> Path.join("sympp-mcp-test-worker-secrets-#{System.unique_integer([:positive])}")
    |> Path.expand()
  end

  def temporary_worker_repo_root(name) do
    System.tmp_dir!()
    |> Path.join("sympp-mcp-#{name}-#{System.unique_integer([:positive])}")
    |> tap(&File.mkdir_p!/1)
  end

  def comparable_path(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> then(fn path -> if windows?(), do: String.downcase(path), else: path end)
  end

  def solo_workspace_path(name) do
    path = Path.join(System.tmp_dir!(), "sympp-mcp-solo-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  def test_dispatch_handoff_store_dir do
    test_handoff_store_dir()
    |> Path.join("dispatch-#{System.unique_integer([:positive])}")
  end

  def test_handoff_opts(claimed_by, store_dir \\ test_handoff_store_dir()) do
    [
      claimed_by: claimed_by,
      store_dir: store_dir
    ]
  end

  def sqlite_file_uri(path, query) do
    encoded_path =
      path
      |> String.replace("\\", "/")
      |> URI.encode(&sqlite_file_uri_path_char?/1)

    "file:#{encoded_path}?#{query}"
  end

  def assert_same_ledger_database(%{"database" => actual_database}, expected_path, expected_query \\ nil) do
    actual_path =
      case Repo.sqlite_file_uri_path(actual_database) do
        path when is_binary(path) and path != "" -> path
        _path -> actual_database
      end

    assert Repo.same_database_path?(actual_path, expected_path)

    if expected_query do
      assert actual_database =~ "?#{expected_query}"
    end
  end

  def sqlite_file_uri_path_char?(char), do: URI.char_unreserved?(char) or char in [?/, ?:]

  def current_main_database_path(repo) do
    assert {:ok, %{rows: rows}} = SQL.query(repo, "PRAGMA database_list", [], log: false)

    case Enum.find(rows, &main_database_row?/1) do
      [_seq, "main", path] when is_binary(path) and path != "" -> path
      row -> flunk("expected file-backed test ledger for external MCP bootstrap, got: #{inspect(row)}")
    end
  end

  def restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  def restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  def json_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
