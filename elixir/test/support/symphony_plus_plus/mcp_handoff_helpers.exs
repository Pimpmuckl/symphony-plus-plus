Code.require_file("mcp_common_helpers.exs", __DIR__)
Code.require_file("mcp_session_helpers.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPCase.HandoffHelpers do
  @moduledoc false

  import ExUnit.Assertions
  import SymphonyElixir.SymphonyPlusPlus.MCPCase.CommonHelpers
  import SymphonyElixir.SymphonyPlusPlus.MCPCase.SessionHelpers
  alias Ecto.Adapters.SQL
  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
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

  def claim_phase_child_worker(repo, architect_session, child_id) do
    mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => %{"claimed_by" => "worker-1"}
      })

    claim_child_worker_from_mint_response(repo, mint_response, "worker-1")
  end

  def claim_child_worker_from_mint_response(repo, mint_response, claimed_by) do
    worker_grant = get_in(mint_response, ["result", "structuredContent", "worker_grant"])
    bootstrap = Map.fetch!(worker_grant, "worker_bootstrap")
    claim = Map.fetch!(bootstrap, "claim")
    assert claim["tool"] == "claim_local_assignment"
    arguments = get_in(bootstrap, ["claim", "arguments"])
    assert arguments["claimed_by"] == claimed_by
    assert arguments["work_package_id"] == worker_grant["work_package_id"]
    refute Map.has_key?(arguments, "caller_id")

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-child-worker-from-bootstrap",
          "method" => "tools/call",
          "params" => %{"name" => claim["tool"], "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "child-worker-bootstrap-#{worker_grant["id"]}-#{System.unique_integer([:positive])}")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_id"]) == worker_grant["id"]
    claimed_server.session
  end

  def json_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end

  def renew_phase_architect_session(repo, anchor, capabilities, claimed_by \\ "architect-1") do
    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, anchor.phase_id,
               work_package_id: anchor.id,
               capabilities: capabilities
             )

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: claimed_by}, DateTime.utc_now(:microsecond))

    MCPHarness.session(architect_assignment, proof_hash: minted.grant.secret_hash)
  end

  def advance_child_worker_to_ci_waiting(repo, worker_session) do
    [
      {"ready_for_worker", "claimed"},
      {"claimed", "planning"},
      {"planning", "implementing"},
      {"implementing", "reviewing"},
      {"reviewing", "ci_waiting"}
    ]
    |> Enum.each(fn {expected_status, status} ->
      response =
        mcp_tool(repo, worker_session, "set_status", %{
          "expected_status" => expected_status,
          "status" => status,
          "reason" => "advance phase child test flow"
        })

      assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == status
    end)
  end

  def attach_phase_child_ready_evidence(repo, worker_session, child_id, head_sha) do
    append_done_plan(repo, child_id)
    attach_tool(repo, worker_session, "attach_branch", %{"branch" => "agent/#{child_id}/worker", "head_sha" => head_sha})
    attach_tool(repo, worker_session, "attach_pr", %{"url" => "https://github.com/nextide/symphony-plus-plus/pull/7003", "head_sha" => head_sha})

    attach_tool(repo, worker_session, "submit_review_package", ready_review_package_args(head_sha))
  end

  def ready_review_package_args(head_sha) do
    %{
      "summary" => "Ready for architect review",
      "tests" => ["mix test elixir/test/symphony_elixir/symphony_plus_plus/mcp"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true
    }
  end

  def create_child_work_package(repo, session, child_id) do
    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => child_id,
          "title" => "Implement #{child_id}",
          "acceptance_criteria" => ["Complete #{child_id}"]
        }
      })

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == child_id
    child_id
  end
end
