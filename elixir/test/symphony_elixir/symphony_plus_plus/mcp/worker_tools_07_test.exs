Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools07Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "docs mark_ready uses docs gates without investigation recommendation artifacts", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-DOCS", kind: "docs", status: "reviewing"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "docs-worker")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-docs-missing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(missing_response, ["error", "data", "missing"])
    assert get_in(missing_response, ["error", "data", "reason"]) == "readiness_failed"
    assert "tests_passed" in missing
    refute "findings_documented" in missing
    refute "recommendation_artifact_recorded" in missing

    scope_response =
      attach_tool(repo, session, "request_scope_expansion", %{
        "summary" => "Docs scope note",
        "idempotency_key" => "docs-scope-note"
      })

    refute Map.has_key?(response_progress_payload(repo, scope_response), "recommendation_artifact_id")

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Docs validation passed",
      "status" => "tests_passed",
      "idempotency_key" => "docs-validation"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-docs", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "kind"]) == "docs"
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"
  end

  test "non-merge readiness accepts branchless validation packages when branch metadata is not required", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BRANCHLESS-REVIEW", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Branchless quick-fix review",
      "tests" => ["mix test"],
      "artifacts" => ["branchless-review.txt"],
      "head_sha" => "standalone-head"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-branchless-review", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "hotfix mark_ready accepts incident-depth review evidence without plan nodes", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-HOTFIX", kind: "hotfix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-HOTFIX/worker", "head_sha" => "hotfix-head"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/812", "head_sha" => "hotfix-head"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/812", "hotfix-head")

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready hotfix",
      "tests" => ["mix test"],
      "artifacts" => ["hotfix-review.txt"],
      "head_sha" => "hotfix-head"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-hotfix", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"
  end

  test "investigation readiness does not require branch or review package", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-READY", kind: "investigation", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Recommendation", "body" => "No code change needed.", "idempotency_key" => "investigation-finding"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(finding_response, ["result", "structuredContent", "finding", "title"]) == "Recommendation"

    missing_recommendation_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-recommendation", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(missing_recommendation_response, ["error", "data", "missing"])
    refute "current_pr_state" in get_in(missing_recommendation_response, ["error", "data", "missing"])
    refute "scope_guard" in get_in(missing_recommendation_response, ["error", "data", "missing"])

    spoofed_artifact_id =
      "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join([package.id, "recommendation", "recommendation.md"], ":")), padding: false)

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed recommendation",
      "payload" => %{
        "type" => "scope_expansion_request",
        "source_tool" => "request_scope_expansion",
        "recommendation_artifact_id" => spoofed_artifact_id,
        "approved" => false,
        "requested_file_globs" => ["lib/spoof/**"]
      },
      "idempotency_key" => "investigation-spoofed-recommendation"
    })

    spoofed_recommendation_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-spoofed-recommendation", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(spoofed_recommendation_response, ["error", "data", "missing"])
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed recommendation with protected-looking key",
      "payload" => %{
        "type" => "scope_expansion_request",
        "source_tool" => "request_scope_expansion",
        "recommendation_artifact_id" => spoofed_artifact_id,
        "approved" => false,
        "requested_file_globs" => ["lib/spoof/**"]
      },
      "idempotency_key" => "request_scope_expansion:investigation-spoofed-recommendation"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed recommendation without protected type",
      "payload" => %{
        "approved" => false,
        "requested_file_globs" => ["lib/spoof/**"]
      },
      "idempotency_key" => "investigation-spoofed-recommendation-fields"
    })

    protected_key_spoof_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-protected-key-spoof", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(protected_key_spoof_response, ["error", "data", "missing"])
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)
    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)

    for summary <- [
          "Spoofed recommendation",
          "Spoofed recommendation with protected-looking key",
          "Spoofed recommendation without protected type"
        ] do
      event = Enum.find(progress_events, &(&1.summary == summary))
      assert event
      refute Map.has_key?(event.payload, "type")
      refute Map.has_key?(event.payload, "source_tool")
      refute Map.has_key?(event.payload, "recommendation_artifact_id")
      refute Map.has_key?(event.payload, "approved")
      refute Map.has_key?(event.payload, "requested_file_globs")
    end

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => spoofed_artifact_id,
               "work_package_id" => package.id,
               "path" => "recommendation.md",
               "title" => "Spoofed recommendation artifact",
               "kind" => "reference",
               "uri" => "sympp://artifacts/spoofed-recommendation"
             })

    spoofed_artifact_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-spoofed-artifact", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(spoofed_artifact_response, ["error", "data", "missing"])

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "No scope expansion needed",
      "body" => "Recommendation recorded for the investigation package.",
      "idempotency_key" => "investigation-recommendation"
    })

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Updated recommendation",
      "body" => "Recommendation remains recorded without duplicate canonical artifacts.",
      "idempotency_key" => "investigation-recommendation-updated"
    })

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)

    assert Enum.any?(
             artifacts,
             &(&1.title == "Investigation recommendation" and &1.kind == "recommendation" and &1.path == "recommendation.md" and
                 is_nil(&1.uri))
           )

    repo.get!(Artifact, spoofed_artifact_id)
    |> Ecto.Changeset.change(uri: "sympp://artifacts/canonical-recommendation")
    |> repo.update!()

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Final recommendation",
      "body" => "Recommendation remains recorded without clearing canonical artifact URI.",
      "idempotency_key" => "investigation-recommendation-final"
    })

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)

    assert Enum.any?(
             artifacts,
             &(&1.title == "Investigation recommendation" and &1.kind == "recommendation" and &1.path == "recommendation.md" and
                 &1.uri == "sympp://artifacts/canonical-recommendation")
           )

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "non-investigation scope requests do not emit recommendation artifact references", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-HOTFIX-SCOPE-REQUEST", kind: "hotfix"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Need extra file",
      "body" => "Worker recommends expanding allowed files.",
      "idempotency_key" => "hotfix-scope-request",
      "payload" => %{
        "requested_file_globs" => ["lib/other/**"],
        "recommendation_artifact_id" => "artifact_spoofed",
        "source_tool" => "caller"
      }
    })

    assert {:ok, [event]} = PlanningRepository.list_progress_events(repo, package.id)
    assert event.payload["type"] == "scope_expansion_request"
    assert event.payload["source_tool"] == "request_scope_expansion"
    assert event.payload["requested_file_globs"] == ["lib/other/**"]
    refute Map.has_key?(event.payload, "recommendation_artifact_id")

    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)
  end

  test "request_scope_expansion without a session returns an auth error", %{repo: repo} do
    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "scope-without-session",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{"summary" => "Need more scope", "idempotency_key" => "missing-session-scope"}
          }
        },
        repo: repo
      )

    assert get_in(response, ["error", "data", "reason"]) == "claim_required"
  end

  test "investigation readiness rejects legacy recommendation event without artifact", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-LEGACY-READY", kind: "investigation", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    legacy_artifact_id =
      "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join([package.id, "recommendation", "recommendation.md"], ":")), padding: false)

    assert {:ok, _finding} =
             PlanningRepository.append_finding(repo, %{
               "work_package_id" => package.id,
               "title" => "Recommendation",
               "body" => "No code change needed.",
               "idempotency_key" => "investigation-legacy-finding"
             })

    assert {:ok, event} =
             PlanningRepository.append_audit_progress_event(repo, assignment, %{
               "work_package_id" => package.id,
               "summary" => "Prior recommendation",
               "body" => "Recommendation recorded before artifact markers existed.",
               "idempotency_key" => "request_scope_expansion:investigation-legacy-recommendation",
               "payload" => %{
                 "type" => "scope_expansion_request",
                 "source_tool" => "request_scope_expansion",
                 "approved" => false,
                 "requested_file_globs" => ["lib/legacy/**"],
                 "recommendation_artifact_id" => legacy_artifact_id
               }
             })

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    refute Enum.any?(artifacts, &(&1.kind == "recommendation" and &1.path == "recommendation.md"))

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-recommendation", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(ready_response, ["error", "data", "missing"])
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)

    replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "replay-legacy-recommendation",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{
              "summary" => "Prior recommendation",
              "body" => "Recommendation recorded before artifact markers existed.",
              "idempotency_key" => "investigation-legacy-recommendation",
              "payload" => %{
                "requested_file_globs" => ["lib/legacy/**"],
                "recommendation_artifact_id" => legacy_artifact_id
              }
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"]) == event.id
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)
  end

  test "mark_ready fails recommendation gate when legacy artifact cannot be repaired", %{repo: repo} do
    assert {:ok, owner_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-LEGACY-OWNER", kind: "investigation"))
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-LEGACY-COLLISION", kind: "investigation", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    legacy_artifact_id =
      "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join([package.id, "recommendation", "recommendation.md"], ":")), padding: false)

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => legacy_artifact_id,
               "work_package_id" => owner_package.id,
               "path" => "recommendation.md",
               "title" => "Other package recommendation",
               "kind" => "recommendation"
             })

    assert {:ok, _finding} =
             PlanningRepository.append_finding(repo, %{
               "work_package_id" => package.id,
               "title" => "Recommendation",
               "body" => "No code change needed.",
               "idempotency_key" => "investigation-legacy-collision-finding"
             })

    assert {:ok, _event} =
             PlanningRepository.append_audit_progress_event(repo, assignment, %{
               "work_package_id" => package.id,
               "summary" => "Prior recommendation",
               "body" => "Recommendation recorded before artifact markers existed.",
               "idempotency_key" => "request_scope_expansion:investigation-legacy-collision-recommendation",
               "payload" => %{
                 "type" => "scope_expansion_request",
                 "source_tool" => "request_scope_expansion",
                 "approved" => false,
                 "recommendation_artifact_id" => legacy_artifact_id
               }
             })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-collision", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(response, ["error", "data", "missing"])
  end

  test "unmarked legacy scope event replay does not create recommendation artifact readiness", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-LEGACY-UNMARKED", kind: "investigation", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert {:ok, _finding} =
             PlanningRepository.append_finding(repo, %{
               "work_package_id" => package.id,
               "title" => "Recommendation",
               "body" => "No code change needed.",
               "idempotency_key" => "investigation-legacy-unmarked-finding"
             })

    assert {:ok, _event} =
             PlanningRepository.append_audit_progress_event(repo, assignment, %{
               "work_package_id" => package.id,
               "summary" => "Prior scope request",
               "body" => "Raw scope request without canonical recommendation marker.",
               "idempotency_key" => "request_scope_expansion:investigation-legacy-unmarked",
               "payload" => %{
                 "type" => "scope_expansion_request",
                 "source_tool" => "request_scope_expansion",
                 "approved" => false
               }
             })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-unmarked", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(response, ["error", "data", "missing"])
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)

    replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "replay-legacy-unmarked",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{
              "summary" => "Prior scope request",
              "body" => "Raw scope request without canonical recommendation marker.",
              "idempotency_key" => "investigation-legacy-unmarked"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"])
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)

    replay_ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-unmarked-after-replay", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(replay_ready_response, ["error", "data", "missing"])

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Canonical recommendation",
      "body" => "Recommendation is now recorded through the current canonical path.",
      "idempotency_key" => "investigation-legacy-unmarked-canonical"
    })

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)

    assert Enum.any?(
             artifacts,
             &(&1.work_package_id == package.id and &1.path == "recommendation.md" and
                 &1.title == "Investigation recommendation" and &1.kind == "recommendation")
           )

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-unmarked-after-canonical", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "recommendation artifact repair rejects cross-package id collisions", %{repo: repo} do
    assert {:ok, owner_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-OWNER", kind: "investigation"))
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-COLLISION", kind: "investigation"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    colliding_artifact_id =
      "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join([package.id, "recommendation", "recommendation.md"], ":")), padding: false)

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => colliding_artifact_id,
               "work_package_id" => owner_package.id,
               "path" => "recommendation.md",
               "title" => "Other package recommendation",
               "kind" => "recommendation"
             })

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "scope-artifact-collision",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{
              "summary" => "Recommendation",
              "body" => "Recommendation should not steal another package artifact.",
              "idempotency_key" => "artifact-collision"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "id_already_exists"
    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, owner_package.id)
    assert Enum.any?(artifacts, &(&1.id == colliding_artifact_id and &1.work_package_id == owner_package.id))
  end

  test "mark_ready rejects spoofed metadata and accepts skipped plan nodes", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-SPOOF", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert {:ok, _skipped} =
             PlanningRepository.append_plan_node(repo, %{
               "work_package_id" => package.id,
               "title" => "Skipped with rationale",
               "body" => "No longer needed",
               "status" => "skipped"
             })

    Enum.each(["branch", "pr", "review_package"], fn type ->
      response =
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "spoof-#{type}",
            "method" => "tools/call",
            "params" => %{
              "name" => "append_progress",
              "arguments" => %{
                "summary" => "Spoof #{type}",
                "idempotency_key" => "spoof-#{type}",
                "payload" => %{"type" => type, "source_tool" => "attach_#{type}"}
              }
            }
          },
          repo: repo,
          session: session
        )

      assert get_in(response, ["result", "structuredContent", "progress_event", "id"])
    end)

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["error", "data", "reason"]) == "readiness_failed"

    assert get_in(ready_response, ["error", "data", "missing"]) == [
             "acceptance_criteria_met",
             "tests_passed",
             "branch_attached",
             "pr_attached",
             "review_artifacts_attached"
           ]
  end

  test "worker metadata tools preserve protected fields and reject non-map payloads", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PAYLOAD", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{
              "summary" => "Blocked",
              "idempotency_key" => "blocker-protected",
              "payload" => %{"type" => "pr", "active" => false, "source_tool" => "attach_pr"}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert event_id = get_in(blocker_response, ["result", "structuredContent", "progress_event", "id"])
    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)
    event = Enum.find(events, &(&1.id == event_id))
    assert event.payload["type"] == "blocker"
    assert event.payload["source_tool"] == "report_blocker"
    assert event.payload["active"] == true

    invalid_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "bad-payload",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{"summary" => "Bad", "idempotency_key" => "bad-payload", "payload" => false}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_response, ["error", "code"]) == -32_602
    assert get_in(invalid_response, ["error", "data", "reason"]) == "invalid_payload"
  end

  test "mark_ready uses lifecycle capability checks", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-CAP", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id, capabilities: ["worker:claim"])
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-CAP/worker", "head_sha" => "abc124"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/124", "head_sha" => "abc124"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/124", "abc124")

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc124",
      "acceptance_criteria_met" => true
    })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "missing_lifecycle_capability"
  end

  test "worker cannot mark merged mint grants or list all packages through MCP", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-DENIALS", kind: "adapter", status: "ready_for_merge"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    merged_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "merged",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "merged", "expected_status" => "ready_for_merge"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(merged_response, ["error", "data", "reason"]) == "worker_cannot_mark_merged"

    Enum.each(["mint_worker_grant", "list_work_packages"], fn tool ->
      response =
        MCPHarness.request(
          %{"jsonrpc" => "2.0", "id" => tool, "method" => "tools/call", "params" => %{"name" => tool, "arguments" => %{}}},
          repo: repo,
          session: session
        )

      assert get_in(response, ["error", "code"]) == -32_601
    end)
  end
end
