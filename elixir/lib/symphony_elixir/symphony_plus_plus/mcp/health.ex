defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Health do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Config,
    HandleStateStore,
    LocalTrustedTools,
    Session,
    ToolCatalog
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @protocol_version "2025-03-26"
  @assignment_resource "sympp://assignment/current"
  @version_resource "sympp://health/version"
  @bootstrap_tools ToolCatalog.bootstrap_tools()
  @mcp_contract_schema_version ToolCatalog.mcp_contract_schema_version()
  @mcp_contract_health_fields ToolCatalog.mcp_contract_health_fields()

  @spec health(map()) :: map()
  def health(%{config: %Config{health_ledger_mode: :configured_identity} = config}) do
    ledger = configured_identity_ledger_health(config)

    %{
      "status" => if(ledger["reachable"], do: "ok", else: "degraded"),
      "version" => config.version,
      "source" => source_identity(config),
      "mode" => Atom.to_string(config.mode),
      "ledger" => ledger
    }
  end

  def health(%{config: %Config{} = config}) do
    ledger = ledger_health(config)

    %{
      "status" => if(ledger["reachable"], do: "ok", else: "degraded"),
      "version" => config.version,
      "source" => source_identity(config),
      "mode" => Atom.to_string(config.mode),
      "ledger" => ledger
    }
  end

  @spec source_identity(Config.t()) :: map()
  def source_identity(%Config{source_revision: revision}) when is_binary(revision) and revision != "" do
    %{"revision" => String.downcase(revision), "mcp_contract" => mcp_contract_identity()}
  end

  def source_identity(%Config{}), do: %{"revision" => nil, "mcp_contract" => mcp_contract_identity()}

  @spec mcp_contract_identity() :: map()
  def mcp_contract_identity do
    %{
      "fingerprint" => mcp_contract_fingerprint(mcp_contract_material()),
      "schema_version" => @mcp_contract_schema_version
    }
  end

  defp mcp_contract_material do
    config = %Config{mode: :http, repo: Repo, version: "contract", source_revision: nil}

    %{
      "capabilities" => %{
        "resources" => %{},
        "tools" => %{}
      },
      "health_result_fields" => @mcp_contract_health_fields,
      "client_lease_protocol" => 1,
      "protocol_version" => @protocol_version,
      "resources" => resource_contract_material(),
      "schema_version" => @mcp_contract_schema_version,
      "tool_sets" => %{
        "architect" => ToolCatalog.architect_session_tool_specs(current_work_request?: false),
        "architect_current_work_request" => ToolCatalog.architect_session_tool_specs(current_work_request?: true),
        "claimable" => ToolCatalog.claimable_tool_specs(config),
        "local_operator" => LocalTrustedTools.tool_specs(config),
        "unbound" => hide_trusted_local_tool_specs(ToolCatalog.unbound_tool_specs_for_config(config)),
        "worker" => ToolCatalog.worker_session_tool_specs()
      }
    }
  end

  defp resource_contract_material do
    %{
      "list_sets" => %{
        "architect" => base_resource_specs() ++ current_assignment_resource_specs(),
        "unbound" => base_resource_specs(),
        "worker" => base_resource_specs() ++ current_assignment_resource_specs() ++ work_package_resource_template_specs()
      },
      "read_payloads" => %{
        @assignment_resource => %{
          "fields" => Session.public_assignment_fields(),
          "mimeType" => "application/json"
        },
        @version_resource => %{
          "fields" => [
            "mode",
            "source.mcp_contract.fingerprint",
            "source.mcp_contract.schema_version",
            "source.revision",
            "version"
          ],
          "mimeType" => "application/json"
        },
        "sympp://work-packages/{work_package_id}/{file_name}" => %{
          "file_names" => PlanningRenderer.virtual_files(),
          "mimeType" => "text/markdown"
        }
      }
    }
  end

  defp mcp_contract_fingerprint(material) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(canonical_contract_term(material)))
    |> Base.encode16(case: :lower)
  end

  defp canonical_contract_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical_contract_term(nested)} end)
    |> Enum.sort_by(fn {key, _nested} -> key end)
  end

  defp canonical_contract_term(value) when is_list(value), do: Enum.map(value, &canonical_contract_term/1)
  defp canonical_contract_term(value), do: value

  defp ledger_health(%Config{repo: repo, database: database}) do
    case normalized_database(database) do
      nil -> default_ledger_health(repo)
      database -> configured_ledger_health(repo, database)
    end
  end

  defp configured_identity_ledger_health(%Config{repo: repo, database: database}) do
    case normalized_database(database) do
      nil -> configured_identity_default_ledger_health(repo)
      database -> configured_identity_database_ledger_health(database, "explicit")
    end
  end

  defp configured_identity_default_ledger_health(repo) do
    case repo_configured_database_for_identity(repo) || default_repo_database_for_identity(repo) do
      database when is_binary(database) -> configured_identity_database_ledger_health(database, "default")
      _database -> unavailable_ledger_health(unknown_ledger_identity("default"))
    end
  end

  defp default_repo_database_for_identity(Repo), do: Repo.database_path_if_present() || Repo.database_path_without_side_effects()
  defp default_repo_database_for_identity(_repo), do: nil

  defp configured_identity_database_ledger_health(database, source) do
    case configured_ledger(database, source) do
      {:sqlite, ":memory:", identity} ->
        %{"reachable" => true, "identity" => identity}

      {:sqlite, path, identity} when is_binary(path) ->
        if File.exists?(Path.expand(path)) do
          %{"reachable" => true, "identity" => identity}
        else
          unavailable_ledger_health(identity)
        end

      {:server, identity} ->
        unavailable_ledger_health(identity)
    end
  end

  defp default_ledger_health(repo) do
    case live_main_database_path(repo) do
      {:ok, path} -> %{"reachable" => true, "identity" => sqlite_ledger_identity(path, "default")}
      :memory -> %{"reachable" => true, "identity" => sqlite_ledger_identity(":memory:", "default")}
      :error -> generic_default_ledger_health(repo)
    end
  end

  defp generic_default_ledger_health(repo) do
    identity = repo_configured_ledger_identity(repo, "default")

    try do
      case HandleStateStore.repo_query(repo, "SELECT 1", [], log: false) do
        {:ok, _result} -> %{"reachable" => true, "identity" => identity}
        {:error, _reason} -> %{"reachable" => false, "error" => "ledger_unavailable", "identity" => identity}
      end
    rescue
      _error -> %{"reachable" => false, "error" => "ledger_unavailable", "identity" => identity}
    end
  end

  defp configured_ledger_health(repo, database) do
    case configured_ledger(database, "explicit") do
      {:sqlite, path, identity} ->
        case configured_server_ledger_for_explicit_database(repo, database, "explicit") do
          {:server, identity} -> repo_reachable_ledger_health(repo, identity)
          nil -> configured_sqlite_ledger_health(repo, path, identity)
        end

      {:server, identity} ->
        if explicit_database_matches_repo_config?(repo, database) do
          repo_reachable_ledger_health(repo, identity)
        else
          unavailable_ledger_health(identity)
        end
    end
  end

  defp configured_sqlite_ledger_health(repo, path, identity) do
    case {path, live_main_database_path(repo)} do
      {":memory:", :memory} ->
        %{"reachable" => true, "identity" => identity}

      {path, {:ok, live_path}} when is_binary(path) ->
        if Repo.same_database_path?(path, live_path) do
          %{"reachable" => true, "identity" => identity}
        else
          unavailable_ledger_health(identity)
        end

      _unmatched ->
        unavailable_ledger_health(identity)
    end
  end

  defp repo_reachable_ledger_health(repo, identity) do
    case HandleStateStore.repo_query(repo, "SELECT 1", [], log: false) do
      {:ok, _result} -> %{"reachable" => true, "identity" => identity}
      {:error, _reason} -> unavailable_ledger_health(identity)
    end
  rescue
    _error -> unavailable_ledger_health(identity)
  end

  defp unavailable_ledger_health(identity),
    do: %{"reachable" => false, "error" => "ledger_unavailable", "identity" => identity}

  defp configured_ledger(database, source) do
    cond do
      Repo.memory_database?(database) ->
        {:sqlite, ":memory:", sqlite_ledger_identity(":memory:", source)}

      sqlite_file_uri?(database) ->
        {:sqlite, Repo.sqlite_file_uri_path(database), sqlite_file_uri_identity(database, source)}

      remote_database_identity?(database) ->
        {:server, server_ledger_identity(database, source)}

      true ->
        {:sqlite, database, sqlite_ledger_identity(database, source)}
    end
  end

  defp configured_ledger_identity(database, source), do: database |> configured_ledger(source) |> ledger_identity()

  defp ledger_identity({:sqlite, _path, identity}), do: identity
  defp ledger_identity({:server, identity}), do: identity

  defp repo_configured_ledger_identity(repo, source) do
    case repo_configured_database_for_identity(repo) do
      database when is_binary(database) -> configured_ledger_identity(database, source)
      _database -> unknown_ledger_identity(source)
    end
  end

  defp configured_server_ledger_for_explicit_database(repo, database, source) do
    with config when is_list(config) <- repo_config_for_identity(repo),
         true <- explicit_database_name_matches_repo_config?(config, database),
         identity_database when is_binary(identity_database) <- configured_server_database_for_identity(config) do
      {:server, server_ledger_identity(identity_database, source)}
    else
      _unmatched -> nil
    end
  end

  defp sqlite_file_uri_identity(database, source) do
    case Repo.sqlite_file_uri_path(database) do
      path when is_binary(path) and path != "" -> sqlite_ledger_identity(path, source)
      _path -> %{"kind" => "sqlite", "source" => source, "display_path" => "file:[redacted]", "default_home" => false}
    end
  end

  defp sqlite_ledger_identity(path, source) do
    %{
      "kind" => "sqlite",
      "source" => source,
      "display_path" => sqlite_display_path(path),
      "default_home" => default_home_database_path?(path)
    }
  end

  defp server_ledger_identity(database, source) do
    %{
      "kind" => "server",
      "source" => source,
      "endpoint" => safe_server_endpoint(database)
    }
  end

  defp live_main_database_path(repo) do
    case HandleStateStore.repo_query(repo, "PRAGMA database_list", [], log: false) do
      {:ok, %{rows: rows}} ->
        case Enum.find(rows, &match?([_seq, "main", _path], &1)) do
          [_seq, "main", path] when is_binary(path) and path != "" -> {:ok, path}
          [_seq, "main", ""] -> :memory
          _row -> :error
        end

      _result ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp normalized_database(database) when is_binary(database) do
    case String.trim(database) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_database(_database), do: nil

  defp sqlite_file_uri?("file:" <> _uri), do: true
  defp sqlite_file_uri?(_database), do: false

  defp remote_database_identity?(database) when is_binary(database) do
    remote_database_uri?(database) or server_database_dsn?(database) or credential_bearing_database_string?(database)
  end

  defp remote_database_uri?(database) do
    case URI.parse(database) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and scheme != "file" and is_binary(host) -> true
      %URI{scheme: scheme} when scheme in ["http", "https", "postgres", "postgresql", "mysql", "mssql"] -> true
      _uri -> false
    end
  rescue
    _error -> false
  end

  defp credential_bearing_database_string?(database) do
    database =~ ~r/(^|[;?\s])(password|passwd|pwd|secret|token|api[_-]?key)=/i
  end

  defp safe_server_endpoint(database) do
    case URI.parse(database) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        port_part = if is_integer(port), do: ":#{port}", else: ""
        "#{safe_endpoint_part(scheme)}://#{safe_endpoint_host(host)}#{port_part}"

      %URI{scheme: scheme} when is_binary(scheme) ->
        "#{safe_endpoint_part(scheme)}://[redacted]"

      _uri ->
        safe_server_dsn_endpoint(database)
    end
  rescue
    _error -> safe_server_dsn_endpoint(database)
  end

  defp safe_endpoint_part(part) do
    if part =~ ~r/\A[a-zA-Z][a-zA-Z0-9+.-]*\z/, do: String.downcase(part), else: "server"
  end

  defp safe_endpoint_host(host) do
    host = String.downcase(host)

    if host =~ ~r/\A[0-9a-z.:\-]+\z/ do
      if String.contains?(host, ":") and not String.starts_with?(host, "["),
        do: "[#{host}]",
        else: host
    else
      "[redacted]"
    end
  end

  defp safe_server_dsn_endpoint(database) do
    with values when map_size(values) > 0 <- server_database_dsn_values(database),
         host when is_binary(host) <- server_database_dsn_host(values) do
      {dsn_host, embedded_port} = split_server_dsn_host_port(host)
      port = server_database_dsn_port(values)
      "server://#{safe_endpoint_host(dsn_host)}#{if(port == "", do: embedded_port, else: port)}"
    else
      _missing_host -> "server"
    end
  end

  defp server_database_dsn?(database) do
    values = server_database_dsn_values(database)

    Enum.any?(["host", "hostname", "server", "addr", "address", "datasource"], &Map.has_key?(values, &1)) or
      Map.has_key?(values, "dbname") or
      (Map.has_key?(values, "database") and (Map.has_key?(values, "port") or Map.has_key?(values, "trustedconnection")))
  end

  defp server_database_dsn_values(database) do
    case normalized_database(database) do
      nil ->
        %{}

      database ->
        ~r/(?:^|[;\s])([A-Za-z][A-Za-z _-]*)\s*=\s*([^;\s]+)/
        |> Regex.scan(database)
        |> Map.new(fn [_match, key, value] -> {normalize_server_dsn_key(key), trim_server_dsn_value(value)} end)
    end
  end

  defp normalize_server_dsn_key(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[\s_-]/, "")
  end

  defp trim_server_dsn_value(value) do
    value
    |> String.trim()
    |> String.trim("\"'")
  end

  defp server_database_dsn_host(values) do
    Enum.find_value(["host", "hostname", "server", "addr", "address", "datasource"], &Map.get(values, &1))
  end

  defp server_database_dsn_port(values), do: Map.get(values, "port") |> safe_endpoint_port()

  defp split_server_dsn_host_port(host) do
    host =
      host
      |> String.trim()
      |> String.replace(~r/\A(?:tcp|udp):/i, "")

    case String.split(host, ",", parts: 2) do
      [dsn_host, port] -> {dsn_host, safe_endpoint_port(port)}
      [dsn_host] -> {dsn_host, ""}
    end
  end

  defp safe_endpoint_port(port) when is_binary(port) do
    port = String.trim(port)

    if port =~ ~r/\A\d{1,5}\z/ and String.to_integer(port) <= 65_535 do
      ":#{port}"
    else
      ""
    end
  end

  defp safe_endpoint_port(port) when is_integer(port) and port >= 0 and port <= 65_535, do: ":#{port}"

  defp safe_endpoint_port(_port), do: ""

  defp repo_config_for_identity(repo) when is_atom(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
      repo.config()
    else
      []
    end
  rescue
    _error -> []
  end

  defp repo_configured_database_for_identity(repo) do
    repo
    |> repo_config_for_identity()
    |> configured_database_for_identity()
  end

  defp explicit_database_matches_repo_config?(repo, database) do
    case repo_configured_database_for_identity(repo) do
      repo_database when is_binary(repo_database) -> repo_database == database
      _database -> false
    end
  end

  defp configured_database_for_identity(config) when is_list(config) do
    configured_database_url_for_identity(config) ||
      configured_database_host_for_identity(config) ||
      config |> Keyword.get(:database) |> normalized_database()
  end

  defp configured_server_database_for_identity(config) when is_list(config) do
    configured_database_url_for_identity(config) || configured_database_host_for_identity(config)
  end

  defp configured_database_url_for_identity(config) do
    config
    |> Keyword.get(:url)
    |> normalized_database()
  end

  defp configured_database_host_for_identity(config) do
    host =
      config
      |> Keyword.get(:hostname)
      |> case do
        host when is_binary(host) and host != "" -> host
        _missing -> Keyword.get(config, :host)
      end
      |> normalized_database()

    if is_binary(host) do
      port = Keyword.get(config, :port) |> safe_endpoint_port()
      "server://#{safe_endpoint_host(host)}#{port}"
    end
  end

  defp explicit_database_name_matches_repo_config?(config, database) do
    config
    |> Keyword.get(:database)
    |> normalized_database()
    |> Kernel.==(database)
  end

  defp sqlite_display_path(":memory:"), do: ":memory:"

  defp sqlite_display_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> normalize_display_separator()
    |> display_home_relative_path()
  end

  defp normalize_display_separator(path), do: String.replace(path, "\\", "/")

  defp display_home_relative_path(path) do
    with home when is_binary(home) and home != "" <- System.user_home(),
         normalized_home <- home |> Path.expand() |> normalize_display_separator(),
         true <- path == normalized_home or String.starts_with?(path, normalized_home <> "/") do
      relative = binary_part(path, byte_size(normalized_home), byte_size(path) - byte_size(normalized_home))

      case String.trim_leading(relative, "/") do
        "" -> "$HOME"
        relative -> "$HOME/" <> relative
      end
    else
      _not_home -> path
    end
  end

  defp default_home_database_path?(path) do
    with path when is_binary(path) <- normalized_database(path),
         home when is_binary(home) and home != "" <- System.user_home() do
      default_home_database =
        [home, ".agents", "splusplus", "symphony_plus_plus.sqlite3"]
        |> Path.join()
        |> Path.expand()

      Repo.same_database_path?(path, default_home_database)
    else
      _unmatched -> false
    end
  end

  defp unknown_ledger_identity(source), do: %{"kind" => "unknown", "source" => source}

  defp hide_trusted_local_tool_specs(specs) do
    Enum.reject(specs, &(&1["name"] in @bootstrap_tools))
  end

  defp base_resource_specs do
    [
      %{
        "uri" => @version_resource,
        "name" => "Symphony++ version",
        "mimeType" => "application/json"
      }
    ]
  end

  defp current_assignment_resource_specs do
    [
      %{
        "uri" => @assignment_resource,
        "name" => "Current Symphony++ assignment",
        "mimeType" => "application/json"
      }
    ]
  end

  defp work_package_resource_template_specs do
    Enum.map(PlanningRenderer.virtual_files(), fn file_name ->
      %{
        "uri_template" => "sympp://work-packages/{work_package_id}/#{file_name}",
        "name" => file_name,
        "mimeType" => "text/markdown"
      }
    end)
  end
end
