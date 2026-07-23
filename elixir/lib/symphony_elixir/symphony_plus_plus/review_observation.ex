defmodule SymphonyElixir.SymphonyPlusPlus.ReviewObservation do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @cache_table __MODULE__
  @ttl_ms 120_000
  @timeout_ms 3_000
  @max_output_bytes 64_000
  @terminal_statuses ["skipped", "merged", "merged_into_phase", "closed", "abandoned"]

  @spec observe([WorkPackage.t()], keyword()) :: %{optional(String.t()) => map()}
  def observe(work_packages, opts \\ []) when is_list(work_packages) do
    table = Keyword.get(opts, :cache_table, @cache_table)
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
    ttl_ms = Keyword.get(opts, :ttl_ms, @ttl_ms)
    runner = Keyword.get(opts, :runner, &run/4)
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)
    ensure_table(table)

    work_packages
    |> Enum.filter(&eligible?/1)
    |> observe_eligible(%{
      table: table,
      now_ms: now_ms,
      ttl_ms: ttl_ms,
      runner: runner,
      find_executable: find_executable
    })
  end

  defp observe_eligible([], _config), do: %{}

  defp observe_eligible(eligible, config) do
    %{table: table, now_ms: now_ms, ttl_ms: ttl_ms, runner: runner, find_executable: find_executable} = config

    if :ets.insert_new(table, {:refreshing, self()}) do
      try do
        case cached(table, :review_suite_script, now_ms, ttl_ms, fn -> discover(runner, find_executable) end) do
          {:ok, script} ->
            eligible
            |> Enum.group_by(&Path.expand(&1.worktree_path))
            |> Task.async_stream(&observe_worktree(&1, script, config),
              max_concurrency: 4,
              ordered: false,
              timeout: @timeout_ms + 250,
              on_timeout: :kill_task
            )
            |> Enum.reduce(%{}, &collect_observation/2)

          _missing_provider ->
            %{}
        end
      after
        :ets.delete(table, :refreshing)
      end
    else
      cached(eligible, table: table, now_ms: now_ms, ttl_ms: ttl_ms)
    end
  end

  @doc false
  @spec release_refresh(pid(), atom() | :ets.tid()) :: :ok
  def release_refresh(owner, table \\ @cache_table) when is_pid(owner) do
    if table_exists?(table) do
      :ets.delete_object(table, {:refreshing, owner})
    end

    :ok
  end

  defp table_exists?(table) when is_atom(table), do: :ets.whereis(table) != :undefined
  defp table_exists?(_table), do: true

  defp observe_worktree({worktree, packages}, script, config) do
    %{table: table, now_ms: now_ms, ttl_ms: ttl_ms, runner: runner, find_executable: find_executable} = config

    observation =
      cached(table, {:observation, worktree}, now_ms, ttl_ms, fn ->
        status(script, worktree, runner, find_executable)
      end)

    {packages, observation}
  end

  defp collect_observation({:ok, {packages, {:ok, observation}}}, acc) do
    Enum.reduce(packages, acc, &Map.put(&2, &1.id, observation))
  end

  defp collect_observation(_no_observation, acc), do: acc

  @spec cached([WorkPackage.t()], keyword()) :: %{optional(String.t()) => map()}
  def cached(work_packages, opts \\ []) when is_list(work_packages) do
    table = Keyword.get(opts, :cache_table, @cache_table)
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
    ttl_ms = Keyword.get(opts, :ttl_ms, @ttl_ms)
    ensure_table(table)

    work_packages
    |> Enum.filter(&eligible?/1)
    |> Enum.reduce(%{}, fn work_package, observations ->
      key = {:observation, Path.expand(work_package.worktree_path)}

      case cached_value(table, key, now_ms, ttl_ms) do
        {:ok, {:ok, observation}} -> Map.put(observations, work_package.id, observation)
        _missing -> observations
      end
    end)
  end

  defp eligible?(%WorkPackage{
         id: id,
         status: status,
         worktree_path: worktree,
         review_requirement: requirement
       }) do
    is_binary(id) and status not in @terminal_statuses and
      is_binary(worktree) and File.dir?(worktree) and
      map_value(requirement, "type") == "review-suite"
  end

  defp discover(runner, find_executable) do
    with codex when is_binary(codex) <- find_executable.("codex"),
         {:ok, output} <- runner.(codex, ["plugin", "list", "--json"], @timeout_ms, @max_output_bytes),
         {:ok, %{"installed" => installed}} when is_list(installed) <- Jason.decode(output),
         [plugin] <-
           Enum.filter(installed, &(map_value(&1, "pluginId") == "review-suite@review-suite" and map_value(&1, "enabled") == true)),
         path when is_binary(path) <- plugin |> map_value("source") |> map_value("path"),
         script = Path.join([path, "scripts", "review.py"]),
         true <- File.regular?(script) do
      {:ok, script}
    else
      _missing_or_ambiguous -> :error
    end
  end

  defp status(script, worktree, runner, find_executable) do
    with python when is_binary(python) <- find_executable.("python3") || find_executable.("python"),
         {:ok, output} <-
           runner.(python, [script, "--status", "--json", "--cd", worktree], @timeout_ms, @max_output_bytes),
         {:ok, payload} when is_map(payload) <- Jason.decode(output),
         review when is_binary(review) and review != "" <- map_value(payload, "review") do
      {:ok,
       %{
         evidence_id: review,
         status: observed_status(payload),
         reviewed_head: bounded_string(map_value(payload, "reviewed_head") || map_value(payload, "head")),
         step: bounded_string(map_value(payload, "current") || progress_step(map_value(payload, "progress")))
       }
       |> Map.merge(progress(map_value(payload, "progress")))
       |> reject_nil_values()}
    else
      _no_current_review -> :error
    end
  end

  defp observed_status(payload) do
    case {map_value(payload, "done"), map_value(payload, "status")} do
      {_done, status} when status in ["stale", "fix-pending", "failed", "invalidated", "head_changed_after_review"] -> "failed"
      {_done, "done"} -> "passed"
      {true, _status} -> "passed"
      _active -> "in_progress"
    end
  end

  defp progress_step(value) when is_binary(value) do
    case Regex.run(~r/^review\s+\d+\/\d+\s+(.+)$/, value) do
      [_, step] -> step
      _invalid -> nil
    end
  end

  defp progress_step(_value), do: nil

  defp progress(value) when is_binary(value) do
    case Regex.run(~r/(?:review\s+)?(\d+)\/(\d+)/, value) do
      [_, current, total] ->
        %{current: String.to_integer(current), total: String.to_integer(total)}

      _invalid ->
        %{}
    end
  end

  defp progress(_value), do: %{}

  defp run(executable, args, timeout_ms, max_output_bytes) do
    if String.downcase(Path.extname(executable)) in [".cmd", ".bat"] do
      cmd = System.find_executable("cmd") || raise "cmd.exe unavailable"
      command = cmd_quote(cmd) <> " /d /s /c call " <> Enum.map_join([executable | args], " ", &cmd_quote/1)
      run_shell(command, timeout_ms, max_output_bytes)
    else
      run_port(executable, args, timeout_ms, max_output_bytes)
    end
  rescue
    _error -> :error
  end

  defp cmd_quote(value), do: "\"" <> String.replace(value, "\"", "\"\"") <> "\""

  defp run_port(executable, args, timeout_ms, max_output_bytes) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args
      ])

    collect(port, "", System.monotonic_time(:millisecond) + timeout_ms, max_output_bytes)
  end

  defp run_shell(command, timeout_ms, max_output_bytes) do
    port = Port.open({:spawn, command}, [:binary, :exit_status, :stderr_to_stdout, :hide])
    collect(port, "", System.monotonic_time(:millisecond) + timeout_ms, max_output_bytes)
  end

  defp collect(port, output, deadline_ms, max_output_bytes) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= max_output_bytes ->
        collect(port, output <> data, deadline_ms, max_output_bytes)

      {^port, {:data, _excess}} ->
        Port.close(port)
        :error

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, _failure}} ->
        :error
    after
      remaining_ms ->
        Port.close(port)
        :error
    end
  end

  defp cached(table, key, now_ms, ttl_ms, fun) do
    case cached_value(table, key, now_ms, ttl_ms) do
      {:ok, result} ->
        result

      :error ->
        result = fun.()
        true = :ets.insert(table, {key, now_ms, result})
        result
    end
  end

  defp cached_value(table, key, now_ms, ttl_ms) do
    case :ets.lookup(table, key) do
      [{^key, recorded_ms, result}] when now_ms - recorded_ms < ttl_ms -> {:ok, result}
      _stale -> :error
    end
  end

  defp ensure_table(table) when is_reference(table), do: table

  defp ensure_table(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined ->
        try do
          options = [:named_table, :public, read_concurrency: true, write_concurrency: true]

          options =
            case Process.whereis(SymphonyElixir.Supervisor) do
              pid when is_pid(pid) -> [{:heir, pid, :review_observation} | options]
              _not_started -> options
            end

          :ets.new(table, options)
        rescue
          _race in ArgumentError -> table
        end

      _existing ->
        table
    end
  end

  defp bounded_string(value) when is_binary(value), do: value |> String.trim() |> String.slice(0, 240)
  defp bounded_string(_value), do: nil

  defp map_value(%{} = map, key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    _error in ArgumentError -> nil
  end

  defp map_value(_value, _key), do: nil

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
end
