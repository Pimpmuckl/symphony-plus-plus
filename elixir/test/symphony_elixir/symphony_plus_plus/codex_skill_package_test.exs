Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog

  test "skill package has required metadata and worker MCP workflow" do
    skill = File.read!(@skill_path)

    assert skill =~ "name: symphony-work-package"
    assert skill =~ "description:"

    for marker <- [
          "WorkPackage state adapter",
          "symphony-plus-plus:symphony-worker",
          "get_current_assignment()",
          "read_context()",
          "read_task_plan()",
          "update_task_plan",
          "append_finding",
          "append_progress",
          "create_guidance_request",
          "attach_branch",
          "attach_pr",
          "submit_review_package",
          "complete_review",
          "mark_ready()"
        ] do
      assert skill =~ marker
    end

    assert skill =~ ~s({"work_package_id":"<WP id>"})
    refute skill =~ "claim_work_key"
    refute skill =~ "claim_private_handoff"
    assert skill =~ "Do not create local `task_plan.md`, `findings.md`, or `progress.md` files as"
    assert skill =~ "Worker grants and local claim leases are scoped to exactly one WorkPackage."
    refute skill =~ "add_comment(target_kind, target_id, body, idempotency_key)"
    refute skill =~ "resolve_comment(comment_id, resolution, idempotency_key)"
    refute skill =~ "request_context"
  end

  test "MCP plugin skills and docs make delivery closeout the default" do
    architect_skill = @mcp_plugin_architect_skill_path |> File.read!() |> normalize_newlines()
    worker_skill = @mcp_plugin_skill_path |> File.read!() |> normalize_newlines()
    skill_contract = @mcp_skill_contract_path |> File.read!() |> normalize_newlines()
    dashboard_spec = @dashboard_spec_path |> File.read!() |> normalize_newlines()
    closeout_runbook = @closeout_runbook_path |> File.read!() |> normalize_newlines()

    for marker <- [
          "## Delivery Closeout",
          "WR delivery board",
          "Decisions are rationale",
          "Delivery closeout records lifecycle truth",
          "read_delivery_board",
          "record_work_package_delivery",
          "reconcile_work_request",
          "PR-size or line-budget",
          "cleanup_work_request_work_package_runtime"
        ] do
      assert architect_skill =~ marker
    end

    for marker <- [
          "Stay inside the assigned WorkPackage",
          "Worker grants and local claim leases are scoped to exactly one WorkPackage."
        ] do
      assert worker_skill =~ marker
    end

    for marker <- [
          "read_delivery_board(work_request_id)",
          "record_work_package_delivery(work_request_id, work_package_id, outcome, idempotency_key, evidence)",
          "`completed_no_pr`",
          "`evidence.completed_no_pr`",
          "`superseded`",
          "`evidence.superseded`",
          "`reconcile_work_request`",
          "PR/GitHub evidence",
          "WORK_REQUEST_DELIVERY_CLOSEOUT.md"
        ] do
      assert skill_contract =~ marker
    end

    for marker <- ["Delivery closeout", "stale `ready_for_worker` package", "`ready_for_worker`"] do
      assert dashboard_spec =~ marker
    end

    for marker <- [
          "Kraken-Style Stale Delivery-Board Verification",
          "`ready_for_worker`",
          "Expected projection before closeout",
          "Expected projection after closeout",
          "record_work_package_delivery"
        ] do
      assert closeout_runbook =~ marker
    end
  end

  test "MCP contract and packaged skills document compact worker calls" do
    contract = @contract_path |> File.read!() |> Jason.decode!()
    readable_contract = @contract_path |> Path.dirname() |> Path.join("MCP_TOOLS_CONTRACT.md") |> File.read!() |> normalize_newlines()
    skill_contract = @mcp_skill_contract_path |> File.read!() |> normalize_newlines()
    worker_skill = @mcp_plugin_skill_path |> File.read!() |> normalize_newlines()
    template_skill = @template_skill_path |> File.read!() |> normalize_newlines()

    prompts = [
      File.read!(@template_prompt_path),
      File.read!(Path.join(@repo_root, "implementation_docs_symphplusplus/templates/worker_agent_prompt.md")),
      File.read!(Path.join(@template_references_dir, "worker_prompt.md")),
      File.read!(@mcp_plugin_prompt_path)
    ]

    tool_schemas = Map.new(contract["tool_schemas"], &{&1["name"], &1})

    assert "blocker_closeout" in get_in(tool_schemas, ["set_status", "optional_arguments"])
    assert get_in(tool_schemas, ["mark_ready", "optional_arguments"]) == ["blocker_closeout"]
    assert get_in(tool_schemas, ["complete_review", "optional_arguments"]) == ["note", "reference", "work_package_id"]

    assert get_in(tool_schemas, ["attach_branch", "worker_required_arguments_by_branch_pattern", "literal"]) == ["head_sha"]
    assert get_in(tool_schemas, ["attach_branch", "worker_required_arguments_by_branch_pattern", "templated_or_absent"]) == ["branch", "head_sha"]

    assert get_in(tool_schemas, ["add_comment", "worker_compact_policy"]) =~ "body-only"
    assert get_in(tool_schemas, ["list_comments", "worker_compact_policy"]) =~ "empty argument object"
    assert get_in(tool_schemas, ["sync_pr", "attached_pr_policy"]) =~ "already attached PR"
    assert get_in(tool_schemas, ["sync_pr", "required_arguments"]) == []
    assert get_in(tool_schemas, ["sync_pr", "required_argument_sets"]) == []
    assert "recovery" in get_in(tool_schemas, ["sync_pr", "optional_arguments"])

    for tool <- [
          "update_task_plan",
          "append_finding",
          "append_progress",
          "set_status",
          "report_blocker",
          "resolve_blocker",
          "add_comment",
          "list_comments",
          "resolve_comment",
          "create_guidance_request",
          "read_guidance_request",
          "request_scope_expansion",
          "attach_branch",
          "attach_pr",
          "sync_pr",
          "submit_review_package",
          "complete_review"
        ] do
      worker_schema = ToolCatalog.worker_tool_input_schema(tool)

      refute "work_package_id" in Map.keys(worker_schema["properties"])
    end

    assert get_in(tool_schemas, ["add_comment", "required_arguments"]) == ["body", "target_id", "target_kind"]
    assert get_in(tool_schemas, ["list_comments", "required_arguments"]) == ["target_id", "target_kind"]

    for tool <- ["resolve_blocker", "add_comment", "list_comments", "resolve_comment", "read_guidance_request"] do
      assert "work_package_id" in get_in(tool_schemas, [tool, "optional_arguments"])
    end

    for tool <- [
          "update_task_plan",
          "append_finding",
          "append_progress",
          "set_status",
          "report_blocker",
          "create_guidance_request",
          "request_scope_expansion",
          "attach_branch",
          "attach_pr",
          "sync_pr",
          "submit_review_package",
          "complete_review"
        ] do
      assert "work_package_id" in get_in(tool_schemas, [tool, "optional_arguments"])
    end

    assert get_in(contract, ["discovery_policy", "trusted_local_http_extra_tools"]) == [
             "create_work_request",
             "add_work_request_comment",
             "list_comments",
             "record_work_request_operator_decision"
           ]

    for content <- [readable_contract, skill_contract, worker_skill, template_skill] do
      assert content =~ "add_comment(body)"
      assert content =~ "list_comments()"
      assert content =~ "attach_branch(head_sha)"
      assert content =~ "complete_review(reference?, note?)"
      assert content =~ "sync_pr()"
      assert content =~ "blocker_closeout"
      assert content =~ "attached PR"
      refute content =~ "sync_pr(metadata, url|number)"
      refute content =~ "sync_pr(url_or_number, metadata)"
      refute content =~ "add_comment(target_kind, target_id, body"
      refute content =~ "list_comments(target_kind, target_id"
    end

    for prompt <- prompts do
      assert prompt =~ "attached PR"
      assert prompt =~ "attach_branch(head_sha)"
      assert prompt =~ "sync_pr()"
      assert prompt =~ "complete_review(reference?, note?)"
      assert prompt =~ "blocker_closeout"
      refute prompt =~ "sync_pr(metadata, url|number)"
      refute prompt =~ "sync_pr(url_or_number, metadata)"
    end

    assert readable_contract =~ "create_work_request\nadd_work_request_comment\nlist_comments\nrecord_work_request_operator_decision"
  end

  test "worker prompt is paste-ready and MCP-backed" do
    prompt = File.read!(@prompt_path)
    plugin_prompt = File.read!(@mcp_plugin_prompt_path)
    template_prompt = File.read!(@template_prompt_path)
    template_reference_prompt = File.read!(Path.join(@template_references_dir, "worker_prompt.md"))

    for content <- [prompt, plugin_prompt, template_prompt, template_reference_prompt] do
      assert String.starts_with?(content, "You are assigned Symphony++ work package")
      assert content =~ "<WORK_PACKAGE_ID>"
      assert content =~ "Ledger claim: call `claim_local_assignment`"
      assert content =~ "Worker branch: <PREPARED_BRANCH>"
      assert content =~ "Worktree path: <PREPARED_WORKTREE_PATH>"
      assert content =~ ~s({"work_package_id":"<WORK_PACKAGE_ID>"})
      assert content =~ "update_task_plan(patch, expected_version)"
      assert content =~ "resolve_blocker(blocker_id, resolution, summary, idempotency_key)"
      assert content =~ "request_scope_expansion(summary, idempotency_key, payload)"
      assert content =~ "attach_pr(url, head_sha)"
      assert content =~ "Do not create local planning files as the WorkPackage source of truth."
      assert content =~ "Do not use broad Linear/GitHub state as permission authority."
      refute content =~ "attach_pr(pr_url"
      refute content =~ "Work key handoff:"
      refute content =~ "Handoff target:"
      refute content =~ "Worker branch: agent/<WORK_PACKAGE_ID>/<short-slug>"
      refute content =~ "```"
      refute content =~ "request_context"
    end
  end

  test "MCP wiring docs explain the local HTTP dependency without embedding secrets" do
    wiring = File.read!(@wiring_path)
    plugin_wiring = File.read!(@mcp_plugin_wiring_path)
    template_wiring = File.read!(Path.join(@template_references_dir, "mcp_wiring.md"))

    assert wiring =~ "http://127.0.0.1:19998/mcp"
    assert wiring =~ "mix sympp.cockpit"
    assert wiring =~ "$HOME/.agents/splusplus/symphony_plus_plus.sqlite3"
    assert wiring =~ "--port 0"
    assert wiring =~ "[mcp_servers.symphony_plus_plus]"
    assert wiring =~ "command = \"cmd.exe\""
    assert wiring =~ "scripts/start-sympp-mcp.cmd"
    assert wiring =~ ~s(`work_package_id`)
    assert wiring =~ "optional `claimed_by`"
    refute wiring =~ "sympp-worker-secret.ps1"
    refute wiring =~ "sympp-worker-secret.sh"
    refute wiring =~ "run-mcp-local-file-once"
    refute wiring =~ "--work-key-secret-env"
    prose_wiring = normalize_prose(wiring)

    assert prose_wiring =~ "should not embed bearer tokens"
    assert wiring =~ "generic Codex sessions, review-suite lanes, and `codex review`"
    assert prose_wiring =~ "open a new session before treating stale skill metadata"
    assert wiring =~ "cache/plugin adoption happens only at final feature-branch cutover"
    assert wiring =~ "Do not refresh user-local plugin caches as part of normal feature-branch"
    assert wiring =~ "Skill visibility, explicit MCP configuration, global MCP settings"
    assert prose_wiring =~ "must not declare `mcpServers`"
    assert wiring =~ "That server may not appear"
    assert plugin_wiring == wiring
    assert template_wiring == wiring
    refute wiring =~ "sympp_live_"
  end

  test "worker secret wrappers are no longer packaged" do
    contract = File.read!(@contract_path)

    refute File.exists?(@worker_secret_script_path)
    refute File.exists?(@worker_secret_shell_path)
    refute contract =~ "run-mcp-local-file-once"
    refute contract =~ "claim_work_key"
    refute contract =~ "claim_private_handoff"
  end

  test "Codex plugin package exposes MCP-free base skills" do
    manifest =
      @plugin_manifest_path
      |> File.read!()
      |> Jason.decode!()

    marketplace =
      @marketplace_path
      |> File.read!()
      |> Jason.decode!()

    assert manifest["name"] == "symphony-plus-plus"
    assert manifest["version"] == @plugin_version
    assert Version.compare(@plugin_version, "0.1.1") == :gt
    assert manifest["skills"] == "./skills/"
    refute Map.has_key?(manifest, "mcpServers")
    assert manifest["interface"]["displayName"] == "Symphony++"
    assert manifest["interface"]["category"] == "Developer Tools"
    assert manifest["interface"]["composerIcon"] == "./assets/splusplus-logo.png"
    assert manifest["interface"]["logo"] == "./assets/splusplus-logo.png"
    assert manifest["description"] =~ "MCP-free"
    assert manifest["description"] =~ "worker/coordinator"
    assert manifest["interface"]["shortDescription"] =~ "MCP-free"
    refute manifest["description"] =~ "WorkPackage"
    refute manifest["interface"]["shortDescription"] =~ "WorkPackage"
    refute File.exists?(@plugin_mcp_path)
    assert File.exists?(@plugin_skills_dir)
    refute File.exists?(@plugin_legacy_skills_dir)
    assert File.exists?(@plugin_icon_path)
    assert File.read!(@plugin_default_solo_skill_path) =~ "name: symphony-solo-session"
    assert File.read!(@plugin_default_solo_skill_path) =~ "ordinary single-agent work, non-MCP worker tasks"
    assert File.read!(@plugin_default_solo_skill_path) =~ "symphony-work-package"
    assert File.read!(@plugin_default_worker_skill_path) =~ "name: symphony-worker"
    assert File.read!(@plugin_default_worker_skill_path) =~ "Each worker uses its own session"
    assert File.read!(@plugin_default_worker_skill_path) =~ "symphony-plus-plus-mcp:symphony-work-package"
    assert File.read!(@plugin_default_coordinator_skill_path) =~ "name: symphony-coordinator"
    assert File.read!(@plugin_default_coordinator_skill_path) =~ "Do not share that session with workers"
    assert File.read!(@plugin_solo_script_path) =~ "mix sympp.solo"
    assert File.read!(@plugin_solo_script_path) =~ "not the caller/task repo"
    assert File.read!(@plugin_solo_script_path) =~ "marketplace snapshot"
    assert File.read!(@plugin_solo_script_path) =~ ".sympp-source-root hints are ignored"
    refute File.read!(@plugin_solo_script_path) =~ "Resolve-RepoRootFromCacheHints"
    refute File.read!(@plugin_solo_script_path) =~ "Resolve-DefaultDatabase"
    refute File.read!(@plugin_solo_script_path) =~ "solo-sessions.sqlite3"
    assert File.read!(@plugin_default_solo_skill_path) =~ "Do not set `SYMPP_REPO_ROOT` to the caller/task repository"
    assert File.read!(@mcp_plugin_solo_script_path) =~ "not the caller/task repo"
    assert File.read!(@mcp_plugin_solo_script_path) =~ "marketplace snapshot"
    assert File.read!(@mcp_plugin_solo_script_path) =~ ".sympp-source-root hints are ignored"
    refute File.read!(@mcp_plugin_solo_script_path) =~ "Resolve-RepoRootFromCacheHints"
    refute File.read!(@mcp_plugin_solo_script_path) =~ "Resolve-DefaultDatabase"
    refute File.read!(@mcp_plugin_solo_script_path) =~ "solo-sessions.sqlite3"
    assert File.read!(@plugin_solo_script_path) == File.read!(@mcp_plugin_solo_script_path)
    assert File.read!(@plugin_solo_script_path) =~ "Resolve-UsageScriptPath"
    refute File.read!(@plugin_solo_script_path) =~ "pwsh plugins/symphony-plus-plus/scripts/sympp-solo.ps1"
    refute File.read!(@plugin_solo_script_path) =~ "pwsh plugins/symphony-plus-plus-mcp/scripts/sympp-solo.ps1"

    assert Enum.any?(marketplace["plugins"], fn plugin ->
             plugin["name"] == "symphony-plus-plus" and
               plugin["source"] == %{"source" => "local", "path" => "./plugins/symphony-plus-plus"} and
               plugin["category"] == "Developer Tools"
           end)

    assert Enum.any?(marketplace["plugins"], fn plugin ->
             plugin["name"] == "symphony-plus-plus-mcp" and
               plugin["source"] == %{"source" => "local", "path" => "./plugins/symphony-plus-plus-mcp"} and
               plugin["category"] == "Developer Tools"
           end)

    assert File.exists?(@refresh_script_path)
    refute File.exists?(@worker_secret_script_path)
    refute File.exists?(@worker_secret_shell_path)
    assert File.read!(@plugin_readme_path) =~ ~s("path": "./plugins/symphony-plus-plus")
    assert File.read!(@plugin_readme_path) =~ "manifest-version cache"
    assert File.read!(@plugin_readme_path) =~ "codex plugin marketplace upgrade"
    assert File.read!(@plugin_readme_path) =~ "isolated development Codex homes only"
    assert File.read!(@plugin_readme_path) =~ "intentionally skill-only"
    assert File.read!(@plugin_readme_path) =~ "does not declare `mcpServers`"
    assert File.read!(@plugin_readme_path) =~ "standard root `skills/` directory"
    assert File.read!(@plugin_readme_path) =~ "`codex review`"
    assert File.read!(@plugin_readme_path) =~ "plugins/symphony-plus-plus-mcp"
    assert File.read!(@plugin_readme_path) =~ "diagnose-mcp-lifecycle.ps1"
    assert File.read!(@plugin_readme_path) =~ "local HTTP daemon"
    assert File.read!(@plugin_readme_path) =~ "local bridge lease"
    assert File.read!(@plugin_readme_path) =~ "exact S++ source revision"
    assert File.read!(@plugin_readme_path) =~ "last bridge lease for a runtime key"
    assert File.read!(@plugin_readme_path) =~ "diagnostic truncates and redacts"
    assert File.read!(@plugin_readme_path) =~ "Live process counts are scoped to `-RepoRoot`"
    assert File.read!(@plugin_readme_path) =~ "marketplace source clone"
    assert File.read!(@plugin_readme_path) =~ "prunes removed managed skill directories"
    assert File.read!(@plugin_readme_path) =~ "prunes the\nolder generated `local` cache root"
    assert File.read!(@plugin_readme_path) =~ "Superseded version directories"
    assert File.read!(@plugin_readme_path) =~ "The diagnostic rejects `-RepoRoot`"
    assert File.read!(@plugin_readme_path) =~ "multiple marketplace clones"
    assert File.read!(@plugin_readme_path) =~ "reported separately as unattributed"
    assert File.read!(@plugin_readme_path) =~ "opt-in\n`mise exec -- mix` launcher path"
    assert File.read!(@plugin_readme_path) =~ "Malformed installed cache JSON is reported"
    assert File.read!(@plugin_readme_path) =~ "scans every `symphony-plus-plus` marketplace cache"
    assert File.read!(@plugin_readme_path) =~ "manifest lifecycle status"
    assert File.read!(@plugin_readme_path) =~ "incompatible_default_plugin_bundles_mcp"
    assert File.read!(@plugin_readme_path) =~ "missing_manifest"
    assert File.read!(@plugin_readme_path) =~ "reporting machine-wide processes"
    assert File.read!(@plugin_readme_path) =~ "defines the expected\n`symphony_plus_plus` command-backed launcher"
    assert File.read!(@plugin_readme_path) =~ "process scan as unsupported"
    assert File.read!(@plugin_readme_path) =~ "Default Planning And Opt-In MCP"
    assert File.read!(@plugin_readme_path) =~ "symphony-plus-plus:symphony-solo-session"
    assert File.read!(@plugin_readme_path) =~ "sympp-solo.ps1 -ValidateOnly"
    assert File.read!(@plugin_readme_path) =~ "http://127.0.0.1:19998/mcp"
    assert File.read!(@plugin_readme_path) =~ "codex --profile sympp-agent app <path>"
    assert File.read!(@plugin_readme_path) =~ "subprocess/app-server session"
    assert File.read!(@plugin_readme_path) =~ "supported replacement for app-visible"
    assert File.read!(@plugin_readme_path) =~ "Solo/cockpit handoff path"
    assert File.read!(@plugin_readme_path) =~ "shared local Symphony++ default ledger"
    assert File.read!(@plugin_readme_path) =~ "Solo caller repository identity comes from the CLI arguments"
    assert File.read!(@plugin_readme_path) =~ "diagnose-mcp-lifecycle.ps1 -Doctor"
    assert File.read!(@plugin_readme_path) =~ "solo_ready_mcp_companion_not_enabled"
    assert File.read!(@plugin_readme_path) =~ "symphony-plus-plus-mcp@<marketplace>"
    assert File.read!(@plugin_readme_path) =~ "-EnableMcpCompanion"
    assert File.read!(@plugin_readme_path) =~ "-CodexHome <dedicated-codex-home>"
    assert File.read!(@plugin_readme_path) =~ ".sympp-generated-cache"
    assert File.read!(@plugin_readme_path) =~ "refuses the default `~/.codex` cache"
    assert File.read!(@plugin_readme_path) =~ "cannot inspect the tool list already registered"
    assert File.read!(@plugin_readme_path) =~ "codex plugin marketplace upgrade"
    assert File.read!(@plugin_readme_path) =~ "no longer uses `.sympp-source-root`"
    assert File.read!(@plugin_readme_path) =~ "smoke-sympp-mcp-http.ps1 -RepoRoot ."

    assert File.read!(@plugin_default_solo_skill_path) =~
             "lightweight parent coordination"

    refute File.read!(@plugin_readme_path) =~ "../../Code/"
    assert File.read!(@refresh_script_path) =~ "ReparsePoint"
    assert File.read!(@refresh_script_path) =~ "ValidateInstalledCache"
    assert File.read!(@refresh_script_path) =~ "Invoke-InstalledCacheValidation"
    assert File.read!(@refresh_script_path) =~ "$PluginName = \"all\""
    assert File.read!(@refresh_script_path) =~ "SymppPluginPackageNames"
    assert File.read!(@refresh_script_path) =~ "PSObject.Properties.Name) -contains \"mcpServers\""
    assert File.read!(@refresh_script_path) =~ "scripts/sympp-solo.ps1"
    assert File.read!(@refresh_script_path) =~ "legacy skills-default directory"
    assert File.read!(@refresh_script_path) =~ "\"assets\""
    assert File.read!(@refresh_script_path) =~ "Remove-GeneratedLocalCacheEntry"
    assert File.read!(@refresh_script_path) =~ "Removed stale generated Symphony++ local plugin cache"
    assert File.read!(@refresh_script_path) =~ "Unmarked local plugin cache entry still exists"
    refute File.read!(@refresh_script_path) =~ "local target:"
    assert File.read!(@refresh_script_path) =~ "Repair-IncompatibleDefaultPluginCacheEntries"
    assert File.read!(@refresh_script_path) =~ "Sync-ManagedDirectoryChildren"
    assert File.read!(@refresh_script_path) =~ "Installed plugin MCP launcher validation failed"
    assert File.read!(@refresh_script_path) =~ "Default installed plugin cache must not contain root .mcp.json"
    assert File.read!(@refresh_script_path) =~ "Run the activation doctor"
    assert File.read!(@refresh_script_path) =~ "Get-AvailablePowerShellCommandName"
    assert File.read!(@refresh_script_path) =~ "Quote-PowerShellLiteral $doctorScript"
    assert File.read!(@refresh_script_path) =~ "-CodexHome $(Quote-PowerShellLiteral $codexHomePath)"
    assert File.read!(@refresh_script_path) =~ "-MarketplaceName $(Quote-PowerShellLiteral $marketplaceName)"
    refute File.read!(@refresh_script_path) =~ " -File plugins\\symphony-plus-plus"

    lifecycle_diagnostic = File.read!(@plugin_lifecycle_diagnostic_path)

    assert File.exists?(@plugin_lifecycle_diagnostic_path)

    for marker <- [
          "start-sympp-mcp.ps1",
          "sympp\\.mcp --mode stdio",
          "Resolve-ComparableFileSystemPath",
          "Update-TomlMultilineStringState",
          "New-CurrentDiagnosticCommand",
          "installed_cache = @($cachePackages)",
          "live_repo_roots = @($repoRoots)",
          "launcher_parents = @($launcherParents)",
          "repo_root_filter = $RepoRoot",
          "other_marketplace_mcp_companion_enabled",
          "RepoRoot does not look like a Symphony++ checkout",
          "mise_sympp_mcp = $miseProcesses.Count",
          "Find-AncestorLauncherProcessIds",
          "foreach ($processId in $found)",
          "Find-TomlBooleanKeyAssignment",
          "$filterAnchorProcesses",
          "manifest_parse_error",
          "mcp_parse_error",
          "manifest_mcpServers_declared",
          "manifest_exists",
          "default_plugin_lifecycle_status",
          "symphony-plus-plus-mcp",
          "package_name",
          "package.marketplace_name",
          "ready_priority",
          "version_sort_key",
          "current_working_directory",
          "multiple_marketplaces_need_selection",
          "relocate_global_sympp_mcp_entry",
          "-CodexHome $(Quote-PowerShellLiteral $CodexHomePath)",
          "$($package.marketplace_name)/$($package.package_name)/$($package.label)",
          "opt_in_mcp_plugin_bundles_mcp",
          "reference_mcp_server_status",
          "invalid_url",
          "invalid_mixed_http_stdio",
          "non_default_http_url",
          "http_mcp_reachability_status",
          "mcp_endpoint_available",
          "unexpected_http_status_",
          "unreachable",
          "invalid_cwd",
          "invalid_args",
          "Test-CachePackageIsCurrentForProcessScope",
          "Test-CachePackageCanScopeProcesses",
          "missing_manifest",
          "incompatible_default_plugin_bundles_mcp",
          "symphony_plus_plus_server",
          "process_scan_scope",
          "skipped_no_repo_root_scope",
          "skipped_ambiguous_marketplace_source_clones",
          "installed_cache_marketplace_source_clone",
          "directLauncherProcesses",
          "start_sympp_mcp_pwsh_unattributed",
          "unattributed_launcher_parents",
          "MarketplaceName = \"*\"",
          "[System.Boolean]::Parse",
          "Get-ReadinessSummary",
          "solo_ready_mcp_companion_not_enabled",
          "Get-ActivationConfigKey",
          "EnableMcpCompanion",
          "Set-PluginEnabledInConfig",
          "sympp-backup",
          "Keep symphony-plus-plus-mcp out of generic worker",
          "ready_via_mcp_companion",
          "session_visibility_note"
        ] do
      assert lifecycle_diagnostic =~ marker
    end

    for helper_name <- @plugin_lifecycle_diagnostic_helper_names do
      helper_path = Path.join(Path.dirname(@plugin_lifecycle_diagnostic_path), helper_name)
      assert File.exists?(helper_path)
    end

    diagnostic_self_test =
      @plugin_lifecycle_diagnostic_path
      |> Path.dirname()
      |> Path.join("sympp-diagnostic-self-test.ps1")
      |> File.read!()

    assert diagnostic_self_test =~ "diagnose-mcp-lifecycle self-test passed"
    assert diagnostic_self_test =~ "quoted boolean key"

    assert File.read!(@refresh_script_path) =~
             "Assert-ExistingCachePathNotReparsePoint @($codexHomePath, $pluginsRoot, $cacheRoot, $marketplaceCacheRoot, $pluginCacheRoot)"

    assert File.read!(@refresh_script_path) =~ "Assert-NoReparsePointDescendants $TargetRoot"
    assert File.read!(@refresh_script_path) =~ "Assert-NotReparsePoint $target"
    assert File.read!(@refresh_script_path) =~ "Assert-NoReparsePointDescendants $target"
    assert File.read!(@refresh_script_path) =~ ".sympp-generated-cache"
    assert File.read!(@refresh_script_path) =~ "Refusing to refresh the default Codex plugin cache"
    refute File.read!(@refresh_script_path) =~ "Remove-Item -LiteralPath $TargetRoot -Recurse"
    assert File.read!(@refresh_script_path) =~ "Refusing to refresh reparse-point plugin cache directory"
    assert File.read!(@refresh_script_path) =~ "Refusing to refresh plugin cache directory containing a reparse-point child"
  end

  test "Codex plugin package is physically MCP-free by default" do
    manifest =
      @plugin_manifest_path
      |> File.read!()
      |> Jason.decode!()

    assert manifest["name"] == "symphony-plus-plus"
    refute Map.has_key?(manifest, "mcpServers")
    refute File.exists?(@plugin_mcp_path)
  end

  test "opt-in MCP plugin package carries full skill set and bundled server wiring" do
    manifest =
      @mcp_plugin_manifest_path
      |> File.read!()
      |> Jason.decode!()

    mcp_config =
      @mcp_plugin_mcp_path
      |> File.read!()
      |> Jason.decode!()

    assert manifest["name"] == "symphony-plus-plus-mcp"
    assert manifest["version"] == @plugin_version
    assert manifest["skills"] == "./skills/"
    assert manifest["mcpServers"] == "./.mcp.json"
    assert manifest["description"] =~ "Full Symphony++ MCP-backed"
    assert manifest["interface"]["displayName"] == "Symphony++ MCP"
    assert manifest["interface"]["category"] == "Developer Tools"
    assert manifest["interface"]["composerIcon"] == "./assets/splusplus-logo.png"
    assert manifest["interface"]["logo"] == "./assets/splusplus-logo.png"
    assert File.read!(@mcp_plugin_icon_path) == File.read!(@plugin_icon_path)

    assert File.read!(@mcp_plugin_readme_path) =~ "`symphony-plus-plus` Codex plugin"
    assert File.read!(@mcp_plugin_readme_path) =~ "Do not enable this plugin in the normal global Codex config"
    assert File.read!(@mcp_plugin_readme_path) =~ "complete MCP-mode plugin"
    assert normalize_prose(File.read!(@mcp_plugin_readme_path)) =~ "Do not enable both packages in the same Codex home"
    assert File.read!(@mcp_plugin_readme_path) =~ "assets/splusplus-logo.png"
    assert File.read!(@mcp_plugin_readme_path) =~ "codex plugin add symphony-plus-plus-mcp@symphony-plus-plus"
    assert File.read!(@mcp_plugin_readme_path) =~ "codex plugin marketplace upgrade"
    assert File.read!(@mcp_plugin_readme_path) =~ "marketplace-installed plugin"
    assert File.read!(@mcp_plugin_readme_path) =~ "next MCP-enabled Codex session starts it again"
    assert File.read!(@mcp_plugin_readme_path) =~ "diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Doctor"
    assert File.read!(@mcp_plugin_readme_path) =~ "cannot inspect"
    assert File.read!(@mcp_plugin_readme_path) =~ "smoke-sympp-mcp-http.ps1 -RepoRoot ."
    assert File.read!(@mcp_plugin_readme_path) =~ "agent-facing MCP contract fingerprint"

    assert File.read!(@mcp_plugin_start_script_path) =~ "sympp.mcp"
    assert File.read!(@mcp_plugin_start_script_path) =~ "sympp-mcp-launcher-helpers.ps1"
    assert File.exists?(@mcp_plugin_helper_path)
    assert File.read!(@mcp_plugin_start_cmd_path) =~ "start-sympp-mcp.ps1"
    assert File.read!(@mcp_plugin_start_cmd_path) =~ "powershell.exe"
    assert File.read!(@mcp_plugin_start_cmd_path) =~ "-NonInteractive"
    assert File.read!(@mcp_plugin_start_cmd_path) =~ "goto :run_pwsh"
    refute File.read!(@mcp_plugin_start_cmd_path) =~ "if %ERRORLEVEL%==0 ("
    assert File.read!(@mcp_plugin_solo_script_path) =~ "sympp.solo"

    assert %{
             "symphony_plus_plus" => %{
               "type" => "stdio",
               "command" => "cmd.exe",
               "args" => ["/d", "/s", "/c", "scripts\\start-sympp-mcp.cmd"],
               "cwd" => ".",
               "startup_timeout_sec" => 360.0,
               "tool_timeout_sec" => 300.0
             }
           } = documented_mcp_server_map(mcp_config)

    server = documented_mcp_server_map(mcp_config)["symphony_plus_plus"]
    refute Map.has_key?(server, "url")

    serialized = Jason.encode!(manifest) <> Jason.encode!(mcp_config)
    refute serialized =~ "SYMPP_WORK_KEY_SECRET"
    refute serialized =~ "bearer"
    refute serialized =~ "token"
    refute serialized =~ "worker-secret"
  end

  @tag :ci_slow
  test "lifecycle diagnostic explains default skill visible but MCP companion not enabled" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-readiness-default-only-#{System.unique_integer([:positive])}")

    if powershell do
      default_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])

      companion_manifest_path =
        plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

      companion_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => @plugin_version}))

        File.mkdir_p!(Path.dirname(companion_manifest_path))

        File.write!(
          companion_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_mcp_path,
          command_mcp_config_json()
        )

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@jonat-local"]
          enabled = true
          """
        )

        {json_output, json_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-SkipProcessScan",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert json_status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["overall_status"] == "plugin_cache_stale"
        assert readiness["solo_session"]["status"] == "default_plugin_cache_stale"
        assert readiness["workrequest_mcp"]["status"] == "companion_installed_not_enabled"
        assert readiness["workrequest_mcp"]["companion_config_key"] == "symphony-plus-plus-mcp@jonat-local"
        upgrade_action = Enum.find(readiness["next_actions"], &(&1["code"] == "upgrade_mcp_companion_cache"))
        assert upgrade_action
        assert_scoped_marketplace_upgrade!(upgrade_action["command"], temp_codex_home, "jonat-local")
        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))
        assert readiness["generic_review_boundary"] =~ "generic worker"

        {doctor_output, doctor_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Doctor"
            ],
            stderr_to_stdout: true
          )

        assert doctor_status == 0, doctor_output
        assert doctor_output =~ "overall: plugin_cache_stale"
        assert doctor_output =~ "config key: symphony-plus-plus-mcp@jonat-local"
        assert doctor_output =~ "upgrade_mcp_companion_cache"
        assert doctor_output =~ "restart or reload the dedicated MCP-enabled session"
        assert doctor_output =~ "Keep symphony-plus-plus-mcp out of generic worker"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  @tag :ci_slow
  test "lifecycle diagnostic self-test covers enable command TOML mutation shapes" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")

    if powershell do
      {output, status} =
        System.cmd(
          powershell,
          [
            "-NoProfile",
            "-File",
            @plugin_lifecycle_diagnostic_path,
            "-SelfTest"
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "diagnose-mcp-lifecycle self-test passed."
    end
  end

  @tag :ci_slow
  test "HTTP MCP smoke self-test covers source revision validation" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")

    if powershell do
      {output, status} =
        System.cmd(
          powershell,
          [
            "-NoProfile",
            "-File",
            @smoke_script_path,
            "-SelfTest"
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "PowerShell header normalization, source revision, redaction, and bound argument validation self-test passed."
    end
  end

  test "high-concurrency gate keeps its fast package contract" do
    powershell = System.find_executable("pwsh") || System.find_executable("powershell.exe") || System.find_executable("powershell")

    if powershell do
      test_script = Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/tests/end-to-end/run-performance-gate-tests.ps1")
      {output, status} = System.cmd(powershell, ["-NoProfile", "-File", test_script], stderr_to_stdout: true)

      assert status == 0, output
      assert output =~ "Performance gate parsing, structured output, threshold failures, and cutover contract passed."
    end
  end

  test "MCP contract pins the server-reported agent-facing contract fingerprint" do
    launcher = File.read!(@mcp_plugin_start_script_path)
    fingerprint = Server.mcp_contract_identity()["fingerprint"]
    contract = @contract_path |> File.read!() |> Jason.decode!()

    assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert contract["mcp_contract_fingerprint"] == fingerprint
    refute launcher =~ "$ExpectedMcpContractFingerprint"
    assert launcher =~ "Resolve-ExpectedMcpContractFingerprint"
  end

  test "MCP launcher keeps client lease heartbeat below the server lease ttl" do
    launcher = File.read!(@mcp_plugin_start_script_path)

    assert launcher =~ ~s(Get-EnvInteger "SYMPP_MCP_CLIENT_HEARTBEAT_SEC" 300 5 540)
  end
end
