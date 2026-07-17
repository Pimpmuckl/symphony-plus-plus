Code.require_file("mcp_common_helpers.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPCase.SessionHelpers do
  @moduledoc false

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions
  import SymphonyElixir.SymphonyPlusPlus.MCPCase.CommonHelpers
  alias Ecto.Adapters.SQL
  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory
  @architect_phase_id "phase-mcp-architect-test"

  def create_work_request_handoff_architect_session(repo, %WorkRequest{} = work_request, capabilities) do
    phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    assert {:ok, _phase} =
             PhaseRepository.create(repo, %{
               id: phase_id,
               title: "Architect handoff for #{work_request.id}"
             })

    package_attrs =
      [
        id: ArchitectHandoff.anchor_id_for_work_request(work_request),
        kind: "delegation",
        title: "Architect handoff: #{work_request.title}",
        repo: work_request.repo,
        base_branch: work_request.base_branch,
        allowed_file_globs: ["elixir/lib", "elixir/lib/**"],
        phase_id: phase_id,
        status: "planning"
      ]
      |> WorkPackageFactory.attrs()

    assert {:ok, anchor} = WorkPackageRepository.create(repo, package_attrs)

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase_id,
               work_package_id: anchor.id,
               work_request_id: work_request.id,
               capabilities: capabilities
             )

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: minted.grant.secret_hash)
    assert {:ok, grant} = AccessGrantRepository.get(repo, minted.grant.id)

    {anchor, session, grant}
  end

  def create_phase_architect_session(repo, work_package_id, capabilities, overrides \\ []) do
    phase_id = Keyword.get(overrides, :phase_id) || ensure_architect_phase(repo)

    package_attrs =
      [
        id: work_package_id,
        kind: "mcp",
        base_branch: "symphony-plus-plus/beta",
        repo: "nextide/symphony-plus-plus",
        allowed_file_globs: ["elixir/lib/**"],
        phase_id: phase_id,
        status: "planning"
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, package} = WorkPackageRepository.create(repo, package_attrs)

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase_id,
               work_package_id: package.id,
               capabilities: capabilities
             )

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: minted.grant.secret_hash)
    assert {:ok, grant} = AccessGrantRepository.get(repo, minted.grant.id)

    {package, session, grant}
  end

  def grant_work_request_scope!(repo, %Session{} = session, work_request_id) do
    grant_scope!(repo, session, Scope.work_request(work_request_id), "work_request", work_request_id)
  end

  def grant_work_package_scope!(repo, %Session{} = session, work_package_id) do
    grant_scope!(repo, session, Scope.work_package(work_package_id), "work_package", work_package_id)
  end

  def grant_scope!(repo, %Session{} = session, %Scope{} = scope, scope_type, scope_id) do
    assert {:ok, grant} = AccessGrantRepository.get(repo, session.assignment.grant_id)

    attrs = GrantScope.attrs_from_scope(grant.id, scope)

    case repo.insert(GrantScope.create_changeset(attrs)) do
      {:ok, %GrantScope{}} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> assert_duplicate_grant_scope!(changeset)
    end

    assert {:ok, scope_rows} = AccessGrantRepository.list_scopes(repo, grant.id)
    assert Enum.any?(scope_rows, &(&1.scope_type == scope_type and &1.scope_id == scope_id))
  end

  def remove_grant_scope_type!(repo, %Session{} = session, scope_type) do
    repo.delete_all(
      from(scope in GrantScope,
        where: scope.access_grant_id == ^session.assignment.grant_id,
        where: scope.scope_type == ^scope_type
      )
    )

    assert {:ok, scope_rows} = AccessGrantRepository.list_scopes(repo, session.assignment.grant_id)
    refute Enum.any?(scope_rows, &(&1.scope_type == scope_type))
  end

  def assert_duplicate_grant_scope!(%Ecto.Changeset{} = changeset) do
    assert {"has already been taken", opts} = Keyword.fetch!(changeset.errors, :scope_key)
    assert Keyword.get(opts, :constraint) == :unique
  end

  def create_architect_session(repo, work_package_id, capabilities, overrides \\ []) do
    package_attrs =
      [
        id: work_package_id,
        kind: "mcp",
        base_branch: "symphony-plus-plus/beta",
        repo: "nextide/symphony-plus-plus",
        allowed_file_globs: ["elixir/lib/**"],
        status: "planning"
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               package_attrs
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, capabilities)

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))
    {:ok, package} = WorkPackageRepository.get(repo, package.id)

    {package, session}
  end

  def create_non_expiring_architect_session(repo, work_package_id, capabilities) do
    phase_id = ensure_architect_phase(repo)

    package_attrs =
      [
        id: work_package_id,
        kind: "mcp",
        base_branch: "symphony-plus-plus/beta",
        repo: "nextide/symphony-plus-plus",
        allowed_file_globs: ["elixir/lib/**"],
        status: "planning",
        phase_id: phase_id
      ]
      |> WorkPackageFactory.attrs()

    assert {:ok, package} = WorkPackageRepository.create(repo, package_attrs)

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase_id,
               work_package_id: package.id,
               capabilities: capabilities
             )

    assert minted.grant.expires_at == nil

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(minted.work_key.secret))
    {:ok, package} = WorkPackageRepository.get(repo, package.id)

    {package, session}
  end

  def active_worker_grants(grants) do
    now = DateTime.utc_now(:microsecond)

    Enum.filter(grants, fn grant ->
      grant.grant_role == "worker" and is_nil(grant.revoked_at) and live_expires_at?(grant.expires_at, now)
    end)
  end

  def live_expires_at?(nil, %DateTime{}), do: true
  def live_expires_at?(%DateTime{} = expires_at, %DateTime{} = now), do: DateTime.compare(expires_at, now) == :gt

  def rebuild_access_grants_with_not_null_expiry!(repo_or_pid) do
    query!(repo_or_pid, "PRAGMA foreign_keys = OFF")

    try do
      query!(repo_or_pid, "DROP TABLE IF EXISTS sympp_access_grants_legacy_expiry")

      query!(repo_or_pid, """
      CREATE TABLE sympp_access_grants_legacy_expiry (
        id TEXT PRIMARY KEY NOT NULL,
        work_package_id TEXT NOT NULL REFERENCES sympp_work_packages(id) ON DELETE CASCADE,
        display_key TEXT NOT NULL,
        secret_hash TEXT NOT NULL,
        grant_role TEXT NOT NULL,
        capabilities TEXT NOT NULL DEFAULT '[]',
        expires_at TEXT NOT NULL,
        revoked_at TEXT,
        claimed_at TEXT,
        claimed_by TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        phase_id TEXT REFERENCES sympp_phases(id) ON DELETE CASCADE,
        scope_repo TEXT,
        scope_base_branch TEXT,
        provenance TEXT
      )
      """)

      query!(repo_or_pid, """
      INSERT INTO sympp_access_grants_legacy_expiry (
        id,
        work_package_id,
        display_key,
        secret_hash,
        grant_role,
        capabilities,
        expires_at,
        revoked_at,
        claimed_at,
        claimed_by,
        inserted_at,
        updated_at,
        phase_id,
        scope_repo,
        scope_base_branch,
        provenance
      )
      SELECT
        id,
        work_package_id,
        display_key,
        secret_hash,
        grant_role,
        capabilities,
        expires_at,
        revoked_at,
        claimed_at,
        claimed_by,
        inserted_at,
        updated_at,
        phase_id,
        scope_repo,
        scope_base_branch,
        provenance
      FROM sympp_access_grants
      """)

      query!(repo_or_pid, "DROP TABLE sympp_access_grants")
      query!(repo_or_pid, "ALTER TABLE sympp_access_grants_legacy_expiry RENAME TO sympp_access_grants")
      recreate_access_grant_indexes!(repo_or_pid)
    after
      query!(repo_or_pid, "PRAGMA foreign_keys = ON")
    end
  end

  def recreate_access_grant_indexes!(repo_or_pid) do
    query!(repo_or_pid, "CREATE UNIQUE INDEX sympp_access_grants_id_unique_index ON sympp_access_grants (id)")
    query!(repo_or_pid, "CREATE UNIQUE INDEX sympp_access_grants_secret_hash_unique_index ON sympp_access_grants (secret_hash)")
    query!(repo_or_pid, "CREATE INDEX sympp_access_grants_work_package_id_index ON sympp_access_grants (work_package_id)")
    query!(repo_or_pid, "CREATE INDEX sympp_access_grants_display_key_index ON sympp_access_grants (display_key)")
    query!(repo_or_pid, "CREATE INDEX sympp_access_grants_grant_role_index ON sympp_access_grants (grant_role)")
    query!(repo_or_pid, "CREATE INDEX sympp_access_grants_phase_id_index ON sympp_access_grants (phase_id)")
  end

  def remove_null_expiry_migration_version!(repo_or_pid) do
    query!(repo_or_pid, "DELETE FROM schema_migrations WHERE version = ?", [20_260_519_120_000])
  end

  def access_grant_expiry_not_null?(repo_or_pid) do
    %{rows: rows} = query!(repo_or_pid, "PRAGMA table_info(sympp_access_grants)")

    Enum.any?(rows, fn
      [_cid, "expires_at", _type, not_null, _default_value, _primary_key] -> not_null in [1, true]
      _column -> false
    end)
  end

  def schema_migration_recorded?(repo_or_pid, version) do
    %{rows: [[count]]} = query!(repo_or_pid, "SELECT COUNT(*) FROM schema_migrations WHERE version = ?", [version])
    count == 1
  end

  def query!(repo_or_pid, sql, params \\ []) do
    SQL.query!(repo_or_pid, sql, params, log: false)
  end

  def mcp_tool(repo, session, name, arguments, opts \\ []) do
    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => name,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      config: Keyword.get(opts, :config, test_mcp_config(repo)),
      session: session
    )
  end

  def test_mcp_config(repo), do: Config.default(repo: repo, repo_root: test_repo_root())

  def local_mcp_config(repo), do: Config.default(repo: repo, mode: :http, repo_root: test_repo_root(), local_daemon_trusted: true)

  def local_mcp_server(%Config{} = config, state_key) do
    Server.new(config, initialized: true, local_daemon_trusted: true, state_key: state_key)
  end

  def create_local_claim_package!(repo, id, overrides \\ []) do
    attrs =
      [
        id: id,
        kind: "mcp",
        repo: "nextide/symphony-plus-plus",
        base_branch: "feature/sympp-v21-ledger-claims",
        branch_pattern: "agent/#{id}/worker",
        worktree_path: local_claim_worktree_path(id),
        status: "ready_for_worker"
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, package} = WorkPackageRepository.create(repo, attrs)
    package
  end

  def local_assignment_claim_args(%WorkPackage{} = package, overrides \\ %{}) do
    %{
      "repo" => package.repo,
      "base_branch" => package.base_branch,
      "work_package_id" => package.id,
      "branch" => package.branch_pattern,
      "worktree_path" => package.worktree_path,
      "caller_id" => "codex-local-test",
      "claimed_by" => "local-worker-1"
    }
    |> Map.merge(overrides)
  end

  def local_assignment_claim_actor(arguments) do
    owner_material =
      [
        "worker",
        arguments["work_package_id"],
        arguments["claimed_by"]
      ]
      |> Enum.join("\0")

    %{
      "actor_kind" => "agent",
      "actor_id" => "local:" <> local_assignment_actor_hash(owner_material),
      "actor_display_name" => arguments["claimed_by"]
    }
  end

  def local_assignment_actor_hash(material) do
    Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  def local_claim_worktree_path(work_package_id) do
    Path.expand(Path.join(System.tmp_dir!(), "sympp-local-claim-#{work_package_id}"))
  end

  def set_relative_owner_origin!(fixture, owner_repo) do
    relative_origin = "#{owner_repo}.git"
    local_origin = Path.join(fixture.repo_root, relative_origin)

    File.mkdir_p!(Path.dirname(local_origin))
    TestSupport.git_output!(fixture.root, ["clone", "--bare", fixture.origin, local_origin])
    TestSupport.git_output!(fixture.repo_root, ["remote", "set-url", "origin", relative_origin])

    fixture
  end

  def create_architect_work_key(repo, work_package_id, capabilities \\ ["architect:lifecycle.transition"]) do
    now = DateTime.utc_now(:microsecond)
    work_key = WorkKey.generate()
    phase_id = phase_id_for_architect_grant(repo, work_package_id, capabilities)

    attrs = %{
      work_package_id: work_package_id,
      display_key: work_key.display_key,
      secret_hash: WorkKey.secret_hash(work_key.secret),
      grant_role: "architect",
      capabilities: capabilities,
      expires_at: DateTime.add(now, 86_400, :second)
    }

    attrs = if phase_id, do: Map.put(attrs, :phase_id, phase_id), else: attrs

    with {:ok, _grant} <- AccessGrantRepository.create(repo, attrs) do
      {:ok, work_key}
    end
  end

  def phase_id_for_architect_grant(repo, work_package_id, capabilities) do
    if "read:phase" in capabilities do
      phase_id = ensure_architect_phase(repo)
      assert {:ok, _work_package} = WorkPackageRepository.update(repo, work_package_id, %{phase_id: phase_id})
      phase_id
    end
  end

  def ensure_architect_phase(repo) do
    case PhaseRepository.get(repo, @architect_phase_id) do
      {:ok, phase} ->
        phase.id

      {:error, :not_found} ->
        assert {:ok, phase} = PhaseRepository.create(repo, %{id: @architect_phase_id, title: "MCP architect test phase"})
        phase.id
    end
  end

  def decode_json_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  def decode_json_objects_from_mixed_output(output) do
    output
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim_leading/1)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&Jason.decode!/1)
  end

  def json_rpc_response_summary(responses) do
    Enum.map(responses, fn response ->
      result = Map.get(response, "result", %{})

      %{
        id: Map.get(response, "id"),
        error: get_in(response, ["error", "data", "reason"]) || get_in(response, ["error", "message"]),
        result_keys: if(is_map(result), do: Map.keys(result), else: [])
      }
    end)
  end
end
