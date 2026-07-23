defmodule SymphonyElixir.SymphonyPlusPlus.PluginLauncherSourceDiscoveryTest do
  use ExUnit.Case, async: true

  @moduletag :ci_slow

  @repo_root Path.expand("../../../../", __DIR__)
  @plugin_marketplace_name "symphony-plus-plus"
  @plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json")
  @plugin_version @plugin_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("version")
  @plugin_solo_script_path Path.join(@repo_root, "plugins/symphony-plus-plus/scripts/sympp-solo.ps1")
  @mcp_plugin_solo_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-solo.ps1")
  @mcp_plugin_start_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")

  test "installed launchers resolve marketplace source clone despite missing or stale cache hints" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-marketplace-source")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      stale_source_root = write_minimal_stale_source(temp_codex_home)
      default_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"])
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(default_cache_root)
        File.write!(Path.join(default_cache_root, ".sympp-source-root"), "#{stale_source_root}\n")
        File.mkdir_p!(mcp_cache_root)
        File.write!(Path.join(mcp_cache_root, ".sympp-source-root"), "#{stale_source_root}\n")

        launchers = [
          {write_cached_script(default_cache_root, @plugin_solo_script_path), "Symphony++ Solo Session wrapper validation passed."},
          {write_cached_script(mcp_cache_root, @mcp_plugin_solo_script_path), "Symphony++ Solo Session wrapper validation passed."},
          {write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path), "Symphony++ MCP launcher validation passed."}
        ]

        for {script_path, expected} <- launchers do
          {output, status} =
            System.cmd(
              powershell,
              ["-NoProfile", "-File", script_path, "-ValidateOnly"],
              cd: Path.dirname(Path.dirname(script_path)),
              stderr_to_stdout: true,
              env: [
                {"SYMPP_LAUNCHER", "direct"},
                {"SYMPP_MIX", fake_mix},
                {"SYMPP_REPO_ROOT", ""},
                {"SYMPP_SOURCE_FALLBACK", "1"}
              ]
            )

          assert status == 0, output
          assert output =~ expected
          assert normalize_path_fragment(output) =~ "reporoot: #{normalize_path_fragment(marketplace_root)}"
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed Solo wrapper help derives usage from cache package name" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-help-cache-path")

    if powershell do
      default_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"])
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")

      try do
        wrappers = [
          {write_cached_script(default_cache_root, @plugin_solo_script_path), "pwsh plugins/symphony-plus-plus/scripts/sympp-solo.ps1 -Help"},
          {write_cached_script(mcp_cache_root, @mcp_plugin_solo_script_path), "pwsh plugins/symphony-plus-plus-mcp/scripts/sympp-solo.ps1 -Help"}
        ]

        for {script_path, expected_usage} <- wrappers do
          {output, status} =
            System.cmd(
              powershell,
              ["-NoProfile", "-File", script_path, "-Help"],
              cd: Path.dirname(Path.dirname(script_path)),
              stderr_to_stdout: true
            )

          assert status == 0, output
          assert output =~ expected_usage
          refute output =~ "plugins/1.0.0/scripts/sympp-solo.ps1"
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed launchers default to mise for source checkouts with mise config" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-marketplace-mise-default")

    if powershell do
      fake_mise = fake_mise_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      File.write!(Path.join(marketplace_root, "elixir/mise.toml"), "[tools]\nelixir = \"1.19.5-otp-28\"\n")
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        launchers = [
          {write_cached_script(mcp_cache_root, @mcp_plugin_solo_script_path), "Symphony++ Solo Session wrapper validation passed."},
          {write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path), "Symphony++ MCP launcher validation passed."}
        ]

        for {script_path, expected} <- launchers do
          {output, status} =
            System.cmd(
              powershell,
              ["-NoProfile", "-File", script_path, "-ValidateOnly"],
              cd: Path.dirname(Path.dirname(script_path)),
              stderr_to_stdout: true,
              env: [
                {"SYMPP_MISE", fake_mise},
                {"SYMPP_REPO_ROOT", ""},
                {"SYMPP_HOME", sympp_home},
                {"SYMPP_SOURCE_FALLBACK", "1"}
              ]
            )

          assert status == 0, output
          assert output =~ expected
          assert output =~ "Mix 1.98.0 mise"
          assert output =~ "launcher: mise"
          assert normalize_path_fragment(output) =~ "mixbuildroot: #{normalize_path_fragment(sympp_home)}"
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "Solo wrapper keeps direct default for source checkouts without mise config" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-marketplace-direct-default")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_solo_script_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [{"SYMPP_MIX", fake_mix}, {"SYMPP_REPO_ROOT", ""}, {"SYMPP_HOME", sympp_home}]
          )

        assert status == 0, output
        assert output =~ "Symphony++ Solo Session wrapper validation passed."
        assert output =~ "Mix 1.99.0 test"
        assert output =~ "launcher: direct"
        assert normalize_path_fragment(output) =~ "mixbuildroot: #{normalize_path_fragment(sympp_home)}"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed launchers fall back to direct when mise config cannot run" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-marketplace-mise-probe-fails")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      fake_mise = fake_failing_mise_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      File.write!(Path.join(marketplace_root, "elixir/mise.toml"), "[tools]\nelixir = \"1.19.5-otp-28\"\n")
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_solo_script_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_MISE", fake_mise},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_HOME", sympp_home}
            ]
          )

        assert status == 0, output
        assert output =~ "Symphony++ Solo Session wrapper validation passed."
        assert output =~ "Mix 1.99.0 test"
        assert output =~ "launcher: direct"
        assert normalize_path_fragment(output) =~ "mixbuildroot: #{normalize_path_fragment(sympp_home)}"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "direct stdio launcher fetches locked deps before running MCP from marketplace source clone" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-elixir-deps")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")
      log_dir = Path.join(temp_codex_home, "logs")

      try do
        File.mkdir_p!(mcp_cache_root)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-Command",
              "& { param($ScriptPath) & $ScriptPath }",
              script_path
            ],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_ELIXIR_SETUP_TIMEOUT_SEC", "5"},
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_LOG_DIR", log_dir},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert status == 0, output

        assert normalize_path_fragment(output) =~
                 "ensuring symphony++ elixir dependencies are available in #{normalize_path_fragment(Path.join(marketplace_root, "elixir"))}."

        fake_mix_calls =
          fake_mix_log
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.replace(&1, "\"", ""))
          |> Enum.filter(
            &(String.contains?(&1, "deps.get") or &1 == "compile" or
                String.starts_with?(&1, "sympp.mcp "))
          )

        assert ["deps.get --check-locked", "compile", mcp_call] = fake_mix_calls
        assert String.starts_with?(mcp_call, "sympp.mcp ")
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "Solo wrapper validates and prepares locked deps before running Solo task" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-solo-deps")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_solo_script_path)

        {validate_output, validate_status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert validate_status == 0, validate_output
        assert File.dir?(Path.join(sympp_home, "build/solo/direct"))

        {solo_output, solo_status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "list", "--repo", "demo"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert solo_status == 0, solo_output

        fake_mix_calls =
          fake_mix_log
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.replace(&1, "\"", ""))
          |> Enum.filter(
            &(String.contains?(&1, "deps.get") or &1 == "sympp.solo --help" or
                String.starts_with?(&1, "sympp.solo "))
          )

        assert [
                 "deps.get --check-locked",
                 "sympp.solo --help",
                 "deps.get --check-locked",
                 "sympp.solo list --repo demo"
               ] = fake_mix_calls
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  defp write_cached_script(cache_root, source_script_path) do
    target = Path.join([cache_root, "scripts", Path.basename(source_script_path)])
    File.mkdir_p!(Path.dirname(target))
    File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{String.duplicate("b", 40)}\n")
    File.cp!(source_script_path, target)

    for helper_name <-
          ~w(sympp-launcher-runtime.ps1 sympp-mcp-launcher-helpers.ps1 sympp-mcp-artifact-manifest.ps1 sympp-mcp-artifact-channel.ps1 sympp-mcp-artifact-runtime.ps1 sympp-mcp-process-runtime.ps1 sympp-diagnostic-runtime-artifacts.ps1 sympp-diagnostic-launcher-artifacts.ps1 sympp-diagnostic-self-test.ps1) do
      source_helper = Path.join(Path.dirname(source_script_path), helper_name)

      if File.exists?(source_helper) do
        File.cp!(source_helper, Path.join(Path.dirname(target), helper_name))
      end
    end

    target
  end

  defp write_cache_manifest(cache_root, plugin_name, opts \\ []) do
    manifest_path = Path.join(cache_root, ".codex-plugin/plugin.json")
    File.mkdir_p!(Path.dirname(manifest_path))

    manifest =
      if Keyword.get(opts, :mcp?, false) do
        %{"name" => plugin_name, "version" => @plugin_version, "mcpServers" => "./.mcp.json"}
      else
        %{"name" => plugin_name, "version" => @plugin_version}
      end

    File.write!(manifest_path, Jason.encode!(manifest))

    if Keyword.get(opts, :mcp?, false) do
      File.write!(
        Path.join(cache_root, ".mcp.json"),
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "cmd.exe",
            "args" => ["/d", "/s", "/c", "scripts/start-sympp-mcp.cmd"],
            "cwd" => "."
          }
        })
      )
    end
  end

  defp write_minimal_marketplace_source(codex_home) do
    marketplace_root = Path.join([codex_home, ".tmp", "marketplaces", @plugin_marketplace_name])
    File.mkdir_p!(marketplace_root)
    File.write!(Path.join(marketplace_root, ".codex-marketplace-install.json"), Jason.encode!(%{"revision" => String.duplicate("b", 40)}))
    File.mkdir_p!(Path.join(marketplace_root, "elixir"))
    File.write!(Path.join(marketplace_root, "elixir/mix.exs"), "defmodule SymphonyElixir.MixProject do\nend\n")
    File.mkdir_p!(Path.join(marketplace_root, "elixir/lib/mix/tasks"))
    File.write!(Path.join(marketplace_root, "elixir/lib/mix/tasks/sympp.solo.ex"), "")
    File.mkdir_p!(Path.join(marketplace_root, "scripts"))
    File.write!(Path.join(marketplace_root, "scripts/refresh-local-plugin.ps1"), "")
    File.write!(Path.join(marketplace_root, "scripts/smoke-sympp-mcp-http.ps1"), "")
    File.mkdir_p!(Path.join(marketplace_root, "elixir/priv/symphony_plus_plus"))

    File.cp!(
      Path.join(@repo_root, "elixir/priv/symphony_plus_plus/mcp_contract.json"),
      Path.join(marketplace_root, "elixir/priv/symphony_plus_plus/mcp_contract.json")
    )

    File.mkdir_p!(Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts"))

    File.cp!(
      @mcp_plugin_start_script_path,
      Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")
    )

    for helper_name <-
          ~w(sympp-launcher-runtime.ps1 sympp-mcp-launcher-helpers.ps1 sympp-mcp-artifact-manifest.ps1 sympp-mcp-artifact-channel.ps1 sympp-mcp-artifact-runtime.ps1 sympp-mcp-process-runtime.ps1) do
      File.cp!(
        Path.join(Path.dirname(@mcp_plugin_start_script_path), helper_name),
        Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts/#{helper_name}")
      )
    end

    write_cache_manifest(Path.join(marketplace_root, "plugins/symphony-plus-plus"), "symphony-plus-plus")
    write_cache_manifest(Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp"), "symphony-plus-plus-mcp", mcp?: true)

    marketplace_root
  end

  defp write_minimal_stale_source(codex_home) do
    source_root = Path.join(codex_home, "stale-source")
    File.mkdir_p!(Path.join(source_root, "elixir/lib/mix/tasks"))
    File.write!(Path.join(source_root, "elixir/mix.exs"), "defmodule Stale.MixProject do\nend\n")
    File.write!(Path.join(source_root, "elixir/lib/mix/tasks/sympp.solo.ex"), "")
    source_root
  end

  defp fake_mix_executable(temp_root) do
    path = Path.join(temp_root, if(windows?(), do: "mix.cmd", else: "mix"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, fake_mix_script())

    unless windows?() do
      File.chmod!(path, 0o755)
    end

    path
  end

  defp fake_mise_executable(temp_root) do
    path = Path.join(temp_root, if(windows?(), do: "mise.cmd", else: "mise"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, fake_mise_script())

    unless windows?() do
      File.chmod!(path, 0o755)
    end

    path
  end

  defp fake_failing_mise_executable(temp_root) do
    path = Path.join(temp_root, if(windows?(), do: "failing-mise.cmd", else: "failing-mise"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, fake_failing_mise_script())

    unless windows?() do
      File.chmod!(path, 0o755)
    end

    path
  end

  defp fake_mix_script do
    if windows?() do
      """
      @echo off
      if not "%SYMPP_FAKE_MIX_LOG%"=="" echo %*>>"%SYMPP_FAKE_MIX_LOG%"
      if "%~1"=="--version" (
        echo Mix 1.99.0 test
        exit /b 0
      )
      if "%~1"=="deps.get" (
        if "%~2"=="--check-locked" exit /b 0
        exit /b 3
      )
      if "%~1"=="compile" (
        exit /b 0
      )
      if "%~1"=="sympp.mcp" (
        exit /b 0
      )
      if "%~1"=="sympp.solo" (
        exit /b 0
      )
      echo unexpected mix args: %*
      exit /b 2
      """
    else
      """
      #!/usr/bin/env sh
      if [ -n "$SYMPP_FAKE_MIX_LOG" ]; then
        printf '%s\\n' "$*" >> "$SYMPP_FAKE_MIX_LOG"
      fi
      if [ "$1" = "--version" ]; then
        echo "Mix 1.99.0 test"
        exit 0
      fi
      if [ "$1" = "deps.get" ]; then
        if [ "$2" = "--check-locked" ]; then
          exit 0
        fi
        exit 3
      fi
      if [ "$1" = "compile" ]; then
        exit 0
      fi
      if [ "$1" = "sympp.mcp" ]; then
        exit 0
      fi
      if [ "$1" = "sympp.solo" ]; then
        exit 0
      fi
      echo "unexpected mix args: $*" >&2
      exit 2
      """
    end
  end

  defp fake_mise_script do
    if windows?() do
      """
      @echo off
      if not "%SYMPP_FAKE_MISE_LOG%"=="" echo %*>>"%SYMPP_FAKE_MISE_LOG%"
      if "%~1"=="exec" if "%~2"=="--" if "%~3"=="mix" if "%~4"=="--version" (
        echo Mix 1.98.0 mise
        exit /b 0
      )
      if "%~1"=="exec" if "%~2"=="--" if "%~3"=="mix" if "%~4"=="deps.get" if "%~5"=="--check-locked" (
        exit /b 0
      )
      if "%~1"=="exec" if "%~2"=="--" if "%~3"=="mix" if "%~4"=="sympp.solo" if "%~5"=="--help" (
        exit /b 0
      )
      echo unexpected mise args: %*
      exit /b 2
      """
    else
      """
      #!/usr/bin/env sh
      if [ -n "$SYMPP_FAKE_MISE_LOG" ]; then
        printf '%s\\n' "$*" >> "$SYMPP_FAKE_MISE_LOG"
      fi
      if [ "$1" = "exec" ] && [ "$2" = "--" ] && [ "$3" = "mix" ] && [ "$4" = "--version" ]; then
        echo "Mix 1.98.0 mise"
        exit 0
      fi
      if [ "$1" = "exec" ] && [ "$2" = "--" ] && [ "$3" = "mix" ] && [ "$4" = "deps.get" ] && [ "$5" = "--check-locked" ]; then
        exit 0
      fi
      if [ "$1" = "exec" ] && [ "$2" = "--" ] && [ "$3" = "mix" ] && [ "$4" = "sympp.solo" ] && [ "$5" = "--help" ]; then
        exit 0
      fi
      echo "unexpected mise args: $*" >&2
      exit 2
      """
    end
  end

  defp fake_failing_mise_script do
    if windows?() do
      """
      @echo off
      echo failing mise args: %* 1>&2
      exit /b 2
      """
    else
      """
      #!/usr/bin/env sh
      echo "failing mise args: $*" >&2
      exit 2
      """
    end
  end

  defp windows?, do: match?({:win32, _name}, :os.type())

  defp normalize_path_fragment(value) do
    value
    |> String.replace("\\", "/")
    |> String.downcase()
  end

  defp unique_temp_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{unique_id()}")
  end

  defp unique_id do
    id = "#{System.pid()}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    String.replace(id, ~r/[^A-Za-z0-9_.-]/, "-")
  end

  defp plugin_cache_path(codex_home, suffix, plugin_name \\ "symphony-plus-plus") do
    Path.join([codex_home, "plugins", "cache", @plugin_marketplace_name, plugin_name] ++ suffix)
  end
end
