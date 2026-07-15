Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestListPaginationTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  defmodule QueryProbe do
    def handle(_event, _measurements, metadata, test_pid), do: send(test_pid, {:list_query, to_string(metadata.query || "")})
  end

  test "list_work_requests defaults to 50 rows and rejects invalid bounds", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PAGE-DEFAULT", ["read:work_request"])

    for index <- 1..51 do
      create_work_request!(repo,
        id: "WR-MCP-PAGE-DEFAULT-#{String.pad_leading(Integer.to_string(index), 3, "0")}",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )
    end

    payload =
      repo
      |> mcp_tool(session, "list_work_requests", %{"status" => "ready_for_slicing"})
      |> get_in(["result", "structuredContent"])

    assert payload["limit"] == 50
    assert payload["total_count"] == 50
    assert length(payload["work_requests"]) == 50
    assert is_binary(payload["next_cursor"])

    over_max = mcp_tool(repo, session, "list_work_requests", %{"limit" => 201})
    assert get_in(over_max, ["error", "data", "reason"]) == "limit_exceeds_maximum"

    invalid_cursor = mcp_tool(repo, session, "list_work_requests", %{"cursor" => "not-a-cursor"})
    assert get_in(invalid_cursor, ["error", "data", "reason"]) == "invalid_cursor"
  end

  test "list_work_requests pages stable authorized status matches with one batched scope query", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PAGE-SCOPED", ["read:work_request"])

    ready =
      for index <- 1..10 do
        create_work_request!(repo,
          id: "WR-MCP-PAGE-SCOPED-#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          repo: anchor.repo,
          base_branch: anchor.base_branch,
          status: "ready_for_slicing"
        )
      end

    _draft =
      create_work_request!(repo,
        id: "WR-MCP-PAGE-SCOPED-DRAFT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "draft"
      )

    visible = Enum.take_every(ready, 2)
    Enum.each(visible, &grant_work_request_scope!(repo, session, &1.id))
    remove_grant_scope_type!(repo, session, "repo")

    handler_id = {__MODULE__, self(), make_ref()}
    event = repo.config()[:telemetry_prefix] ++ [:query]
    :ok = :telemetry.attach(handler_id, event, &QueryProbe.handle/4, self())

    first = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing", "limit" => 2})
    :telemetry.detach(handler_id)
    first_payload = get_in(first, ["result", "structuredContent"])
    queries = drain_queries([])

    second =
      mcp_tool(repo, session, "list_work_requests", %{
        "status" => "ready_for_slicing",
        "limit" => 2,
        "cursor" => first_payload["next_cursor"]
      })

    second_payload = get_in(second, ["result", "structuredContent"])

    third =
      mcp_tool(repo, session, "list_work_requests", %{
        "status" => "ready_for_slicing",
        "limit" => 2,
        "cursor" => second_payload["next_cursor"]
      })

    third_payload = get_in(third, ["result", "structuredContent"])

    listed =
      [first_payload, second_payload, third_payload]
      |> Enum.flat_map(& &1["work_requests"])
      |> Enum.map(& &1["id"])

    assert listed == Enum.map(visible, & &1.id)
    assert length(listed) == length(Enum.uniq(listed))
    refute Map.has_key?(third_payload, "next_cursor")

    assert Enum.count(queries, &String.contains?(&1, "FROM \"sympp_work_request_repo_scopes\"")) == 1
    assert length(queries) < 25
  end

  test "sparse authorization returns a bounded continuation without skipping visible rows", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PAGE-SPARSE", ["read:work_request"])

    work_requests =
      for index <- 1..1_100 do
        create_work_request!(repo,
          id: "WR-MCP-PAGE-SPARSE-#{String.pad_leading(Integer.to_string(index), 4, "0")}",
          repo: anchor.repo,
          base_branch: anchor.base_branch,
          status: "ready_for_slicing"
        )
      end

    visible = List.last(work_requests)
    grant_work_request_scope!(repo, session, visible.id)
    remove_grant_scope_type!(repo, session, "repo")

    handler_id = {__MODULE__, self(), make_ref()}
    event = repo.config()[:telemetry_prefix] ++ [:query]
    :ok = :telemetry.attach(handler_id, event, &QueryProbe.handle/4, self())

    first = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing", "limit" => 1})
    :telemetry.detach(handler_id)
    first_payload = get_in(first, ["result", "structuredContent"])
    queries = drain_queries([])

    assert first_payload["work_requests"] == []
    assert is_binary(first_payload["next_cursor"])
    assert length(queries) < 25

    second =
      mcp_tool(repo, session, "list_work_requests", %{
        "status" => "ready_for_slicing",
        "limit" => 1,
        "cursor" => first_payload["next_cursor"]
      })

    second_payload = get_in(second, ["result", "structuredContent"])
    assert Enum.map(second_payload["work_requests"], & &1["id"]) == [visible.id]
    refute Map.has_key?(second_payload, "next_cursor")
  end

  defp drain_queries(queries) do
    receive do
      {:list_query, query} -> drain_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
