defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AllowNullAccessGrantExpiry do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    repo().checkout(fn ->
      if expires_at_not_null?() do
        rebuild_access_grants_with_nullable_expiry()
      end
    end)
  end

  def down do
    raise "irreversible migration: access grants may contain non-expiring rows"
  end

  defp expires_at_not_null? do
    %{rows: rows} = repo().query!("PRAGMA table_info(sympp_access_grants)")

    Enum.any?(rows, fn
      [_cid, "expires_at", _type, not_null, _default_value, _primary_key] -> not_null in [1, true]
      _column -> false
    end)
  end

  defp rebuild_access_grants_with_nullable_expiry do
    query!("PRAGMA foreign_keys = OFF")

    try do
      query!("""
      CREATE TABLE sympp_access_grants_expiry_migration (
        id TEXT PRIMARY KEY NOT NULL,
        work_package_id TEXT NOT NULL REFERENCES sympp_work_packages(id) ON DELETE CASCADE,
        display_key TEXT NOT NULL,
        secret_hash TEXT NOT NULL,
        grant_role TEXT NOT NULL,
        capabilities TEXT NOT NULL DEFAULT '[]',
        expires_at TEXT,
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

      query!("""
      INSERT INTO sympp_access_grants_expiry_migration (
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

      query!("DROP TABLE sympp_access_grants")
      query!("ALTER TABLE sympp_access_grants_expiry_migration RENAME TO sympp_access_grants")
      recreate_indexes()
    after
      query!("PRAGMA foreign_keys = ON")
    end
  end

  defp recreate_indexes do
    query!("CREATE UNIQUE INDEX sympp_access_grants_id_unique_index ON sympp_access_grants (id)")
    query!("CREATE UNIQUE INDEX sympp_access_grants_secret_hash_unique_index ON sympp_access_grants (secret_hash)")
    query!("CREATE INDEX sympp_access_grants_work_package_id_index ON sympp_access_grants (work_package_id)")
    query!("CREATE INDEX sympp_access_grants_display_key_index ON sympp_access_grants (display_key)")
    query!("CREATE INDEX sympp_access_grants_grant_role_index ON sympp_access_grants (grant_role)")
    query!("CREATE INDEX sympp_access_grants_phase_id_index ON sympp_access_grants (phase_id)")
  end

  defp query!(sql), do: repo().query!(sql)
end
