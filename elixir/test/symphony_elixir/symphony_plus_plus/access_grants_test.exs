defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrantsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Auth
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  defmodule LockedAccessGrantRepo do
    def get(_schema, _id), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule BrokenAccessGrantRepo do
    def get(_schema, _id), do: raise(%Exqlite.Error{message: "disk I/O failed"})
  end

  defmodule TerminalClaimRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @race_key :sympp_terminal_claim_race

    def arm(work_package_id), do: Process.put(@race_key, work_package_id)
    def disarm, do: Process.delete(@race_key)

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def one(query), do: Repo.one(query)
    def update(changeset), do: Repo.update(changeset)
    def transaction(fun), do: Repo.transaction(fun)
    def rollback(reason), do: Repo.rollback(reason)

    def update_all(query, updates) do
      case Process.get(@race_key) do
        work_package_id when is_binary(work_package_id) ->
          Process.delete(@race_key)

          Repo.update_all(
            from(work_package in WorkPackage, where: work_package.id == ^work_package_id),
            set: [status: "merged", updated_at: DateTime.utc_now(:microsecond)]
          )

        _race ->
          :ok
      end

      Repo.update_all(query, updates)
    end
  end

  defmodule TerminalMintRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @race_key :sympp_terminal_mint_race

    def arm(work_package_id), do: Process.put(@race_key, work_package_id)
    def disarm, do: Process.delete(@race_key)

    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def one(query), do: Repo.one(query)
    def rollback(reason), do: Repo.rollback(reason)

    def transaction(fun) do
      case Process.get(@race_key) do
        work_package_id when is_binary(work_package_id) ->
          Process.delete(@race_key)

          Repo.update_all(
            from(work_package in WorkPackage, where: work_package.id == ^work_package_id),
            set: [status: "skipped", updated_at: DateTime.utc_now(:microsecond)]
          )

        _race ->
          :ok
      end

      Repo.transaction(fun)
    end
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 8})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(GrantScope)
    repo.delete_all(AccessGrant)
    repo.query!("DELETE FROM sympp_work_requests")
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)
    :ok
  end

  test "generates high-entropy work keys with four-character display keys" do
    first = WorkKey.generate()
    second = WorkKey.generate()

    assert String.length(first.display_key) == 4
    assert first.display_key =~ ~r/\A[0-9A-F]{4}\z/
    assert WorkKey.secret_shape?(first.secret)
    assert String.length(first.secret) >= 46
    assert first.secret != second.secret
    assert WorkKey.secret_hash(first.secret) != WorkKey.secret_hash(second.secret)
  end

  test "mints a worker grant for one work package and stores only a secret hash", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-002"))

    assert {:ok, %{grant: grant, work_key: work_key}} =
             Service.mint_worker_grant(repo, work_package.id, capabilities: ["worker:claim"])

    assert %AccessGrant{} = grant
    assert grant.work_package_id == work_package.id
    assert grant.grant_role == "worker"
    assert grant.display_key == work_key.display_key
    assert grant.secret_hash == WorkKey.secret_hash(work_key.secret)
    assert grant.expires_at == nil
    refute grant.secret_hash == work_key.secret

    assert {:ok, persisted} = Repository.get(repo, grant.id)
    assert persisted.expires_at == nil
    refute Map.has_key?(Map.from_struct(persisted), :secret)
    refute Map.has_key?(Map.from_struct(persisted), :raw_secret)
    refute inspect(persisted) =~ persisted.secret_hash
    refute inspect(work_key) =~ work_key.secret
  end

  test "planned WorkPackages cannot mint or claim worker authority before dispatch", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PLANNED-AUTHORITY", status: "planned")
             )

    assert {:error, :work_package_not_dispatched} =
             Service.mint_worker_grant(repo, work_package.id)

    work_key = WorkKey.generate()

    assert {:ok, grant} =
             Repository.create(repo, %{
               work_package_id: work_package.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "worker",
               capabilities: ["worker:claim"]
             })

    assert {:error, :work_package_not_dispatched} =
             Service.claim_local_worker_grant(repo, work_package.id, claimed_by: "early-worker")

    assert {:ok, persisted} = Repository.get(repo, grant.id)
    assert persisted.claimed_at == nil
    assert persisted.claimed_by == nil
  end

  test "grant scope persistence supports all explicit scope row types", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SCOPE-SCHEMA"))
    assert {:ok, %{grant: grant}} = Service.mint_worker_grant(repo, work_package.id)
    repo.delete_all(GrantScope)

    for scope <- [
          Scope.ledger(),
          Scope.repo("nextide/symphony-plus-plus", "main"),
          Scope.work_request("wr-scope-schema"),
          Scope.work_package("wrs-scope-schema"),
          Scope.work_package(work_package.id)
        ] do
      assert {:ok, %GrantScope{}} =
               scope
               |> then(&GrantScope.attrs_from_scope(grant.id, &1))
               |> GrantScope.create_changeset()
               |> repo.insert()
    end

    assert {:ok, scope_rows} = Repository.list_scopes(repo, grant.id)
    assert MapSet.new(Enum.map(scope_rows, & &1.scope_type)) == MapSet.new(["ledger", "repo", "work_request", "work_package", "work_package"])
  end

  test "worker grants persist exactly one work package scope", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-SCOPE"))

    assert {:ok, %{grant: grant}} =
             Service.mint_worker_grant(repo, work_package.id, capabilities: ["worker:claim"])

    assert {:ok, [%GrantScope{} = scope]} = Repository.list_scopes(repo, grant.id)
    assert scope.scope_type == "work_package"
    assert scope.scope_id == work_package.id
    assert scope.scope_key == "work_package:#{work_package.id}"
    assert scope.repo == nil
    assert scope.base_branch == nil
  end

  test "architect handoff grants persist one work request scope", %{repo: repo} do
    {phase, work_package, _work_request} = create_handoff_anchor!(repo, "wr-architect-scope")

    assert {:ok, %{grant: grant}} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-architect-scope",
               capabilities: ["read:work_request", "write:work_request"]
             )

    assert {:ok, scope_rows} = Repository.list_scopes(repo, grant.id)
    assert [%GrantScope{scope_type: "work_request", scope_id: "wr-architect-scope"}] = Enum.filter(scope_rows, &(&1.scope_type == "work_request"))
  end

  test "architect grants reject requested work request scopes outside the anchor repository", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-invalid-work-request-scope", title: "Invalid WorkRequest scope"})

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(kind: "delegation", phase_id: phase.id)
             )

    insert_work_request!(repo, "wr-outside-repo", "other/repo", work_package.base_branch)

    assert {:error, :invalid_scope} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-outside-repo",
               capabilities: ["read:work_request", "write:work_request"]
             )
  end

  test "architect grants reject unattached work request scopes in the anchor repository", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-unattached-work-request-scope", title: "Unattached WorkRequest scope"})

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(kind: "delegation", phase_id: phase.id)
             )

    insert_work_request!(repo, "wr-unattached-scope", work_package.repo, work_package.base_branch)

    assert {:error, :invalid_scope} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-unattached-scope",
               capabilities: ["read:work_request", "write:work_request"]
             )
  end

  test "architect grants reject WorkPackage scopes outside the anchor package", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-invalid-work-package-scope", title: "Invalid WorkPackage scope"})

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(kind: "delegation", phase_id: phase.id)
             )

    assert {:ok, other_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-OTHER-SCOPE", kind: "delegation", phase_id: phase.id)
             )

    insert_work_request!(repo, "wr-work-package-scope", work_package.repo, work_package.base_branch)
    attach_work_request!(repo, "wr-work-package-scope", other_package.id)

    assert {:ok, %{grant: grant}} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               capabilities: ["read:work_request", "write:work_request"]
             )

    assert {:error, :invalid_scope} =
             Repository.ensure_grant_scopes(repo, grant, %{
               work_package_id: other_package.id
             })
  end

  test "architect grants reject slice-derived work request scopes outside the anchor repository", %{repo: repo} do
    assert {:ok, phase} =
             PhaseRepository.create(repo, %{
               id: "phase-cross-repo-work-package-scope",
               title: "Cross-repo WorkPackage scope"
             })

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(kind: "delegation", phase_id: phase.id)
             )

    insert_work_request!(repo, "wr-cross-repo-slice-scope", "other/repo", work_package.base_branch)

    attach_work_request!(repo, "wr-cross-repo-slice-scope", work_package.id)

    assert {:error, :invalid_scope} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-cross-repo-slice-scope",
               capabilities: ["read:work_request", "write:work_request"]
             )
  end

  test "architect grants reject explicit scopes outside the anchor authority", %{repo: repo} do
    assert {:ok, phase} =
             PhaseRepository.create(repo, %{
               id: "phase-invalid-explicit-scopes",
               title: "Invalid explicit scopes"
             })

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(kind: "delegation", phase_id: phase.id)
             )

    invalid_scopes = [
      Scope.ledger(),
      Scope.repo("other/repo", work_package.base_branch),
      Scope.repo(work_package.repo, "other/base"),
      Scope.work_package("wp-outside-anchor")
    ]

    for scope <- invalid_scopes do
      work_key = WorkKey.generate()

      assert {:error, :invalid_scope} =
               Repository.create(repo, %{
                 work_package_id: work_package.id,
                 phase_id: phase.id,
                 display_key: work_key.display_key,
                 secret_hash: WorkKey.secret_hash(work_key.secret),
                 grant_role: "architect",
                 scopes: [scope],
                 capabilities: ["read:work_request", "write:work_request"]
               })
    end
  end

  test "architect grants resolve work request scope from a dispatched WorkPackage", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-resolved-work-request-scope", title: "Resolved WorkRequest scope"})

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(kind: "delegation", phase_id: phase.id)
             )

    insert_work_request!(repo, "wr-resolved-scope", work_package.repo, work_package.base_branch)
    attach_work_request!(repo, "wr-resolved-scope", work_package.id)

    assert {:ok, %{grant: grant}} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               capabilities: ["read:work_request", "write:work_request"]
             )

    assert {:ok, scope_rows} = Repository.list_scopes(repo, grant.id)
    assert [%GrantScope{scope_type: "work_request", scope_id: "wr-resolved-scope"}] = Enum.filter(scope_rows, &(&1.scope_type == "work_request"))
  end

  test "architect grants constrain WorkPackages to persisted work request scope", %{repo: repo} do
    {phase, work_package, _work_request} = create_handoff_anchor!(repo, "wr-work-package-allowed")
    insert_work_request!(repo, "wr-work-package-other", work_package.repo, work_package.base_branch)

    assert {:ok, other_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORK-PACKAGE-OTHER",
                 kind: "delegation",
                 phase_id: phase.id,
                 repo: work_package.repo,
                 base_branch: work_package.base_branch
               )
             )

    attach_work_request!(repo, "wr-work-package-other", other_package.id)

    assert {:ok, %{grant: grant}} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-work-package-allowed",
               capabilities: ["read:work_request", "write:work_request"]
             )

    assert {:error, :invalid_scope} =
             Repository.ensure_grant_scopes(repo, grant, %{
               work_package_id: other_package.id
             })

    assert {:ok, scope_rows} = Repository.list_scopes(repo, grant.id)
    assert [%GrantScope{scope_type: "work_request", scope_id: "wr-work-package-allowed"}] = Enum.filter(scope_rows, &(&1.scope_type == "work_request"))

    assert [%GrantScope{scope_type: "work_package", scope_id: scope_work_package_id}] =
             Enum.filter(scope_rows, &(&1.scope_type == "work_package"))

    assert scope_work_package_id == work_package.id
  end

  test "architect grants derive work request scope from requested WorkPackage", %{repo: repo} do
    assert {:ok, phase} =
             PhaseRepository.create(repo, %{
               id: "phase-requested-work-package-work-request",
               title: "Requested WorkPackage WorkRequest"
             })

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(kind: "delegation", phase_id: phase.id)
             )

    insert_work_request!(repo, "wr-requested-work-package", work_package.repo, work_package.base_branch)
    attach_work_request!(repo, "wr-requested-work-package", work_package.id)

    assert {:ok, %{grant: grant}} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               capabilities: ["read:work_request", "write:work_request"]
             )

    assert {:ok, scope_rows} = Repository.list_scopes(repo, grant.id)
    assert [%GrantScope{scope_type: "work_request", scope_id: "wr-requested-work-package"}] = Enum.filter(scope_rows, &(&1.scope_type == "work_request"))
    work_package_id = work_package.id
    assert [%GrantScope{scope_type: "work_package", scope_id: ^work_package_id}] = Enum.filter(scope_rows, &(&1.scope_type == "work_package"))
  end

  test "architect grants reject default slice-derived work request scope outside anchor repo", %{repo: repo} do
    assert {:ok, phase} =
             PhaseRepository.create(repo, %{
               id: "phase-invalid-default-work-request-scope",
               title: "Invalid default WorkRequest scope"
             })

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 kind: "delegation",
                 phase_id: phase.id,
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main"
               )
             )

    insert_work_request!(repo, "wr-default-cross-repo", "nextide/other", work_package.base_branch)
    attach_work_request!(repo, "wr-default-cross-repo", work_package.id)

    assert {:error, :invalid_scope} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               capabilities: ["read:work_request", "write:work_request"]
             )
  end

  test "default worker grants are non-expiring and remain claimable", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)
    far_future = ~U[2027-04-30 10:00:00Z]

    assert minted.grant.expires_at == nil
    assert {:ok, %Assignment{} = assignment} = Service.claim(repo, minted.work_key.secret, now: far_future, claimed_by: "worker-1")
    assert assignment.grant_id == minted.grant.id
  end

  test "explicit worker grant expiry is preserved", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    expires_at = ~U[2026-05-01 12:00:00.123456Z]

    assert {:ok, %{grant: grant}} = Service.mint_worker_grant(repo, work_package.id, expires_at: expires_at)

    assert DateTime.compare(grant.expires_at, expires_at) == :eq
    assert {:ok, persisted} = Repository.get(repo, grant.id)
    assert persisted.expires_at == expires_at
  end

  test "default architect grants are non-expiring and remain claimable", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-no-expiry-grant", title: "No expiry grant"})

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(kind: "mcp", phase_id: phase.id)
             )

    assert {:ok, minted} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               capabilities: ["read:phase"]
             )

    far_future = ~U[2027-04-30 10:00:00Z]

    assert minted.grant.expires_at == nil
    assert {:ok, %Assignment{} = assignment} = Service.claim(repo, minted.work_key.secret, now: far_future, claimed_by: "architect-1")
    assert assignment.grant_role == "architect"
    assert assignment.phase_id == phase.id
  end

  test "create ignores terminal lifecycle fields", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    work_key = WorkKey.generate()
    timestamp = ~U[2026-04-30 10:00:00Z]
    expires_at = DateTime.add(timestamp, 60, :second)

    assert {:ok, grant} =
             Repository.create(repo, %{
               work_package_id: work_package.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "worker",
               capabilities: ["worker:claim"],
               expires_at: expires_at,
               claimed_at: timestamp,
               claimed_by: "worker-1",
               revoked_at: timestamp
             })

    assert DateTime.compare(grant.expires_at, expires_at) == :eq
    assert grant.claimed_at == nil
    assert grant.claimed_by == nil
    assert grant.revoked_at == nil
  end

  test "claiming a valid secret returns a scoped assignment without returning the raw secret", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-002"))
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:ok, %Assignment{} = assignment} =
             Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    assert assignment.grant_id == minted.grant.id
    assert assignment.work_package_id == work_package.id
    assert assignment.display_key == minted.work_key.display_key
    assert assignment.grant_role == "worker"
    assert assignment.capabilities == ["worker:claim", "worker:lifecycle.transition"]
    assert assignment.claimed_by == "worker-1"
    assert assignment.scopes == [Scope.work_package(work_package.id)]
    refute inspect(assignment) =~ minted.work_key.secret
  end

  test "claim reconnect restores missing worker scope rows for existing grants", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)
    repo.delete_all(GrantScope)

    assert {:ok, %AccessGrant{} = first_claim} =
             Service.claim_local_worker_grant(repo, work_package.id, claimed_by: "worker-1")

    assert first_claim.id == minted.grant.id
    assert {:ok, [%GrantScope{scope_type: "work_package", scope_id: work_package_id}]} = Repository.list_scopes(repo, minted.grant.id)
    assert work_package_id == work_package.id

    repo.delete_all(GrantScope)

    assert {:ok, %AccessGrant{} = reconnect} =
             Service.claim_local_worker_grant(repo, work_package.id, claimed_by: "worker-1")

    assert reconnect.id == minted.grant.id
    assert {:ok, [%GrantScope{scope_type: "work_package", scope_id: work_package_id}]} = Repository.list_scopes(repo, minted.grant.id)
    assert work_package_id == work_package.id
  end

  test "auth revalidation reloads persisted worker work package scopes", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:ok, %Assignment{} = assignment} =
             Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    stale_session = Session.new(%{assignment | scopes: []}, proof_hash: minted.grant.secret_hash)

    assert {:ok, %Session{} = live_session} = Auth.require_session(stale_session, repo)
    assert live_session.assignment.scopes == [Scope.work_package(work_package.id)]
  end

  test "local architect reconnect restores explicit work request scope rows", %{repo: repo} do
    {phase, work_package, _work_request} = create_handoff_anchor!(repo, "wr-local-architect-scope")

    assert {:ok, minted} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-local-architect-scope",
               capabilities: ["read:work_request", "write:work_request"]
             )

    repo.delete_all(GrantScope)

    assert {:ok, %AccessGrant{} = first_claim} =
             Service.claim_local_architect_grant(repo, work_package.id, phase.id,
               claimed_by: "architect-1",
               scope_repo: work_package.repo,
               scope_base_branch: work_package.base_branch,
               work_request_id: "wr-local-architect-scope"
             )

    assert first_claim.id == minted.grant.id
    assert {:ok, scope_rows} = Repository.list_scopes(repo, minted.grant.id)
    assert [%GrantScope{scope_type: "work_request", scope_id: "wr-local-architect-scope"}] = Enum.filter(scope_rows, &(&1.scope_type == "work_request"))

    repo.delete_all(GrantScope)

    assert {:ok, %AccessGrant{} = reconnect} =
             Service.claim_local_architect_grant(repo, work_package.id, phase.id,
               claimed_by: "architect-1",
               scope_repo: work_package.repo,
               scope_base_branch: work_package.base_branch,
               work_request_id: "wr-local-architect-scope"
             )

    assert reconnect.id == minted.grant.id
    assert {:ok, scope_rows} = Repository.list_scopes(repo, minted.grant.id)
    assert [%GrantScope{scope_type: "work_request", scope_id: "wr-local-architect-scope"}] = Enum.filter(scope_rows, &(&1.scope_type == "work_request"))
  end

  test "local architect repo alias filtering happens before selecting a grant", %{repo: repo} do
    {phase, work_package, _work_request} = create_handoff_anchor!(repo, "wr-local-architect-repo-alias-order")

    assert {:ok, matching} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-local-architect-repo-alias-order",
               capabilities: ["read:work_request", "write:work_request"]
             )

    assert {:ok, newer_unmatched} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-local-architect-repo-alias-order",
               capabilities: ["read:work_request", "write:work_request"]
             )

    newer_unmatched.grant
    |> Ecto.Changeset.change(scope_repo: "elsewhere/other")
    |> repo.update!()

    assert {:ok, %AccessGrant{} = first_claim} =
             Service.claim_local_architect_grant(repo, work_package.id, phase.id,
               claimed_by: "architect-1",
               scope_repo: work_package.repo,
               scope_base_branch: work_package.base_branch,
               work_request_id: "wr-local-architect-repo-alias-order"
             )

    assert first_claim.id == matching.grant.id

    assert {:ok, newer_claimed_unmatched} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-local-architect-repo-alias-order",
               capabilities: ["read:work_request", "write:work_request"]
             )

    newer_claimed_unmatched.grant
    |> Ecto.Changeset.change(scope_repo: "elsewhere/other", claimed_by: "architect-1", claimed_at: DateTime.add(DateTime.utc_now(:microsecond), 1, :second))
    |> repo.update!()

    assert {:ok, %AccessGrant{} = reconnect} =
             Service.claim_local_architect_grant(repo, work_package.id, phase.id,
               claimed_by: "architect-1",
               scope_repo: work_package.repo,
               scope_base_branch: work_package.base_branch,
               work_request_id: "wr-local-architect-repo-alias-order"
             )

    assert reconnect.id == matching.grant.id
  end

  test "local architect reconnect rejects work request scope drift", %{repo: repo} do
    {phase, work_package, _work_request} = create_handoff_anchor!(repo, "wr-architect-scope-original")
    insert_work_request!(repo, "wr-architect-scope-drift", work_package.repo, work_package.base_branch)

    assert {:ok, _minted} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-architect-scope-original",
               capabilities: ["read:work_request", "write:work_request"]
             )

    assert {:ok, %AccessGrant{}} =
             Service.claim_local_architect_grant(repo, work_package.id, phase.id,
               claimed_by: "architect-1",
               scope_repo: work_package.repo,
               scope_base_branch: work_package.base_branch,
               work_request_id: "wr-architect-scope-original"
             )

    assert {:error, :invalid_scope} =
             Service.claim_local_architect_grant(repo, work_package.id, phase.id,
               claimed_by: "architect-1",
               scope_repo: work_package.repo,
               scope_base_branch: work_package.base_branch,
               work_request_id: "wr-architect-scope-drift"
             )
  end

  test "auth revalidation reloads persisted architect work request scopes", %{repo: repo} do
    {phase, work_package, _work_request} = create_handoff_anchor!(repo, "wr-auth-architect-scope")

    assert {:ok, minted} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               work_request_id: "wr-auth-architect-scope",
               capabilities: ["read:work_request", "write:work_request"]
             )

    assert {:ok, %Assignment{} = assignment} =
             Service.claim(repo, minted.work_key.secret, claimed_by: "architect-1")

    stale_session = Session.new(%{assignment | scopes: []}, proof_hash: minted.grant.secret_hash)

    assert {:ok, %Session{} = live_session} = Auth.require_session(stale_session, repo)
    assert Scope.work_request("wr-auth-architect-scope") in live_session.assignment.scopes
  end

  test "repository claims require a nonblank worker identity", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:error, :missing_claim_identity} =
             Repository.claim(repo, minted.work_key.secret, %{}, DateTime.utc_now(:microsecond))

    assert {:error, :missing_claim_identity} =
             Repository.claim(repo, minted.work_key.secret, %{claimed_by: "   "}, DateTime.utc_now(:microsecond))

    assert {:ok, persisted} = Repository.get(repo, minted.grant.id)
    assert persisted.claimed_at == nil
    assert persisted.claimed_by == nil
  end

  test "service claims do not invent a worker identity", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:error, :missing_claim_identity} = Service.claim(repo, minted.work_key.secret)

    assert {:ok, persisted} = Repository.get(repo, minted.grant.id)
    assert persisted.claimed_at == nil
    assert persisted.claimed_by == nil
  end

  test "repository normalizes SQLite read failures" do
    assert {:error, :database_busy} = Repository.get(LockedAccessGrantRepo, "grant-1")
    assert {:error, {:storage_failed, "disk I/O failed"}} = Repository.get(BrokenAccessGrantRepo, "grant-1")
  end

  test "expired grants reject claims", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    now = ~U[2026-04-30 10:00:00Z]

    assert {:ok, minted} =
             Service.mint_worker_grant(repo, work_package.id,
               now: now,
               expires_at: DateTime.add(now, -1, :second)
             )

    assert {:error, :expired} = Service.claim(repo, minted.work_key.secret, now: now, claimed_by: "worker-1")
  end

  test "revoked grants reject claims", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)
    assert {:ok, %AccessGrant{revoked_at: %DateTime{}}} = Service.revoke(repo, minted.grant.id)

    assert {:error, :revoked} = Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
  end

  test "terminal work package state rejects claims without mutating the grant", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(status: "ready_for_worker"))

    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)
    assert {:ok, _work_package} = WorkPackageRepository.update_status(repo, work_package.id, "ready_for_worker", "merged")

    assert {:error, :work_package_terminal} =
             Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    assert {:ok, grant} = Repository.get(repo, minted.grant.id)
    assert grant.claimed_at == nil
    assert grant.claimed_by == nil
  end

  test "terminal work package claim race rejects atomically without mutating the grant", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(status: "ready_for_worker"))

    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    try do
      TerminalClaimRaceRepo.arm(work_package.id)

      assert {:error, :work_package_terminal} =
               Service.claim(TerminalClaimRaceRepo, minted.work_key.secret, claimed_by: "worker-1")
    after
      TerminalClaimRaceRepo.disarm()
    end

    assert {:ok, grant} = Repository.get(repo, minted.grant.id)
    assert grant.claimed_at == nil
    assert grant.claimed_by == nil
  end

  test "skipped work package mint race rejects atomically without creating worker authority", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(status: "ready_for_worker"))

    try do
      TerminalMintRaceRepo.arm(work_package.id)

      assert {:error, :work_package_terminal} =
               Service.mint_worker_grant(TerminalMintRaceRepo, work_package.id)
    after
      TerminalMintRaceRepo.disarm()
    end

    assert repo.get!(WorkPackage, work_package.id).status == "skipped"
    assert repo.aggregate(AccessGrant, :count, :id) == 0
  end

  test "revoke is idempotent and preserves the first revocation timestamp", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)
    first_revoked_at = ~U[2026-04-30 10:00:00Z]
    later_revoked_at = ~U[2026-04-30 11:00:00Z]

    assert {:ok, first_revoke} = Service.revoke(repo, minted.grant.id, now: first_revoked_at)
    assert {:ok, second_revoke} = Service.revoke(repo, minted.grant.id, now: later_revoked_at)

    assert DateTime.compare(first_revoke.revoked_at, first_revoked_at) == :eq
    assert second_revoke.revoked_at == first_revoke.revoked_at
  end

  test "invalid secrets reject claims", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, _minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:error, :invalid_secret} = Service.claim(repo, "wk_not-the-secret", claimed_by: "worker-1")
  end

  test "double claim is explicitly rejected after the first valid claim", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:ok, %Assignment{}} = Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    assert {:error, :already_claimed} = Service.claim(repo, minted.work_key.secret, claimed_by: "worker-2")
  end

  test "concurrent claims allow only one worker to claim the grant", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Service.claim(repo, minted.work_key.secret, claimed_by: "worker-#{index}")
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert 1 == Enum.count(results, &match?({:ok, %Assignment{}}, &1))
    assert 7 == Enum.count(results, &match?({:error, :already_claimed}, &1))
  end

  test "four-character display key alone cannot authenticate", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:error, :display_key_only} = Service.claim(repo, minted.work_key.display_key, claimed_by: "worker-1")
  end

  test "worker grant cannot include architect capabilities", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())

    assert {:error, %Ecto.Changeset{} = changeset} =
             Service.mint_worker_grant(repo, work_package.id, capabilities: ["worker:claim", "architect:merge"])

    assert "worker grants cannot include architect capabilities" in errors_on(changeset).capabilities
  end

  test "worker grant cannot include architect MCP tool capabilities", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())

    for capability <- [
          "read:phase",
          "read:work_request",
          "write:work_request",
          "dispatch:work_request",
          "write:phase_plan"
        ] do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Service.mint_worker_grant(repo, work_package.id, capabilities: ["worker:claim", capability])

      assert "worker grants cannot include architect capabilities" in errors_on(changeset).capabilities
    end
  end

  test "architect grant can include work request capabilities", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-work-request-capabilities", title: "WorkRequest capabilities"})

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(kind: "delegation", phase_id: phase.id)
             )

    work_key = WorkKey.generate()

    assert {:ok, %AccessGrant{} = grant} =
             Repository.create(repo, %{
               work_package_id: work_package.id,
               phase_id: phase.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:work_request", "write:work_request", "dispatch:work_request"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })

    assert grant.capabilities == ["read:work_request", "write:work_request", "dispatch:work_request"]
    assert grant.phase_id == phase.id
  end

  test "architect read phase grants require phase scope", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    work_key = WorkKey.generate()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Repository.create(repo, %{
               work_package_id: work_package.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })

    assert "architect phase-scoped grants require phase scope" in errors_on(changeset).phase_id
  end

  test "architect dispatch work request grants require phase scope", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    work_key = WorkKey.generate()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Repository.create(repo, %{
               work_package_id: work_package.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["dispatch:work_request"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })

    assert "architect phase-scoped grants require phase scope" in errors_on(changeset).phase_id
  end

  test "architect read and write work request grants require phase scope", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())

    for capability <- ["read:work_request", "write:work_request"] do
      work_key = WorkKey.generate()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Repository.create(repo, %{
                 work_package_id: work_package.id,
                 display_key: work_key.display_key,
                 secret_hash: WorkKey.secret_hash(work_key.secret),
                 grant_role: "architect",
                 capabilities: [capability],
                 expires_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
               })

      assert "architect phase-scoped grants require phase scope" in errors_on(changeset).phase_id
    end
  end

  test "architect read phase grants require a work package anchor", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-grant-missing-anchor", title: "Grant anchor"})
    work_key = WorkKey.generate()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Repository.create(repo, %{
               phase_id: phase.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })

    assert "architect phase-scoped grants require work package anchor" in errors_on(changeset).work_package_id
  end

  test "architect read phase grants require an anchor package inside the phase", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-grant-anchor", title: "Grant anchor"})
    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-grant-other", title: "Other phase"})

    assert {:ok, other_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-GRANT-OTHER", kind: "delegation", phase_id: other_phase.id)
             )

    work_key = WorkKey.generate()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Repository.create(repo, %{
               work_package_id: other_child.id,
               phase_id: phase.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })

    assert "must belong to architect phase" in errors_on(changeset).work_package_id
  end

  test "architect read phase grants report missing phase scope as a changeset error", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-GRANT-MISSING-PHASE", kind: "delegation")
             )

    work_key = WorkKey.generate()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Repository.create(repo, %{
               work_package_id: work_package.id,
               phase_id: "phase-missing",
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })

    assert "does not exist" in errors_on(changeset).phase_id
  end

  test "architect work request grants freeze anchor scope without read phase", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-grant-delegation", title: "Delegation phase"})

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-GRANT-DELEGATION",
                 kind: "mcp",
                 phase_id: phase.id,
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, %{grant: grant}} =
             Service.mint_architect_grant(repo, phase.id,
               work_package_id: work_package.id,
               capabilities: ["write:work_request"]
             )

    assert grant.phase_id == phase.id
    assert grant.scope_repo == work_package.repo
    assert grant.scope_base_branch == work_package.base_branch
  end

  test "architect work request grants without read phase require a valid anchor", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-grant-delegation-anchor", title: "Delegation anchor"})
    work_key = WorkKey.generate()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Repository.create(repo, %{
               phase_id: phase.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["write:work_request"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })

    assert Enum.any?(
             errors_on(changeset).work_package_id,
             &(&1 in ["can't be blank", "architect phase grants require work package anchor"])
           )
  end

  test "scope snapshot migration does not backfill legacy phase grants from current anchors" do
    database_path = WorkPackageFactory.database_path()
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      pre_scope_snapshot_migration = 20_260_506_120_000

      migrated_versions =
        Ecto.Migrator.run(Repo, Migrations.all(), :up,
          to: pre_scope_snapshot_migration,
          log: false
        )

      assert pre_scope_snapshot_migration in migrated_versions

      now = DateTime.utc_now(:microsecond)
      expires_at = DateTime.add(now, 86_400, :second)
      work_key = WorkKey.generate()

      Repo.query!(
        """
        INSERT INTO sympp_phases
          (id, title, description, status, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        ["phase-legacy-scope", "Legacy scope", nil, "active", now, now]
      )

      Repo.query!(
        """
        INSERT INTO sympp_work_packages
          (id, kind, title, repo, base_branch, branch_pattern, product_description,
           engineering_scope, acceptance_criteria, status, parent_id, owner_id,
           allowed_file_globs, policy_template, phase_id, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          "SYMPP-LEGACY-SCOPE",
          "mcp",
          "Legacy scope",
          "nextide/drifted",
          "main",
          nil,
          nil,
          nil,
          "[]",
          "planning",
          nil,
          nil,
          "[\"elixir/lib/**\"]",
          nil,
          "phase-legacy-scope",
          now,
          now
        ]
      )

      Repo.query!(
        """
        INSERT INTO sympp_access_grants
          (id, work_package_id, phase_id, display_key, secret_hash, grant_role,
           capabilities, expires_at, revoked_at, claimed_at, claimed_by,
           inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          "grant-legacy-scope",
          "SYMPP-LEGACY-SCOPE",
          "phase-legacy-scope",
          work_key.display_key,
          WorkKey.secret_hash(work_key.secret),
          "architect",
          Jason.encode!(["write:work_request"]),
          expires_at,
          nil,
          nil,
          nil,
          now,
          now
        ]
      )

      Ecto.Migrator.run(Repo, Migrations.all(), :up, all: true, log: false)

      result =
        Repo.query!(
          "SELECT scope_repo, scope_base_branch FROM sympp_access_grants WHERE id = ?",
          ["grant-legacy-scope"]
        )

      assert [[nil, nil]] = result.rows
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  test "grant scope migration backfills legacy worker and architect rows" do
    database_path = WorkPackageFactory.database_path()
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      pre_grant_scope_migration = 20_260_527_120_000

      migrated_versions =
        Ecto.Migrator.run(Repo, Migrations.all(), :up,
          to: pre_grant_scope_migration,
          log: false
        )

      assert pre_grant_scope_migration in migrated_versions

      now = DateTime.utc_now(:microsecond)
      worker_key = WorkKey.generate()
      architect_key = WorkKey.generate()
      foreign_architect_key = WorkKey.generate()
      operator_key = WorkKey.generate()

      assert {:ok, phase} = PhaseRepository.create(Repo, %{id: "phase-grant-scope-backfill", title: "Grant scope backfill"})

      work_package =
        insert_legacy_work_package!(Repo,
          id: "SYMPP-GRANT-SCOPE-BACKFILL",
          phase_id: phase.id,
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      insert_work_request!(Repo, "wr-grant-scope-backfill", work_package.repo, work_package.base_branch)
      insert_legacy_slice!(Repo, "wrs-grant-scope-backfill", "wr-grant-scope-backfill", work_package.id, work_package.base_branch)

      foreign_work_package =
        insert_legacy_work_package!(Repo,
          id: "SYMPP-GRANT-SCOPE-FOREIGN",
          phase_id: phase.id,
          repo: work_package.repo,
          base_branch: work_package.base_branch
        )

      insert_work_request!(Repo, "wr-grant-scope-foreign-branch", work_package.repo, "feature/other")
      insert_legacy_slice!(Repo, "wrs-grant-scope-foreign-branch", "wr-grant-scope-foreign-branch", foreign_work_package.id, "feature/other")

      Repo.query!(
        """
        INSERT INTO sympp_access_grants
          (id, work_package_id, phase_id, scope_repo, scope_base_branch, display_key,
           secret_hash, grant_role, provenance, capabilities, expires_at, revoked_at,
           claimed_at, claimed_by, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          "grant-worker-scope-backfill",
          work_package.id,
          nil,
          nil,
          nil,
          worker_key.display_key,
          WorkKey.secret_hash(worker_key.secret),
          "worker",
          nil,
          Jason.encode!(["worker:claim"]),
          nil,
          nil,
          nil,
          nil,
          now,
          now
        ]
      )

      Repo.query!(
        """
        INSERT INTO sympp_access_grants
          (id, work_package_id, phase_id, scope_repo, scope_base_branch, display_key,
           secret_hash, grant_role, provenance, capabilities, expires_at, revoked_at,
           claimed_at, claimed_by, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          "grant-architect-scope-foreign",
          foreign_work_package.id,
          phase.id,
          foreign_work_package.repo,
          foreign_work_package.base_branch,
          foreign_architect_key.display_key,
          WorkKey.secret_hash(foreign_architect_key.secret),
          "architect",
          nil,
          Jason.encode!(["read:work_request", "write:work_request"]),
          nil,
          nil,
          nil,
          nil,
          now,
          now
        ]
      )

      Repo.query!(
        """
        INSERT INTO sympp_access_grants
          (id, work_package_id, phase_id, scope_repo, scope_base_branch, display_key,
           secret_hash, grant_role, provenance, capabilities, expires_at, revoked_at,
           claimed_at, claimed_by, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          "grant-architect-scope-backfill",
          work_package.id,
          phase.id,
          work_package.repo,
          work_package.base_branch,
          architect_key.display_key,
          WorkKey.secret_hash(architect_key.secret),
          "architect",
          nil,
          Jason.encode!(["read:work_request", "write:work_request"]),
          nil,
          nil,
          nil,
          nil,
          now,
          now
        ]
      )

      Repo.query!(
        """
        INSERT INTO sympp_access_grants
          (id, work_package_id, phase_id, scope_repo, scope_base_branch, display_key,
           secret_hash, grant_role, provenance, capabilities, expires_at, revoked_at,
           claimed_at, claimed_by, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          "grant-operator-scope-backfill",
          work_package.id,
          nil,
          work_package.repo,
          work_package.base_branch,
          operator_key.display_key,
          WorkKey.secret_hash(operator_key.secret),
          "operator",
          nil,
          Jason.encode!(["operator:ledger"]),
          nil,
          nil,
          nil,
          nil,
          now,
          now
        ]
      )

      Ecto.Migrator.run(Repo, Migrations.all(), :up, all: true, log: false)

      worker_scopes =
        Repo.query!(
          """
          SELECT scope_type, scope_id, repo, base_branch
          FROM sympp_access_grant_scopes
          WHERE access_grant_id = ?
          ORDER BY scope_type
          """,
          ["grant-worker-scope-backfill"]
        )

      assert [["work_package", "SYMPP-GRANT-SCOPE-BACKFILL", nil, nil]] = worker_scopes.rows

      architect_scopes =
        Repo.query!(
          """
          SELECT scope_type, scope_id, repo, base_branch
          FROM sympp_access_grant_scopes
          WHERE access_grant_id = ?
          ORDER BY scope_type
          """,
          ["grant-architect-scope-backfill"]
        )

      assert ["repo", nil, "nextide/symphony-plus-plus", "main"] in architect_scopes.rows
      assert ["work_package", "SYMPP-GRANT-SCOPE-BACKFILL", nil, nil] in architect_scopes.rows
      assert ["work_request", "wr-grant-scope-backfill", nil, nil] in architect_scopes.rows

      foreign_scopes =
        Repo.query!(
          """
          SELECT scope_type, scope_id, repo, base_branch
          FROM sympp_access_grant_scopes
          WHERE access_grant_id = ?
          ORDER BY scope_type
          """,
          ["grant-architect-scope-foreign"]
        )

      assert ["repo", nil, "nextide/symphony-plus-plus", "main"] in foreign_scopes.rows
      assert ["work_package", "SYMPP-GRANT-SCOPE-FOREIGN", nil, nil] in foreign_scopes.rows
      refute Enum.any?(foreign_scopes.rows, &match?(["work_request", _, _, _], &1))

      operator_scopes =
        Repo.query!(
          """
          SELECT scope_type, scope_id, repo, base_branch
          FROM sympp_access_grant_scopes
          WHERE access_grant_id = ?
          """,
          ["grant-operator-scope-backfill"]
        )

      assert [] = operator_scopes.rows
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  test "non-id constraint failures are not reported as duplicate ids", %{repo: repo} do
    work_key = WorkKey.generate()

    assert {:error, {:constraint_failed, "foreign_key"}} =
             Repository.create(repo, %{
               work_package_id: "missing-work-package",
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "worker",
               capabilities: ["worker:claim"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })
  end

  test "raw secret is returned only at mint time and not emitted in logs", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())

    {minted, log} =
      capture_secret_log(fn ->
        assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)
        assert {:ok, %Assignment{} = assignment} = Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
        refute Map.has_key?(Map.from_struct(assignment), :secret)
        minted
      end)

    refute log =~ minted.work_key.secret
  end

  defp insert_work_request!(repo, id, repo_name, base_branch) do
    now = DateTime.utc_now(:microsecond)

    repo.query!(
      """
      INSERT INTO sympp_work_requests
        (id, title, repo, base_branch, work_type, human_description, constraints,
         desired_dispatch_shape, status, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        "Scoped WorkRequest",
        repo_name,
        base_branch,
        "implementation",
        "Scope test",
        Jason.encode!(%{}),
        "one_package",
        "ready_for_slicing",
        now,
        now
      ]
    )

    repo.get!(WorkRequest, id)
  end

  defp create_handoff_anchor!(repo, work_request_id) do
    work_request = insert_work_request!(repo, work_request_id, "nextide/example", "main")
    phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)
    anchor_id = ArchitectHandoff.anchor_id_for_work_request(work_request)

    assert {:ok, phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Architect handoff scope"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: anchor_id,
                 kind: "delegation",
                 phase_id: phase.id,
                 repo: work_request.repo,
                 base_branch: work_request.base_branch,
                 allowed_file_globs: []
               )
             )

    {phase, anchor, work_request}
  end

  defp attach_work_request!(repo, work_request_id, work_package_id) do
    work_package = repo.get!(SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage, work_package_id)

    repo.update!(
      Ecto.Changeset.change(work_package,
        work_request_id: work_request_id,
        sequence: 1,
        goal: "Persist scope",
        status: "ready_for_worker",
        dispatched_at: DateTime.utc_now(:microsecond)
      )
    )
  end

  defp insert_legacy_work_package!(repo, attrs) do
    now = DateTime.utc_now(:microsecond)

    repo.query!(
      """
      INSERT INTO sympp_work_packages
        (id, kind, title, repo, base_branch, acceptance_criteria, status,
         allowed_file_globs, phase_id, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        attrs[:id],
        "delegation",
        "Legacy scope package",
        attrs[:repo],
        attrs[:base_branch],
        "[]",
        "implementing",
        "[]",
        attrs[:phase_id],
        now,
        now
      ]
    )

    Map.new(attrs)
  end

  defp insert_legacy_slice!(repo, id, work_request_id, work_package_id, base_branch) do
    now = DateTime.utc_now(:microsecond)

    repo.query!(
      """
      INSERT INTO sympp_work_request_planned_slices
        (id, work_request_id, sequence, title, goal, work_package_kind,
         target_base_branch, branch_pattern, owned_file_globs, forbidden_file_globs,
         acceptance_criteria, validation_steps, review_lanes, stop_conditions, status,
         work_package_id, dispatched_at, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        work_request_id,
        1,
        "Scoped slice",
        "Persist scope",
        "mcp",
        base_branch,
        nil,
        "[]",
        "[]",
        "[]",
        "[]",
        "[]",
        "[]",
        "dispatched",
        work_package_id,
        now,
        now,
        now
      ]
    )
  end

  defp capture_secret_log(fun) do
    ref = make_ref()
    parent = self()

    log =
      capture_log(fn ->
        send(parent, {ref, fun.()})
      end)

    receive do
      {^ref, result} -> {result, log}
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end
end
