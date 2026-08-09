Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.PhaseArchitectTools01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "phase architect creates child work package inside scoped phase", %{repo: repo} do
    {anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-CREATE-ANCHOR", [
        "create:child_work_package",
        "read:phase"
      ])

    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-CREATED-CHILD",
          "title" => "Implement child lane",
          "acceptance_criteria" => ["Child lane complete"],
          "allowed_file_globs" => ["./elixir\\lib\\symphony_elixir/**"]
        }
      })

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == "SYMPP-P7-002-CREATED-CHILD"
    assert get_in(response, ["result", "structuredContent", "work_package", "kind"]) == "phase_child"
    assert get_in(response, ["result", "structuredContent", "work_package", "phase_id"]) == @architect_phase_id
    assert get_in(response, ["result", "structuredContent", "work_package", "parent_id"]) == anchor.id
    assert get_in(response, ["result", "structuredContent", "work_package", "base_branch"]) == "symphony-plus-plus/beta"
    assert get_in(response, ["result", "structuredContent", "work_package", "repo"]) == "nextide/symphony-plus-plus"

    assert {:ok, child} = WorkPackageRepository.get(repo, "SYMPP-P7-002-CREATED-CHILD")
    assert child.status == "ready_for_worker"
    assert child.policy_template == "phase_child"
    assert child.allowed_file_globs == ["elixir/lib/symphony_elixir/**"]
  end

  test "phase architect with delegation-only capabilities can create, mint, and read child", %{repo: repo} do
    {anchor, session, grant} =
      create_phase_architect_session(repo, "SYMPP-P7-002-DELEGATION-ONLY-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:child_progress",
        "read:child_findings"
      ])

    assert grant.phase_id == @architect_phase_id
    assert grant.scope_repo == anchor.repo
    assert grant.scope_base_branch == anchor.base_branch

    child_id = create_child_work_package(repo, session, "SYMPP-P7-002-DELEGATION-ONLY-CHILD")

    mint_response =
      mcp_tool(repo, session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    assert get_in(mint_response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child_id

    status_response = mcp_tool(repo, session, "read_child_status", %{"work_package_id" => child_id})

    assert get_in(status_response, ["result", "structuredContent", "work_package", "id"]) == child_id
    assert get_in(status_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_worker"
  end

  test "phase architect cannot create child outside scoped phase or base branch", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-CREATE-SCOPE-ANCHOR", [
        "create:child_work_package",
        "read:phase"
      ])

    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-p7-002-outside", title: "Outside phase"})

    out_of_phase_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-OUT-OF-PHASE",
          "title" => "Invalid child",
          "phase_id" => other_phase.id,
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(out_of_phase_response, ["error", "code"]) == -32_003
    assert get_in(out_of_phase_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-OUT-OF-PHASE")

    wrong_base_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-WRONG-BASE",
          "title" => "Wrong base",
          "base_branch" => "main",
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(wrong_base_response, ["error", "code"]) == -32_602
    assert get_in(wrong_base_response, ["error", "data", "reason"]) == "base_branch_scope_mismatch"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-WRONG-BASE")

    empty_globs_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-EMPTY-GLOBS",
          "title" => "Empty globs",
          "allowed_file_globs" => [],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(empty_globs_response, ["error", "code"]) == -32_602
    assert get_in(empty_globs_response, ["error", "data", "reason"]) == "missing_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-EMPTY-GLOBS")
  end

  test "phase architect with empty anchor globs requires explicit child file scope", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-EMPTY-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: []
      )

    inherited_empty_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-INHERITED-EMPTY-GLOBS",
          "title" => "Inherited empty globs",
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(inherited_empty_response, ["error", "code"]) == -32_602
    assert get_in(inherited_empty_response, ["error", "data", "reason"]) == "missing_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-INHERITED-EMPTY-GLOBS")

    explicit_empty_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-EXPLICIT-EMPTY-GLOBS",
          "title" => "Explicit empty globs",
          "allowed_file_globs" => [],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(explicit_empty_response, ["error", "code"]) == -32_602
    assert get_in(explicit_empty_response, ["error", "data", "reason"]) == "missing_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-EXPLICIT-EMPTY-GLOBS")

    explicit_scope_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-UNBOUNDED-EXPLICIT-GLOBS",
          "title" => "Explicit globs without anchor scope",
          "allowed_file_globs" => ["elixir/lib/**"],
          "acceptance_criteria" => ["Child carries concrete file scope"]
        }
      })

    assert get_in(explicit_scope_response, ["result", "structuredContent", "work_package", "id"]) ==
             "SYMPP-P7-002-UNBOUNDED-EXPLICIT-GLOBS"

    assert {:ok, child} = WorkPackageRepository.get(repo, "SYMPP-P7-002-UNBOUNDED-EXPLICIT-GLOBS")
    assert child.allowed_file_globs == ["elixir/lib/**"]
  end

  test "phase architect child delegation fails closed after anchor repo or base branch drift", %{repo: repo} do
    for {field, drifted_value, suffix} <- [
          {:base_branch, "main", "BASE"},
          {:repo, "nextide/other", "REPO"}
        ] do
      {anchor, session} =
        create_architect_session(repo, "SYMPP-P7-002-#{suffix}-DRIFT-ANCHOR", [
          "create:child_work_package",
          "mint:child_worker_key",
          "read:phase"
        ])

      child_id = create_child_work_package(repo, session, "SYMPP-P7-002-#{suffix}-DRIFT-CHILD")
      assert {:ok, _anchor} = WorkPackageRepository.update(repo, anchor.id, Map.put(%{}, field, drifted_value))

      create_response =
        mcp_tool(repo, session, "create_child_work_package", %{
          "package" => %{
            "id" => "SYMPP-P7-002-#{suffix}-DRIFT-NEW-CHILD",
            "title" => "Drifted anchor child",
            "acceptance_criteria" => ["Should not be created"]
          }
        })

      assert get_in(create_response, ["error", "code"]) == -32_003
      assert get_in(create_response, ["error", "data", "reason"]) == "outside_session_scope"
      assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-#{suffix}-DRIFT-NEW-CHILD")

      grants_before = repo.aggregate(AccessGrant, :count)

      mint_response =
        mcp_tool(repo, session, "mint_child_worker_key", %{
          "work_package_id" => child_id
        })

      assert get_in(mint_response, ["error", "code"]) == -32_003
      assert get_in(mint_response, ["error", "data", "reason"]) == "outside_session_scope"
      assert repo.aggregate(AccessGrant, :count) == grants_before
    end
  end

  test "phase architect child delegation fails closed when frozen scope snapshot is missing", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-MISSING-SNAPSHOT-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, session, "SYMPP-P7-002-MISSING-SNAPSHOT-CHILD")

    repo.query!(
      "UPDATE sympp_access_grants SET scope_repo = NULL, scope_base_branch = NULL WHERE id = ?",
      [session.assignment.grant_id]
    )

    create_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-MISSING-SNAPSHOT-NEW-CHILD",
          "title" => "Missing snapshot child",
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(create_response, ["error", "code"]) == -32_003
    assert get_in(create_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-MISSING-SNAPSHOT-NEW-CHILD")

    grants_before = repo.aggregate(AccessGrant, :count)

    mint_response =
      mcp_tool(repo, session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    assert get_in(mint_response, ["error", "code"]) == -32_003
    assert get_in(mint_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert repo.aggregate(AccessGrant, :count) == grants_before

    status_response = mcp_tool(repo, session, "read_child_status", %{"work_package_id" => child_id})

    assert get_in(status_response, ["error", "code"]) == -32_003
    assert get_in(status_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "phase architect read_child_status fails closed for missing child IDs", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-MISSING-STATUS-ANCHOR", [
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    response = mcp_tool(repo, session, "read_child_status", %{"work_package_id" => "SYMPP-P7-002-MISSING-STATUS-CHILD"})

    assert get_in(response, ["error", "code"]) == -32_003
    assert get_in(response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "legacy nil-phase architect grant cannot use child delegation or status", %{repo: repo} do
    phase_id = ensure_architect_phase(repo)

    {anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-NIL-PHASE-ANCHOR",
        [
          "create:child_work_package",
          "mint:child_worker_key",
          "read:child_progress",
          "read:child_findings"
        ],
        phase_id: phase_id
      )

    assert is_nil(session.assignment.phase_id)

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-NIL-PHASE-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: phase_id,
                 parent_id: anchor.id,
                 base_branch: anchor.base_branch,
                 repo: anchor.repo,
                 status: "ready_for_worker"
               )
             )

    create_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-NIL-PHASE-NEW-CHILD",
          "title" => "Nil phase child",
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(create_response, ["error", "code"]) == -32_003
    assert get_in(create_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-NIL-PHASE-NEW-CHILD")

    grants_before = repo.aggregate(AccessGrant, :count)

    mint_response =
      mcp_tool(repo, session, "mint_child_worker_key", %{
        "work_package_id" => child.id
      })

    assert get_in(mint_response, ["error", "code"]) == -32_003
    assert get_in(mint_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert repo.aggregate(AccessGrant, :count) == grants_before

    status_response = mcp_tool(repo, session, "read_child_status", %{"work_package_id" => child.id})

    assert get_in(status_response, ["error", "code"]) == -32_003
    assert get_in(status_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "phase architect child creation revalidates anchor scope inside insert transaction", %{repo: repo} do
    {anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-CREATE-RACE-ANCHOR", [
        "create:child_work_package",
        "read:phase"
      ])

    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-p7-002-create-race", title: "Create race"})
    CreateChildAnchorRaceRepo.arm(anchor.id, %{phase_id: other_phase.id})

    response =
      try do
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "create_child_work_package",
            "method" => "tools/call",
            "params" => %{
              "name" => "create_child_work_package",
              "arguments" => %{
                "package" => %{
                  "id" => "SYMPP-P7-002-CREATE-RACE-CHILD",
                  "title" => "Create race child",
                  "acceptance_criteria" => ["Should not be created"]
                }
              }
            }
          },
          config: Config.default(repo: CreateChildAnchorRaceRepo),
          session: session
        )
      after
        CreateChildAnchorRaceRepo.disarm()
      end

    assert get_in(response, ["error", "code"]) == -32_003
    assert get_in(response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-CREATE-RACE-CHILD")
  end

  test "phase architect cannot create child work package with blank scoped fields", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-BLANK-SCOPE-ANCHOR", [
        "create:child_work_package",
        "read:phase"
      ])

    blank_scope_cases = [
      {"phase_id", " ", "invalid_phase_id"},
      {"parent_id", "null", "invalid_parent_id"},
      {"repo", "", "invalid_repo"},
      {"base_branch", " NULL ", "invalid_base_branch"}
    ]

    for {key, value, reason} <- blank_scope_cases do
      child_id = "SYMPP-P7-002-BLANK-" <> (key |> String.replace("_", "-") |> String.upcase())

      response =
        mcp_tool(repo, session, "create_child_work_package", %{
          "package" => %{
            "id" => child_id,
            "title" => "Blank scoped field",
            "acceptance_criteria" => ["Should not be created"],
            key => value
          }
        })

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == reason
      assert {:error, :not_found} = WorkPackageRepository.get(repo, child_id)
    end
  end

  test "phase architect can narrow child globs under supported non-prefix anchor globs", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-GLOB-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["elixir/**/*.ex"]
      )

    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-CHILD",
          "title" => "Narrow glob child",
          "allowed_file_globs" => ["elixir/lib/**/*.ex"],
          "acceptance_criteria" => ["Child scope stays inside anchor glob"]
        }
      })

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == "SYMPP-P7-002-GLOB-CHILD"
    assert {:ok, child} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-CHILD")
    assert child.allowed_file_globs == ["elixir/lib/**/*.ex"]
  end

  test "phase architect child glob scope rejects traversal and invalid broadening", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-GLOB-SCOPE-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["elixir/lib/foo/*.ex"]
      )

    traversal_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-TRAVERSAL",
          "title" => "Traversal child",
          "allowed_file_globs" => ["elixir/lib/../../priv/**"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(traversal_response, ["error", "code"]) == -32_602
    assert get_in(traversal_response, ["error", "data", "reason"]) == "path_traversal_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-TRAVERSAL")

    encoded_traversal_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-ENCODED-TRAVERSAL",
          "title" => "Encoded traversal child",
          "allowed_file_globs" => ["elixir/lib/%2e%2e/priv/**"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(encoded_traversal_response, ["error", "data", "reason"]) == "path_traversal_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-ENCODED-TRAVERSAL")

    encoded_slash_traversal_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-ENCODED-SLASH-TRAVERSAL",
          "title" => "Encoded slash traversal child",
          "allowed_file_globs" => ["elixir/lib%2f..%2fpriv/**"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(encoded_slash_traversal_response, ["error", "data", "reason"]) ==
             "path_traversal_allowed_file_globs"

    assert {:error, :not_found} =
             WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-ENCODED-SLASH-TRAVERSAL")

    broadening_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-BROADENING",
          "title" => "Broadening child",
          "allowed_file_globs" => ["elixir/*/foo/*.ex"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(broadening_response, ["error", "code"]) == -32_602
    assert get_in(broadening_response, ["error", "data", "reason"]) == "child_scope_outside_phase"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-BROADENING")
  end

  test "phase architect child glob scope rejects encoded backslash traversal", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-ENCODED-BACKSLASH-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["elixir/**"]
      )

    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-ENCODED-BACKSLASH-TRAVERSAL",
          "title" => "Encoded backslash traversal child",
          "allowed_file_globs" => ["elixir/lib%5c..%5cpriv/**"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "path_traversal_allowed_file_globs"

    assert {:error, :not_found} =
             WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-ENCODED-BACKSLASH-TRAVERSAL")
  end

  test "phase architect child glob scope rejects encoded separator broadening", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-ENCODED-SEPARATOR-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["elixir/*"]
      )

    encoded_slash_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-ENCODED-SLASH-BROADENING",
          "title" => "Encoded slash broadening child",
          "allowed_file_globs" => ["elixir/lib%2fsecret"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(encoded_slash_response, ["error", "code"]) == -32_602
    assert get_in(encoded_slash_response, ["error", "data", "reason"]) == "invalid_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-ENCODED-SLASH-BROADENING")

    encoded_backslash_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-ENCODED-BACKSLASH-BROADENING",
          "title" => "Encoded backslash broadening child",
          "allowed_file_globs" => ["elixir/lib%5csecret"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(encoded_backslash_response, ["error", "code"]) == -32_602
    assert get_in(encoded_backslash_response, ["error", "data", "reason"]) == "invalid_allowed_file_globs"

    assert {:error, :not_found} =
             WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-ENCODED-BACKSLASH-BROADENING")
  end

  test "phase architect child glob scope rejects child double-star missing required anchor suffix", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-GLOB-SUFFIX-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["foo/**/bar"]
      )

    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-MISSING-SUFFIX",
          "title" => "Missing suffix child",
          "allowed_file_globs" => ["foo/**"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "child_scope_outside_phase"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-MISSING-SUFFIX")
  end

  test "phase architect can narrow wildcard child globs inside wildcard anchor globs", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-WILDCARD-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["elixir/*/foo/*.ex"]
      )

    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-WILDCARD-CHILD",
          "title" => "Wildcard narrowed child",
          "allowed_file_globs" => ["elixir/lib/foo/*.ex"],
          "acceptance_criteria" => ["Child wildcard scope stays inside anchor glob"]
        }
      })

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == "SYMPP-P7-002-WILDCARD-CHILD"
    assert {:ok, child} = WorkPackageRepository.get(repo, "SYMPP-P7-002-WILDCARD-CHILD")
    assert child.allowed_file_globs == ["elixir/lib/foo/*.ex"]
  end

  test "phase architect mints child worker grant and worker is isolated to child package", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-CHILD")
    sibling_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-SIBLING")

    mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    assert get_in(mint_response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child_id
    assert get_in(mint_response, ["result", "structuredContent", "worker_grant", "grant_role"]) == "worker"

    assert get_in(mint_response, ["result", "structuredContent", "worker_grant", "capabilities"]) == [
             "worker:claim",
             "worker:lifecycle.transition"
           ]

    worker_grant = get_in(mint_response, ["result", "structuredContent", "worker_grant"])
    refute Map.has_key?(worker_grant, "secret")
    refute Map.has_key?(worker_grant, "secret_returned_once")
    assert worker_grant["secret_in_response"] == false
    refute Map.has_key?(worker_grant, "secret_handoff")

    bootstrap = worker_grant["worker_bootstrap"]
    assert bootstrap["type"] == "ledger_claim"
    assert bootstrap["mode"] == "local_assignment"
    assert_same_ledger_database(bootstrap["ledger"], current_main_database_path(repo))
    assert bootstrap["claim"]["tool"] == "claim_local_assignment"

    assert bootstrap["claim"]["arguments"] == %{
             "work_package_id" => child_id,
             "claimed_by" => "sympp-child-worker:#{child_id}"
           }

    assert bootstrap["claim"]["required_runtime_arguments"] == []

    content_text = get_in(mint_response, ["result", "content", Access.at(0), "text"])
    refute content_text =~ ~s("secret":)
    refute content_text =~ "secret_returned_once"
    assert content_text =~ "worker_bootstrap"
    assert content_text =~ "claim_local_assignment"
    assert content_text =~ "sympp-child-worker:#{child_id}"

    worker_session = claim_child_worker_from_mint_response(repo, mint_response, "sympp-child-worker:#{child_id}")

    assignment_response = mcp_tool(repo, worker_session, "get_current_assignment", %{})
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == child_id
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "phase_id"]) == nil

    own_resource_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "read-child-task-plan",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{child_id}/task_plan.md"}
        },
        repo: repo,
        session: worker_session
      )

    assert get_in(own_resource_response, ["result", "contents", Access.at(0), "text"]) =~ child_id

    sibling_resource_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "read-sibling-task-plan",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{sibling_id}/task_plan.md"}
        },
        repo: repo,
        session: worker_session
      )

    assert get_in(sibling_resource_response, ["error", "code"]) == -32_003
    assert get_in(sibling_resource_response, ["error", "data", "reason"]) == "outside_session_scope"

    child_status_response =
      mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => child_id})

    assert get_in(child_status_response, ["result", "structuredContent", "work_package", "id"]) == child_id
    assert get_in(child_status_response, ["result", "structuredContent", "work_package", "status"]) == "active"
  end
end
