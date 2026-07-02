Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.DeliveryReconcile02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  @moduletag :ci_slow

  test "WorkPackage worktree MCP tools fail closed outside linked WorkRequest scope", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WORKTREE-SCOPE", [
        "dispatch:work_request"
      ])

    assert {:ok, unlinked_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-WORKTREE-UNLINKED", kind: "mcp", base_branch: "main")
             )

    prepare_response =
      mcp_tool(repo, session, "prepare_work_package_worktree", %{
        "work_package_id" => unlinked_package.id,
        "target_repo_root" => test_repo_root()
      })

    assert get_in(prepare_response, ["error", "code"]) == -32_004
    assert get_in(prepare_response, ["error", "data", "reason"]) == "not_found"

    cleanup_response =
      mcp_tool(repo, session, "cleanup_work_package_worktree", %{
        "work_package_id" => unlinked_package.id,
        "target_repo_root" => test_repo_root()
      })

    assert get_in(cleanup_response, ["error", "code"]) == -32_004
    assert get_in(cleanup_response, ["error", "data", "reason"]) == "not_found"

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-PACKAGE-SCOPE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-PACKAGE-SCOPE",
                 title: "Out-of-scope worktree package",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/worktree",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_packages/**"],
                 acceptance_criteria: ["Keep worktree operations scoped."]
               )
             )

    assert {:ok, stale_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-STALE-SCOPE",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    assert {:ok, _linked_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", stale_package.id)

    assert {:ok, _drifted_package} =
             WorkPackageRepository.update(repo, stale_package.id, %{base_branch: "#{anchor.base_branch}-stale"})

    stale_prepare_response =
      mcp_tool(repo, session, "prepare_work_package_worktree", %{
        "work_package_id" => stale_package.id,
        "target_repo_root" => test_repo_root()
      })

    assert get_in(stale_prepare_response, ["error", "code"]) == -32_004
    assert get_in(stale_prepare_response, ["error", "data", "reason"]) == "not_found"

    stale_cleanup_response =
      mcp_tool(repo, session, "cleanup_work_package_worktree", %{
        "work_package_id" => stale_package.id,
        "target_repo_root" => test_repo_root()
      })

    assert get_in(stale_cleanup_response, ["error", "code"]) == -32_004
    assert get_in(stale_cleanup_response, ["error", "data", "reason"]) == "not_found"
  end

  test "WorkPackage worktree MCP prepare accepts linked package delivery base different from WorkRequest base", %{repo: repo} do
    delivery_base = "feature/kraken-batch-service-redesign"
    fixture = TestSupport.git_repo_fixture!(delivery_base, prefix: "sympp-mcp-delivery-base-worktree")
    codex_home = Path.join(fixture.root, "codex-home")
    config = Config.default(repo: repo, repo_root: test_repo_root())

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-DELIVERY-BASE",
        ["dispatch:work_request"],
        repo: fixture.origin
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-DELIVERY-BASE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced",
        repo_scopes: [%{repo: fixture.origin, base_branch: delivery_base}]
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-DELIVERY-BASE",
                 title: "Prepare integration delivery-base worktree",
                 target_base_branch: delivery_base,
                 branch_pattern: "feat/delivery-base-worktree",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_packages/**"],
                 acceptance_criteria: ["Prepare from the package delivery base."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-DELIVERY-BASE",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: work_request.repo,
                 base_branch: planned_slice.target_base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, _linked_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    {_delivery_anchor, delivery_scoped_session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-DELIVERY-BASE-SCOPED",
        ["dispatch:work_request"],
        repo: fixture.origin,
        base_branch: delivery_base
      )

    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      delivery_scoped_prepare_response =
        mcp_tool(
          repo,
          delivery_scoped_session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      assert get_in(delivery_scoped_prepare_response, ["error", "code"]) == -32_004
      assert get_in(delivery_scoped_prepare_response, ["error", "data", "reason"]) == "not_found"

      wrong_branch_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root,
            "branch" => "feat/wrong-delivery-base"
          },
          config: config
        )

      assert get_in(wrong_branch_response, ["error", "code"]) == -32_602
      assert get_in(wrong_branch_response, ["error", "data", "reason"]) == "branch_scope_mismatch"

      prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      prepare_payload = get_in(prepare_response, ["result", "structuredContent"])
      assert prepare_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}
      assert prepare_payload["worktree"]["status"] == "prepared"
      assert prepare_payload["worktree"]["base_branch"] == delivery_base
      assert prepare_payload["worker_launch"]["base_branch"] == delivery_base
      assert comparable_path(prepare_payload["worktree"]["target_repo_root"]) == comparable_path(fixture.repo_root)
      assert File.dir?(prepare_payload["worktree"]["path"])

      cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      cleanup_payload = get_in(cleanup_response, ["result", "structuredContent"])
      assert cleanup_payload["worktree"]["status"] == "cleaned"
      refute File.exists?(prepare_payload["worktree"]["path"])
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "WorkPackage worktree MCP prepare enforces templated branch patterns", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("symphony-plus-plus/beta", prefix: "sympp-mcp-template-worktree")
    codex_home = Path.join(fixture.root, "codex-home")
    config = Config.default(repo: repo, repo_root: test_repo_root())

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-TEMPLATE",
        ["dispatch:work_request"],
        repo: fixture.origin
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-TEMPLATE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-TEMPLATE",
                 title: "Prepare templated branch worktree",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "agent/{{work_package_id}}/{{slug}}",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
                 acceptance_criteria: ["Keep worktree branches inside the template scope."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-TEMPLATE",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: work_request.repo,
                 base_branch: planned_slice.target_base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, _linked_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      wrong_branch_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root,
            "branch" => "feat/out-of-template"
          },
          config: config
        )

      assert get_in(wrong_branch_response, ["error", "code"]) == -32_602
      assert get_in(wrong_branch_response, ["error", "data", "reason"]) == "branch_scope_mismatch"

      prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root,
            "branch" => "agent/#{package.id}/setup"
          },
          config: config
        )

      prepare_payload = get_in(prepare_response, ["result", "structuredContent"])
      assert prepare_payload["worktree"]["status"] == "prepared"

      cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{"work_package_id" => package.id},
          config: config
        )

      cleanup_payload = get_in(cleanup_response, ["result", "structuredContent"])
      assert cleanup_payload["worktree"]["status"] == "cleaned"
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "WorkPackage worktree MCP prepare rejects same-name owner conflicts", %{repo: repo} do
    target_repo_root =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/acme/frontend.git",
        prefix: "sympp-mcp-bare-scope-target"
      )

    previous_trusted_remotes = Application.get_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-BARE-REPO",
        ["dispatch:work_request"],
        repo: "frontend"
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-BARE-REPO",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-BARE-REPO",
                 title: "Prepare owner-scoped package worktree",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/bare-repo-worktree",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
                 acceptance_criteria: ["Reject same-name owner conflicts."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-BARE-REPO",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: work_request.repo,
                 base_branch: planned_slice.target_base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, _linked_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    try do
      Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, ["Pimpmuckl/frontend"])

      response =
        mcp_tool(repo, session, "prepare_work_package_worktree", %{
          "work_package_id" => package.id,
          "target_repo_root" => target_repo_root
        })

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == "target_repo_root_scope_mismatch"
    after
      restore_app_env(:sympp_repo_identity_trusted_remotes, previous_trusted_remotes)
    end
  end

  test "WorkPackage worktree MCP prepare accepts explicit bare target origins", %{repo: repo} do
    fixture =
      "symphony-plus-plus/beta"
      |> TestSupport.git_repo_fixture!(prefix: "sympp-mcp-bare-host-conflict-worktree")
      |> set_relative_owner_origin!("acme/frontend")

    target_repo_root = Path.join(fixture.root, "frontend")
    File.rename!(fixture.repo_root, target_repo_root)
    fixture = %{fixture | repo_root: target_repo_root}

    codex_home = Path.join(fixture.root, "codex-home")
    host_repo_root = Path.join(fixture.root, "symphony-plus-plus")
    other_host_repo_root = Path.join(fixture.root, "other-symphony-plus-plus")
    File.mkdir_p!(host_repo_root)

    config = Config.default(repo: repo, repo_root: host_repo_root)
    other_owner_config = Config.default(repo: repo, repo_root: other_host_repo_root)

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-HOST-CONFLICT",
        ["dispatch:work_request"],
        repo: "frontend"
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-HOST-CONFLICT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-HOST-CONFLICT",
                 title: "Prepare bare repo target without host conflicts",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/bare-host-conflict-worktree",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
                 acceptance_criteria: ["Do not let the MCP host checkout affect target repo scope."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-HOST-CONFLICT",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: work_request.repo,
                 base_branch: planned_slice.target_base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, _linked_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      host_checkout_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => host_repo_root
          },
          config: config
        )

      assert get_in(host_checkout_response, ["error", "data", "reason"]) == "target_repo_root_scope_mismatch"

      previous_trusted_remotes = Application.get_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)

      try do
        Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, ["other/frontend"])

        conflicting_checkout_response =
          mcp_tool(
            repo,
            session,
            "prepare_work_package_worktree",
            %{
              "work_package_id" => package.id,
              "target_repo_root" => fixture.repo_root
            },
            config: config
          )

        assert get_in(conflicting_checkout_response, ["error", "data", "reason"]) == "target_repo_root_scope_mismatch"
      after
        restore_app_env(:sympp_repo_identity_trusted_remotes, previous_trusted_remotes)
      end

      prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      prepare_payload = get_in(prepare_response, ["result", "structuredContent"])
      assert prepare_payload["worktree"]["status"] == "prepared"

      cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      cleanup_payload = get_in(cleanup_response, ["result", "structuredContent"])
      assert cleanup_payload["worktree"]["status"] == "cleaned"

      other_owner_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: other_owner_config
        )

      other_owner_payload = get_in(other_owner_response, ["result", "structuredContent"])
      assert other_owner_payload["worktree"]["status"] == "prepared"
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end
end
