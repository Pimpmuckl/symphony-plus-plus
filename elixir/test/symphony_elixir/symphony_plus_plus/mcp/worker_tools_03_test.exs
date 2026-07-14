Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles

  test "mark_ready enforces worker readiness gates", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-GATES", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    append_done_plan(repo, package.id)

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(missing_response, ["error", "data", "reason"]) == "readiness_failed"
    assert "pr_attached" in get_in(missing_response, ["error", "data", "missing"])
    refute Enum.any?(get_in(missing_response, ["error", "data", "reasons"]), &(&1["gate"] == "plan_complete"))

    bypass_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ready-bypass",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "ready_for_merge", "expected_status" => "ci_waiting"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(bypass_response, ["error", "data", "reason"]) == "use_mark_ready"
    assert {:ok, unchanged_package} = WorkPackageRepository.get(repo, package.id)
    assert unchanged_package.status == "ci_waiting"

    attach_tool(repo, session, "append_progress", %{"summary" => "Shared key baseline", "idempotency_key" => "shared-metadata-key"})

    missing_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "missing-pr-head",
          "method" => "tools/call",
          "params" => %{"name" => "attach_pr", "arguments" => %{"url" => "https://github.com/example/repo/pull/123"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_head_response, ["error", "data", "reason"]) == "missing_head_sha"

    pre_metadata_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-metadata-headless-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Headless review before metadata",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(pre_metadata_review_response, ["error", "data", "reason"]) == "missing_current_head_sha"

    pre_branch_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-branch-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Review before branch head",
              "tests" => ["mix test"],
              "artifacts" => ["pre-branch-review-log.txt"],
              "head_sha" => "abc123",
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(pre_branch_review_response, ["error", "data", "reason"]) == "missing_current_head_sha"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-GATES/worker", "head_sha" => " abc123 ", "idempotency_key" => "shared-metadata-key"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/123", "head_sha" => " abc123 "})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/123", "abc123")

    headless_review_args = %{
      "summary" => "Headless review",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "reviews" => []
    }

    headless_review_response = attach_tool(repo, session, "submit_review_package", headless_review_args)

    assert response_progress_payload(repo, headless_review_response)["head_sha"] == "abc123"

    missing_acceptance_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-acceptance", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "acceptance_criteria_met" in get_in(missing_acceptance_response, ["error", "data", "missing"])

    trimmed_review_response =
      attach_tool(repo, session, "submit_review_package", %{
        "summary" => "Trimmed review values",
        "tests" => [" mix test "],
        "artifacts" => [" review-log.txt "],
        "head_sha" => " abc123 ",
        "reviews" => []
      })

    trimmed_review_payload = response_progress_payload(repo, trimmed_review_response)
    assert trimmed_review_payload["tests"] == ["mix test"]
    assert trimmed_review_payload["artifacts"] == ["review-log.txt"]

    explicit_key_review_args = %{
      "summary" => "Explicit idempotency key review",
      "tests" => ["mix test"],
      "artifacts" => ["explicit-key-review.txt"],
      "head_sha" => "abc123",
      "idempotency_key" => "explicit-key-review",
      "reviews" => []
    }

    attach_tool(repo, session, "submit_review_package", explicit_key_review_args)

    assert {:ok, trimmed_artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    assert Enum.any?(trimmed_artifacts, &(&1.path == "review-log.txt"))

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test", "fast green"],
      "artifacts" => ["review-fast-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "fast", "verdict" => "green"}]
    })

    repo.delete_all(Artifact)

    missing_review_lanes_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-review-lanes", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(missing_review_lanes_response, ["error", "data", "missing"])

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready after normal",
      "tests" => ["mix test", "normal green"],
      "artifacts" => ["review-normal-log.txt"],
      "head_sha" => "abc123",
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    incremental_review_lanes_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-incremental-review-lanes", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    incremental_missing = get_in(incremental_review_lanes_response, ["error", "data", "missing"])
    refute "review_lanes_complete" in incremental_missing
    assert "acceptance_criteria_met" in incremental_missing
    refute "review_artifacts_attached" in incremental_missing
    refute "plan_complete" in incremental_missing

    malformed_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-review-entries",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Malformed review",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => 1, "verdict" => "green"}, %{"lane" => "normal", "verdict" => nil}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_review_response, ["error", "data", "reason"]) == "invalid_reviews"

    extra_review_key_response =
      attach_tool(repo, session, "submit_review_package", %{
        "summary" => "Extra review key",
        "tests" => ["mix test"],
        "artifacts" => ["review-log.txt"],
        "head_sha" => "abc123",
        "acceptance_criteria_met" => true,
        "reviews" => [%{"lane" => " Fast ", "verdict" => " Green ", "note" => "typo"}]
      })

    assert response_progress_payload(repo, extra_review_key_response)["reviews"] == [%{"lane" => "fast", "verdict" => "green"}]

    duplicate_review_lane_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "duplicate-review-lane",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Duplicate review lane",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [
                %{"lane" => " fast ", "verdict" => "red"},
                %{"lane" => "fast", "verdict" => "green"}
              ]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(duplicate_review_lane_response, ["error", "data", "reason"]) == "invalid_reviews"

    missing_artifacts_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ready-missing-artifacts",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Ready without artifacts",
              "tests" => ["mix test"],
              "artifacts" => [],
              "head_sha" => "abc123",
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_artifacts_response, ["error", "data", "reason"]) == "missing_artifacts"

    blank_artifact_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "blank-artifact",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Blank artifact",
              "tests" => ["mix test"],
              "artifacts" => [" "],
              "head_sha" => "abc123",
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(blank_artifact_response, ["error", "data", "reason"]) == "invalid_artifacts"

    malformed_reviews_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-reviews",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Malformed reviews",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => %{"lane" => "fast", "verdict" => "green"}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_reviews_response, ["error", "data", "reason"]) == "invalid_reviews"

    invalid_acceptance_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-acceptance",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Invalid acceptance",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => "true",
              "reviews" => [%{"lane" => "fast", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_acceptance_response, ["error", "data", "reason"]) == "invalid_acceptance_criteria_met"

    invalid_tests_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-tests",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Invalid tests",
              "tests" => [" "],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_tests_response, ["error", "data", "reason"]) == "invalid_tests"

    invalid_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-head-sha",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Invalid head",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => 123,
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_head_response, ["error", "data", "reason"]) == "invalid_head_sha"

    sibling_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sibling-review-package",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "work_package_id" => "SYMPP-OTHER",
              "summary" => "Wrong package",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(sibling_review_response, ["error", "data", "reason"]) == "outside_session_scope"

    ready_review_args = %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    }

    ready_review_response = attach_tool(repo, session, "submit_review_package", ready_review_args)
    ready_review_event_id = get_in(ready_review_response, ["result", "structuredContent", "progress_event", "id"])

    handoff_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "handoff-with-review-artifact",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/SYMPP-READY-GATES/handoff.md"}
        },
        repo: repo,
        session: session
      )

    assert get_in(handoff_response, ["result", "contents", Access.at(0), "text"]) =~ "review-log.txt"

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest review has findings",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "fast", "verdict" => "green"}]
    })

    latest_missing_lane_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-latest-missing-lane", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    latest_missing_lane_missing = get_in(latest_missing_lane_response, ["error", "data", "missing"])
    assert "review_lanes_complete" in latest_missing_lane_missing
    refute "plan_complete" in latest_missing_lane_missing

    review_lane_reason =
      latest_missing_lane_response
      |> get_in(["error", "data", "reasons"])
      |> Enum.find(&(&1["gate"] == "review_lanes_complete"))

    assert Map.has_key?(review_lane_reason, "required_lanes")
    refute Map.has_key?(review_lane_reason, "accepted_lane_aliases")
    refute Map.has_key?(review_lane_reason, "accepted_verdicts")

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest review has findings",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "findings"}]
    })

    latest_findings_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-latest-findings", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(latest_findings_response, ["error", "data", "missing"])

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/123", "head_sha" => "def456"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/123", "def456")
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-GATES/worker", "head_sha" => "def456"})

    replay_headless_after_head_advance_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "headless-cross-head-review-submit",
          "method" => "tools/call",
          "params" => %{"name" => "submit_review_package", "arguments" => headless_review_args}
        },
        repo: repo,
        session: session
      )

    assert get_in(replay_headless_after_head_advance_response, ["error", "data", "reason"]) == "idempotency_conflict"

    replay_after_head_advance_response = attach_tool(repo, session, "submit_review_package", ready_review_args)

    assert get_in(replay_after_head_advance_response, ["result", "structuredContent", "progress_event", "id"]) == ready_review_event_id

    explicit_key_cross_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "explicit-key-cross-head-review-submit",
          "method" => "tools/call",
          "params" => %{"name" => "submit_review_package", "arguments" => Map.put(explicit_key_review_args, "head_sha", "def456")}
        },
        repo: repo,
        session: session
      )

    assert get_in(explicit_key_cross_head_response, ["error", "data", "reason"]) == "idempotency_conflict"

    stale_submit_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-review-submit",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Stale review",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_submit_response, ["error", "data", "reason"]) == "stale_head_sha"

    stale_review_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-stale-review", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    stale_review_missing = get_in(stale_review_response, ["error", "data", "missing"])
    assert "review_package_submitted" in stale_review_missing
    assert "review_lanes_complete" in stale_review_missing

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "def456",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => " normal ", "verdict" => " green "}]
    })

    assert {:ok, pending_plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               "work_package_id" => package.id,
               "title" => "Complete implementation",
               "status" => "pending"
             })

    pending_plan_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-pending-plan", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "plan_complete" in get_in(pending_plan_response, ["error", "data", "missing"])
    assert {:ok, _plan_node} = PlanningRepository.update_plan_node_status(repo, pending_plan_node.id, "done")

    pre_ready_finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-ready-finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Finding before ready", "body" => "Recorded before ready", "idempotency_key" => "pre-ready-finding"}
          }
        },
        repo: repo,
        session: session
      )

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"

    post_ready_branch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-branch",
          "method" => "tools/call",
          "params" => %{"name" => "attach_branch", "arguments" => %{"branch" => "agent/SYMPP-READY-GATES/worker", "head_sha" => "new-ready-head"}}
        },
        repo: repo,
        session: session
      )

    post_ready_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Red after ready",
              "tests" => ["mix test"],
              "artifacts" => ["red-after-ready.txt"],
              "head_sha" => "def456",
              "acceptance_criteria_met" => false,
              "reviews" => [%{"lane" => "fast", "verdict" => "red"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    post_ready_blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{"summary" => "Blocked after ready", "idempotency_key" => "post-ready-blocker"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-progress",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{"summary" => "Progress after ready", "idempotency_key" => "post-ready-progress"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Finding after ready", "body" => "Too late", "idempotency_key" => "post-ready-finding"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_finding_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-ready-finding-replay",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Finding before ready", "body" => "Recorded before ready", "idempotency_key" => "pre-ready-finding"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_scope_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-scope",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{"summary" => "Scope after ready", "idempotency_key" => "post-ready-scope"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_plan_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => 1, "title" => "Plan after ready"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(post_ready_branch_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_review_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_blocker_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_progress_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_finding_response, ["error", "data", "reason"]) == "already_ready"

    assert get_in(pre_ready_finding_response, ["result", "structuredContent", "finding", "id"]) ==
             get_in(post_ready_finding_replay_response, ["result", "structuredContent", "finding", "id"])

    assert get_in(post_ready_scope_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_plan_response, ["error", "data", "reason"]) == "already_ready"
    assert {:ok, ready_package} = WorkPackageRepository.get(repo, package.id)
    assert ready_package.status == "ready_for_merge"
  end

  test "sync_pr repairs PR identity and records only a verified terminal merge after readiness", %{repo: repo} do
    original_client = Application.get_env(:symphony_elixir, :sympp_github_client)
    Application.put_env(:symphony_elixir, :sympp_github_client, SymphonyElixir.FakeGitHubClient)
    SymphonyElixir.FakeGitHubClient.clear()

    on_exit(fn ->
      SymphonyElixir.FakeGitHubClient.clear()

      case original_client do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        client -> Application.put_env(:symphony_elixir, :sympp_github_client, client)
      end
    end)

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-READY-SYNC-MERGED",
                 kind: "standard_pr",
                 repo: "nextide/repo",
                 base_branch: "main",
                 status: "ready_for_merge"
               )
             )

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "fix/ready-sync", head_sha: "head-a"}
             })

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    assert {:ok, initial_events} = PlanningRepository.list_progress_events(repo, package.id)

    SymphonyElixir.FakeGitHubClient.put_response(
      "nextide/repo",
      27,
      SymphonyElixir.GitHubPullRequestFixtures.metadata(27, "head-a", merged?: false)
    )

    open_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-open",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{"url" => "https://github.com/nextide/repo/pull/27", "head_sha" => "head-a"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(open_response, ["error", "data", "reason"]) == "pr_not_merged"
    assert {:ok, unchanged_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert length(unchanged_events) == length(initial_events)
    assert repo.get!(WorkPackage, package.id).status == "ready_for_merge"

    SymphonyElixir.FakeGitHubClient.put_response(
      "nextide/repo",
      27,
      SymphonyElixir.GitHubPullRequestFixtures.metadata(27, "head-a", merged?: true)
    )

    merged_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-merged",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{"url" => "https://github.com/nextide/repo/pull/27", "head_sha" => "head-a"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(merged_response, ["result", "structuredContent", "work_package", "status"]) == "merged"
    assert get_in(merged_response, ["result", "structuredContent", "pr_sync", "status"]) == "merged"

    replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-replay",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{"url" => "https://github.com/nextide/repo/pull/27", "head_sha" => "head-a"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["result", "structuredContent", "pr_sync", "status"]) == "already_merged"
  end

  test "mark_ready does not require ci_waiting when package policy omits CI", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-NO-CI", kind: "mcp", status: "reviewing"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    append_done_plan(repo, package.id)

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-no-ci-missing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(missing_response, ["error", "data", "missing"])
    refute "status_ci_waiting" in missing
    refute "plan_complete" in missing
    assert "acceptance_criteria_met" in missing
    assert "tests_passed" in missing
    assert "pr_attached" in missing
    assert "review_package_submitted" in missing
    assert "review_lanes_complete" in missing

    append_merge_ready_evidence(repo, session, package.id, "head-no-ci")

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-no-ci", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"
  end

  test "Review Suite round aliases infer evidence and satisfy planned-slice readiness", %{repo: repo} do
    head_sha = "review-suite-alias-head"
    branch = "agent/SYMPP-REVIEW-SUITE-ALIAS/worker"
    work_request = create_work_request!(repo, id: "WR-REVIEW-SUITE-ALIAS", base_branch: "main", status: "ready_for_slicing")

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-REVIEW-SUITE-ALIAS",
                 target_base_branch: work_request.base_branch,
                 branch_pattern: branch,
                 review_lanes: ["normal"]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REVIEW-SUITE-ALIAS",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: work_request.repo,
                 base_branch: planned_slice.target_base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ci_waiting",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    put_review_suite_state!("rvw_alias_normal", "orc-alias-normal", head_sha, "normal", branch: branch, repo: package.repo, work_package_id: package.id)

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, _dispatched_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => branch, "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/777", "head_sha" => head_sha})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready except Review Suite round evidence",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => []
    })

    result =
      attach_tool(repo, session, "attach_review_suite_result", %{
        "round_id" => "rvw_alias_normal",
        "suite" => "github-actions",
        "profile" => "review_suite normal",
        "lane" => "review-suite normal"
      })

    payload = response_progress_payload(repo, result)
    assert payload["suite"] == "review-suite"
    assert payload["profile"] == "normal"
    assert payload["lane"] == "normal"
    assert payload["head_sha"] == head_sha
    assert payload["work_package_id"] == package.id

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-review-suite-alias", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "legacy non-Review Suite payloads do not satisfy Review Suite readiness", %{repo: repo} do
    head_sha = "review-suite-legacy-suite-head"

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REVIEW-SUITE-LEGACY-SUITE",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/#{package.id}/worker", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/778", "head_sha" => head_sha})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready except Review Suite result",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => []
    })

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => review_suite_artifact_id(package.id, head_sha),
               "work_package_id" => package.id,
               "path" => "review-suite-result.json",
               "title" => "Review Suite result",
               "kind" => "review_suite"
             })

    assert {:ok, _event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:legacy-github-actions",
               "summary" => "Legacy review-suite result",
               "status" => "review_suite_passed",
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => head_sha,
                 "suite" => "github-actions",
                 "anchor" => "legacy-github-actions",
                 "summary" => "Legacy payload used the wrong suite",
                 "status" => "passed",
                 "verdict" => "clean",
                 "profile" => "normal",
                 "lane" => "normal",
                 "round_id" => "rvw_legacy_github_actions"
               }
             })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-review-suite-legacy-suite", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert get_in(ready_response, ["error", "data", "reason"]) == "readiness_failed"
    assert "review_suite_result" in missing
    assert "review_lanes_complete" in missing
  end

  test "Review Suite alias normalization keeps custom whitespace lanes distinct" do
    assert ReviewProfiles.normalize_profile("review_suite normal") == "normal"
    assert ReviewProfiles.normalize_profile("review-suite normal") == "normal"
    assert ReviewProfiles.normalize_profile("github review") == "github"
    assert ReviewProfiles.normalize_profile("review_github") == "github"
    assert ReviewProfiles.profile_satisfies?("github", "github review")
    assert ReviewProfiles.profile_satisfies?("github", "review_github")
    assert ReviewProfiles.profile_verdicts_pass?("github review", %{"github" => "green"})
    assert ReviewProfiles.profile_verdicts_pass?("review_github", %{"github" => "green"})
    assert ReviewProfiles.normalize_profile("security review") == "security review"
    assert ReviewProfiles.normalize_profile("security_review") == "security_review"
  end

  test "explicit Review Suite fallback rejects arbitrary suite labels", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-SUITE", kind: "mcp", status: "reviewing"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-suite",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_review_suite_result",
            "arguments" => %{
              "head_sha" => "suite-head",
              "suite" => "github-actions",
              "anchor" => "suite-anchor",
              "summary" => "Not Review Suite",
              "status" => "passed",
              "verdict" => "clean",
              "profile" => "normal"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "invalid_review_suite"
  end

  test "mark_ready still requires ci_waiting when package policy requires CI", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-CI-REQUIRED", kind: "mcp", status: "reviewing", policy_template: "mcp_ci_required")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    append_merge_ready_evidence(repo, session, package.id, "head-ci-required")

    reviewing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-ci-required-reviewing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(reviewing_response, ["error", "data", "reason"]) == "readiness_failed"
    assert get_in(reviewing_response, ["error", "data", "missing"]) == ["status_ci_waiting"]

    transition_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ci-required-transition",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"expected_status" => "reviewing", "status" => "ci_waiting"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(transition_response, ["result", "structuredContent", "work_package", "status"]) == "ci_waiting"

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-ci-required", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"
  end

  test "state machine blocks ready transitions from reviewing when package policy requires CI", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-CI-STATE-MACHINE", kind: "mcp", status: "reviewing", policy_template: "mcp_ci_required")
             )

    actor = %{grant_role: "worker", capabilities: ["worker:lifecycle.transition"], work_package_id: package.id}

    assert {:error, :invalid_transition} =
             StateMachine.validate_ready_transition(package, "ready_for_merge", actor)

    ci_waiting_package = %{package | status: "ci_waiting"}
    assert :ok = StateMachine.validate_ready_transition(ci_waiting_package, "ready_for_merge", actor)
  end

  defp put_review_suite_state!(public_id, cycle_key, head_sha, profile, opts) do
    state_dir = Path.join(System.tmp_dir!(), "review-suite-state-#{System.unique_integer([:positive])}")
    cycles_dir = Path.join([state_dir, "orchestrator", "cycles"])
    File.mkdir_p!(cycles_dir)

    File.write!(Path.join([state_dir, "orchestrator", "index.json"]), Jason.encode!(%{"public_ids" => %{public_id => cycle_key}}))
    File.write!(Path.join(cycles_dir, "#{cycle_key}.json"), Jason.encode!(review_suite_cycle(public_id, head_sha, profile, opts)))

    previous = Application.get_env(:symphony_elixir, :sympp_review_suite_state_dir)
    Application.put_env(:symphony_elixir, :sympp_review_suite_state_dir, state_dir)

    ExUnit.Callbacks.on_exit(fn ->
      restore_review_suite_state_dir(previous)
      File.rm_rf(state_dir)
    end)
  end

  defp review_suite_cycle(public_id, head_sha, profile, opts) do
    %{
      "public_id" => public_id,
      "stage" => "review-green",
      "validation" => %{"review_green" => "passed"},
      "identity" => review_suite_cycle_identity(head_sha, opts),
      "mode" => %{"effective" => profile, "requested" => profile},
      "review_heads" => %{"last_reviewed_head" => head_sha},
      "rounds" => [%{"round_id" => "review_t1", "review_status" => "completed", "reviewed_head" => head_sha}],
      "decisions" => [%{"round_id" => "review_t1", "command" => "clean", "reviewed_head" => head_sha}]
    }
  end

  defp review_suite_cycle_identity(head_sha, opts) do
    %{"base" => Keyword.get(opts, :base_branch, "main"), "branch" => Keyword.get(opts, :branch, "hotfix/review-suite-round-ux"), "head" => head_sha}
    |> put_identity("repo", Keyword.get(opts, :repo))
    |> put_identity("work_package_id", Keyword.get(opts, :work_package_id))
  end

  defp put_identity(identity, _key, nil), do: identity
  defp put_identity(identity, key, value), do: Map.put(identity, key, value)

  defp restore_review_suite_state_dir(nil), do: Application.delete_env(:symphony_elixir, :sympp_review_suite_state_dir)
  defp restore_review_suite_state_dir(value), do: Application.put_env(:symphony_elixir, :sympp_review_suite_state_dir, value)
end
