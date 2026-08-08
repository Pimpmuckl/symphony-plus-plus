Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery

  test "documentation index links only current local files" do
    index_path = Path.join(@repo_root, "docs/README.md")
    index = File.read!(index_path)

    linked_paths =
      ~r/\]\(([^)#]+)(?:#[^)]+)?\)/
      |> Regex.scan(index, capture: :all_but_first)
      |> List.flatten()

    assert linked_paths != []

    for linked_path <- linked_paths do
      assert File.exists?(Path.expand(linked_path, Path.dirname(index_path))),
             "missing documentation index target: #{linked_path}"
    end

    refute index =~ "implementation_docs_symphplusplus"
  end

  test "MCP plugin skills make delivery closeout the default" do
    architect_skill = @mcp_plugin_architect_skill_path |> File.read!() |> normalize_newlines()
    worker_skill = @mcp_plugin_skill_path |> File.read!() |> normalize_newlines()

    for marker <- [
          "## Delivery Closeout",
          "WR delivery board",
          "Decisions are rationale",
          "Delivery closeout records lifecycle truth",
          "read_delivery_board",
          "record_work_package_delivery",
          "reconcile_work_request",
          "PR-size or line-budget",
          "cleanup_work_request_work_package_runtime",
          ~s({"pr_merged":{"pr_url":"...","pr_merged_at":"...","merge_commit_sha":"..."}}),
          ~s({"completed_no_pr":{"no_pr_evidence":"..."}}),
          ~s({"superseded":{"successor_work_package_id":"...","superseded_reason":"..."}}),
          ~s({"abandoned":{"abandoned_rationale":"..."}})
        ] do
      assert architect_skill =~ marker
    end

    for marker <- [
          "Stay inside the assigned WorkPackage",
          "Worker grants and local claim leases are scoped to exactly one WorkPackage."
        ] do
      assert worker_skill =~ marker
    end
  end

  test "delivery evidence schema exposes each concrete runtime contract" do
    evidence_schema =
      ToolCatalog.architect_tool_input_schema("record_work_package_delivery")
      |> get_in(["properties", "evidence"])

    assert length(evidence_schema["oneOf"]) == 4

    for outcome <- WorkPackageDelivery.outcomes() do
      assert branch = Enum.find(evidence_schema["oneOf"], &(&1["required"] == [outcome]))
      assert branch["additionalProperties"] == false

      typed_schema = get_in(branch, ["properties", outcome])
      field_specs = WorkPackageDelivery.evidence_field_specs(outcome)

      assert Map.keys(typed_schema["properties"]) |> Enum.sort() ==
               field_specs |> Enum.map(& &1.name) |> Enum.sort()

      assert typed_schema["required"] ==
               for(%{name: name, required: true} <- field_specs, do: name)
    end

    pr_merged_branch = Enum.find(evidence_schema["oneOf"], &(&1["required"] == ["pr_merged"]))

    assert get_in(pr_merged_branch, ["properties", "pr_merged", "required"]) == [
             "pr_url",
             "pr_merged_at",
             "merge_commit_sha"
           ]
  end

  test "runtime schemas and packaged worker skill agree on compact calls" do
    worker_skill = @mcp_plugin_skill_path |> File.read!() |> normalize_newlines()
    prompt = File.read!(@mcp_plugin_prompt_path)

    refute Map.has_key?(ToolCatalog.worker_tool_input_schema("set_status")["properties"], "blocker_closeout")
    assert ToolCatalog.worker_tool_input_schema("mark_ready")["properties"] == %{}
    assert Map.keys(ToolCatalog.worker_tool_input_schema("complete_review")["properties"]) |> Enum.sort() == ["note", "reference"]
    assert ToolCatalog.worker_tool_input_schema("add_comment")["required"] == ["body"]
    assert ToolCatalog.worker_tool_input_schema("list_comments")["required"] == []
    assert ToolCatalog.worker_tool_input_schema("sync_pr")["required"] == []
    assert Map.has_key?(ToolCatalog.worker_tool_input_schema("sync_pr")["properties"], "recovery")

    for tool <- [
          "update_task_plan",
          "append_finding",
          "append_progress",
          "set_status",
          "add_comment",
          "list_comments",
          "resolve_comment",
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

    for content <- [worker_skill, prompt] do
      assert content =~ "attach_branch(head_sha)"
      assert content =~ "complete_review(reference?, note?)"
      assert content =~ "sync_pr()"
      assert content =~ "attached PR"
      assert content =~ "Workers do not create"
      refute content =~ "blocker_closeout"
      refute content =~ "report_blocker"
      refute content =~ "resolve_blocker"
      refute content =~ "create_guidance_request"
      refute content =~ "sync_pr(metadata, url|number)"
      refute content =~ "sync_pr(url_or_number, metadata)"
    end
  end

  test "packaged worker prompt is paste-ready and MCP-backed" do
    for content <- [File.read!(@mcp_plugin_prompt_path)] do
      assert String.starts_with?(content, "You are assigned Symphony++ work package")
      assert content =~ "<WORK_PACKAGE_ID>"
      assert content =~ "Ledger claim: call `claim_local_assignment`"
      assert content =~ "Worker branch: <PREPARED_BRANCH>"
      assert content =~ "Worktree path: <PREPARED_WORKTREE_PATH>"
      assert content =~ ~s({"work_package_id":"<WORK_PACKAGE_ID>"})
      assert content =~ "update_task_plan(patch, expected_version)"
      refute content =~ "resolve_blocker"
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

  test "packaged MCP wiring docs explain the local HTTP dependency without embedding secrets" do
    wiring = File.read!(@mcp_plugin_wiring_path)

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
    readme = @plugin_readme_path |> File.read!() |> normalize_prose()
    assert readme =~ "./plugins/symphony-plus-plus"
    assert readme =~ "codex plugin marketplace upgrade"
    assert readme =~ "isolated development Codex homes"
    assert readme =~ "skill-only"
    assert readme =~ "does not contain a root `.mcp.json`"
    assert readme =~ "`symphony-plus-plus-mcp` plugin"
    assert readme =~ "diagnose-mcp-lifecycle.ps1"
    assert readme =~ "marketplace source clone"
    assert readme =~ "compatible packaged runtime artifact"
    assert readme =~ "../../docs/operations.md"
    assert readme =~ "../../docs/runtime.md"
    assert readme =~ "refuses the default `~/.codex` cache"
    refute readme =~ "dogfood"
    refute readme =~ "future verified"
    refute readme =~ "repo-local fallback"

    assert File.read!(@plugin_default_solo_skill_path) =~
             "lightweight parent coordination"

    refute readme =~ "../../Code/"
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
