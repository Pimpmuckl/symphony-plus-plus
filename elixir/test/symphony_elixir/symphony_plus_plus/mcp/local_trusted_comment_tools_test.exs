Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.LocalTrustedCommentToolsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "trusted local sessions list comments for existing local targets only", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-MCP-LOCAL-OPERATOR-COMMENT-LIST",
        repo: "nextide/symphony-plus-plus",
        base_branch: "feature/sympp-v21-ledger-claims"
      )

    local_server = local_mcp_server(local_mcp_config(repo), "local-operator-comment-list-state")

    {comment_response, note_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-comment",
          "method" => "tools/call",
          "params" => %{
            "name" => "add_work_request_comment",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "body" => "Coordinate before slicing",
              "created_by" => "operator"
            }
          }
        },
        local_server
      )

    assert comment_id = get_in(comment_response, ["result", "structuredContent", "comment", "id"])

    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-MCP-LOCAL-OPERATOR-COMMENT-LIST", kind: "mcp"))

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(id: "WRS-MCP-LOCAL-OPERATOR-COMMENT-LIST", base_branch: work_request.base_branch)
             )

    assert {:ok, package_comment} =
             CommentService.create(repo, %{
               "target_kind" => "work_package",
               "target_id" => package.id,
               "body" => "Package note",
               "source_type" => "operator",
               "author_name" => "operator"
             })

    assert {:ok, work_package_comment} =
             CommentService.create(repo, %{
               "target_kind" => "work_package",
               "target_id" => work_package.id,
               "body" => "WorkPackage note",
               "source_type" => "operator",
               "author_name" => "operator"
             })

    list_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-list-comments",
          "method" => "tools/call",
          "params" => %{
            "name" => "list_comments",
            "arguments" => %{"target_kind" => "work_request", "target_id" => work_request.id}
          }
        },
        note_server
      )

    assert [%{"id" => ^comment_id}] = get_in(list_response, ["result", "structuredContent", "comments"])

    package_list_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-list-package-comments",
          "method" => "tools/call",
          "params" => %{
            "name" => "list_comments",
            "arguments" => %{"target_kind" => "work_package", "target_id" => package.id}
          }
        },
        note_server
      )

    assert [%{"id" => package_comment_id}] = get_in(package_list_response, ["result", "structuredContent", "comments"])
    assert package_comment_id == package_comment.id

    work_package_list_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-list-work-package-comments",
          "method" => "tools/call",
          "params" => %{
            "name" => "list_comments",
            "arguments" => %{"target_kind" => "work_package", "target_id" => work_package.id}
          }
        },
        note_server
      )

    assert [%{"id" => work_package_comment_id}] = get_in(work_package_list_response, ["result", "structuredContent", "comments"])
    assert work_package_comment_id == work_package_comment.id

    missing_list_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-list-missing-comments",
          "method" => "tools/call",
          "params" => %{
            "name" => "list_comments",
            "arguments" => %{"target_kind" => "work_request", "target_id" => "WR-MCP-LOCAL-OPERATOR-MISSING"}
          }
        },
        note_server
      )

    assert get_in(missing_list_response, ["error", "code"]) == -32_004
    assert get_in(missing_list_response, ["error", "data", "tool"]) == "list_comments"
    assert get_in(missing_list_response, ["error", "data", "reason"]) == "not_found"
  end

  test "trusted local comments remain unavailable outside local MCP", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-COMMENT-LIST-DENIED")

    stdio_list_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stdio-local-operator-list-comments",
          "method" => "tools/call",
          "params" => %{
            "name" => "list_comments",
            "arguments" => %{"target_kind" => "work_request", "target_id" => work_request.id}
          }
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(stdio_list_response, ["error", "code"]) == -32_001
    assert get_in(stdio_list_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(stdio_list_response, ["error", "data", "action"]) == "claim_local_architect_assignment"
  end

  test "local operator WorkRequest note tools work from bound worker sessions", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-BOUND")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-LOCAL-OPERATOR-BOUND", kind: "mcp", status: "active")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    worker_server = %{
      local_mcp_server(local_mcp_config(repo), "local-operator-worker-bound-state")
      | session: MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)
    }

    worker_tools =
      worker_server
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(worker_tools, "add_work_request_comment")
    assert Map.has_key?(worker_tools, "record_work_request_operator_decision")
    assert Map.has_key?(worker_tools, "create_work_request")
    assert Map.has_key?(worker_tools, "list_comments")

    assert {:ok, other_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-LOCAL-OPERATOR-BOUND-OTHER", kind: "mcp"))

    assert {:ok, _foreign_comment} =
             CommentService.create(repo, %{
               "target_kind" => "work_package",
               "target_id" => other_package.id,
               "body" => "foreign local note",
               "source_type" => "operator",
               "author_name" => "operator"
             })

    out_of_scope_list_response = list_package_comments(worker_server, package.id, other_package.id, "local-operator-bound-list-foreign")
    assert get_in(out_of_scope_list_response, ["error", "data", "reason"]) == "outside_session_scope"

    stale_bound_list_response =
      worker_server
      |> Map.put(:state_key, "local-operator-worker-stale-state")
      |> Map.put(:session_refresh_required, true)
      |> list_package_comments(package.id, other_package.id, "local-operator-stale-bound-list-foreign")

    assert get_in(stale_bound_list_response, ["error", "data", "reason"]) == "outside_session_scope"

    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-bound-denied",
          "method" => "tools/call",
          "params" => %{
            "name" => "add_work_request_comment",
            "arguments" => %{"work_request_id" => work_request.id, "body" => "safe note"}
          }
        },
        worker_server
      )

    assert get_in(response, ["result", "structuredContent", "comment", "target_id"]) == work_request.id
    assert get_in(response, ["result", "structuredContent", "comment", "source_type"]) == "operator"
    assert get_in(response, ["result", "structuredContent", "comment", "author_name"]) == "worker-1"

    decision_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-bound-decision",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_work_request_operator_decision",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "decision" => "Bound local sessions may still add operator notes.",
              "rationale" => "The explicit local daemon state is the trust boundary.",
              "scope_impact" => "No worker assignment scope is widened."
            }
          }
        },
        worker_server
      )

    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "source_type"]) == "operator"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "created_by"]) == "worker-1"

    create_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-bound-create-work-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "create_work_request",
            "arguments" => %{
              "repo" => "nextide/symphony-plus-plus",
              "base_branch" => "main",
              "title" => "Bound local session WorkRequest",
              "description" => "Create a WorkRequest from a bound trusted local MCP session.",
              "request_kind" => "investigation"
            }
          }
        },
        worker_server
      )

    assert get_in(create_response, ["result", "structuredContent", "status"]) == "created"
    assert get_in(create_response, ["result", "structuredContent", "work_request", "title"]) == "Bound local session WorkRequest"
  end

  test "local operator WorkRequest note tools reject uninitialized sessions and tolerate stale bindings", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-SESSION-DENIED")
    arguments = %{"work_request_id" => work_request.id, "body" => "safe note", "created_by" => "operator"}

    pre_initialize_server =
      Server.new(local_mcp_config(repo), local_daemon_trusted: true, state_key: "local-operator-pre-init-state")

    pre_initialize_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-pre-init-denied",
          "method" => "tools/call",
          "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
        },
        pre_initialize_server
      )

    assert get_in(pre_initialize_response, ["error", "code"]) == -32_000
    assert get_in(pre_initialize_response, ["error", "data", "reason"]) == "server_not_initialized"

    refresh_required_server = %{local_mcp_server(local_mcp_config(repo), "local-operator-refresh-state") | session_refresh_required: true}

    refresh_required_tools =
      refresh_required_server
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(refresh_required_tools, "get_current_assignment")
    assert Map.has_key?(refresh_required_tools, "claim_local_assignment")
    assert Map.has_key?(refresh_required_tools, "claim_local_architect_assignment")
    assert Map.has_key?(refresh_required_tools, "add_work_request_comment")
    assert Map.has_key?(refresh_required_tools, "record_work_request_operator_decision")
    assert Map.has_key?(refresh_required_tools, "create_work_request")
    assert Map.has_key?(refresh_required_tools, "list_comments")

    refresh_required_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-refresh-denied",
          "method" => "tools/call",
          "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
        },
        refresh_required_server
      )

    assert get_in(refresh_required_response, ["result", "structuredContent", "comment", "target_id"]) == work_request.id
    assert get_in(refresh_required_response, ["result", "structuredContent", "comment", "source_type"]) == "operator"
  end

  defp list_package_comments(server, work_package_id, target_id, request_id) do
    Server.handle(
      %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "tools/call",
        "params" => %{
          "name" => "list_comments",
          "arguments" => %{"work_package_id" => work_package_id, "target_kind" => "work_package", "target_id" => target_id}
        }
      },
      server
    )
  end
end
