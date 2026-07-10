defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Config do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @default_repo_root __DIR__ |> Path.join("../../../../..") |> Path.expand()
  @source_revision_key {__MODULE__, :source_revision}
  @surface_profiles ~w(full worker architect coordinator solo)a

  @enforce_keys [:mode, :repo, :version]
  defstruct [
    :mode,
    :repo,
    :version,
    :source_revision,
    :database,
    :repo_root,
    :claimed_by,
    surface_profile: :full,
    health_ledger_mode: :live,
    local_daemon_trusted: false
  ]

  @type t :: %__MODULE__{
          mode: :stdio | :http,
          repo: module(),
          version: String.t(),
          source_revision: String.t() | nil,
          database: String.t() | nil,
          repo_root: String.t() | nil,
          claimed_by: String.t() | nil,
          surface_profile: :full | :worker | :architect | :coordinator | :solo,
          health_ledger_mode: :live | :configured_identity,
          local_daemon_trusted: boolean()
        }

  @switches [
    database: :string,
    mode: :string,
    repo_root: :string,
    claimed_by: :string,
    surface_profile: :string,
    help: :boolean
  ]

  @spec default(keyword()) :: t()
  def default(opts \\ []) do
    %__MODULE__{
      mode: Keyword.get(opts, :mode, :stdio),
      repo: Keyword.get(opts, :repo, Repo),
      version: Keyword.get(opts, :version, application_version()),
      source_revision: Keyword.get_lazy(opts, :source_revision, &source_revision/0),
      database: Keyword.get(opts, :database),
      repo_root: Keyword.get(opts, :repo_root),
      claimed_by: Keyword.get(opts, :claimed_by),
      surface_profile: surface_profile!(Keyword.get(opts, :surface_profile, System.get_env("SYMPP_MCP_SURFACE_PROFILE"))),
      health_ledger_mode: Keyword.get(opts, :health_ledger_mode, :live),
      local_daemon_trusted: Keyword.get(opts, :local_daemon_trusted, false)
    }
  end

  @doc false
  @spec source_revision() :: String.t() | nil
  def source_revision do
    case :persistent_term.get(@source_revision_key, :unset) do
      :unset ->
        revision = load_source_revision()
        :persistent_term.put(@source_revision_key, revision)
        revision

      revision ->
        revision
    end
  end

  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()} | :help
  def parse(args) when is_list(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false) do
          :help
        else
          parse_options(opts)
        end

      {_opts, _argv, _invalid} ->
        {:error, usage()}
    end
  end

  @spec usage() :: String.t()
  def usage do
    [
      "Usage: mix sympp.mcp [--mode stdio] [--database <sqlite-path>] [--repo-root <path>] [--claimed-by <agent-id>] [--surface-profile <full|worker|architect|coordinator|solo>]",
      Repo.default_database_help_text()
    ]
    |> Enum.join("\n")
  end

  defp parse_options(opts) do
    with {:ok, mode} <- parse_mode(Keyword.get(opts, :mode, "stdio")),
         {:ok, repo_root} <- optional_nonblank(opts, :repo_root),
         {:ok, claimed_by} <- optional_nonblank(opts, :claimed_by),
         {:ok, surface_profile} <- parse_surface_profile(Keyword.get(opts, :surface_profile, System.get_env("SYMPP_MCP_SURFACE_PROFILE"))) do
      {:ok,
       default(
         mode: mode,
         database: Keyword.get(opts, :database),
         repo_root: expand_optional_path(repo_root),
         claimed_by: claimed_by,
         surface_profile: surface_profile
       )}
    end
  end

  defp parse_mode("stdio"), do: {:ok, :stdio}
  defp parse_mode(_mode), do: {:error, "Only STDIO MCP mode is supported for SYMPP-P3-001.\n#{usage()}"}

  defp parse_surface_profile(nil), do: {:ok, :full}

  defp parse_surface_profile(profile) when is_atom(profile) do
    if profile in @surface_profiles, do: {:ok, profile}, else: {:error, usage()}
  end

  defp parse_surface_profile(profile) when is_binary(profile) do
    profile = profile |> String.trim() |> String.downcase()

    case profile do
      "default" ->
        {:ok, :full}

      profile ->
        case Enum.find(@surface_profiles, &(Atom.to_string(&1) == profile)) do
          nil -> {:error, usage()}
          profile -> {:ok, profile}
        end
    end
  end

  defp parse_surface_profile(_profile), do: {:error, usage()}

  defp surface_profile!(profile) do
    case parse_surface_profile(profile) do
      {:ok, profile} -> profile
      {:error, _usage} -> raise ArgumentError, "invalid Symphony++ MCP surface profile"
    end
  end

  defp optional_nonblank(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, usage()}, else: {:ok, value}

      {:ok, _value} ->
        {:error, usage()}

      :error ->
        {:ok, nil}
    end
  end

  defp expand_optional_path(nil), do: nil
  defp expand_optional_path(path), do: Path.expand(path)

  defp application_version do
    case Application.spec(:symphony_elixir, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      _missing -> "0.1.0"
    end
  end

  defp load_source_revision do
    env_revision = source_revision_from_env()

    if env_revision do
      env_revision
    else
      source_revision_from_git()
    end
  end

  defp source_revision_from_env do
    "SYMPP_SOURCE_REVISION"
    |> System.get_env()
    |> normalize_source_revision()
  end

  defp source_revision_from_git do
    with git when is_binary(git) <- System.find_executable("git") || System.find_executable("git.exe"),
         {revision, 0} <- System.cmd(git, ["-C", @default_repo_root, "rev-parse", "--verify", "HEAD"], stderr_to_stdout: true),
         revision when is_binary(revision) <- normalize_source_revision(revision) do
      revision
    else
      _missing_or_invalid -> nil
    end
  end

  defp normalize_source_revision(revision) when is_binary(revision) do
    revision = String.trim(revision)

    if revision =~ ~r/\A[0-9a-f]{40}\z/i do
      String.downcase(revision)
    end
  end

  defp normalize_source_revision(_revision), do: nil
end
