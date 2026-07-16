defmodule Mix.Tasks.CodeQuality.Guard do
  use Mix.Task

  @moduledoc """
  Enforces ratcheted source-size and function-complexity guardrails.

  New files use the production or test defaults below. Legacy files that already
  exceed a default are listed in `@legacy_ratchets` with the measured current
  threshold; they may shrink freely, but growth above the recorded value fails.
  """
  @shortdoc "Fails when source files grow past code quality ratchets"

  @source_extensions [".cmd", ".ex", ".exs", ".js", ".jsx", ".ps1", ".psm1", ".ts", ".tsx"]
  @default_paths [
    "lib",
    "test",
    "assets/src",
    "assets/__tests__",
    "../plugins/symphony-plus-plus/scripts",
    "../plugins/symphony-plus-plus-mcp/scripts",
    "../scripts/refresh-local-plugin.ps1",
    "../scripts/smoke-sympp-mcp-http.ps1"
  ]
  @function_kinds [:def, :defp, :defmacro, :defmacrop]
  @owner_kinds [:defimpl, :defmodule, :defprotocol]
  @complexity_nodes [:case, :cond, :for, :if, :receive, :try, :unless, :with]
  @complexity_operators [:&&, :and, :or, :||]
  @switches [paths: :keep]

  @production_limits %{max_complexity: 20, max_function_lines: 120, max_lines: 600}
  @test_limits %{max_complexity: 30, max_function_lines: 180, max_lines: 900}
  @mcp_dispatcher_ratchets %{
    "lib/symphony_elixir/symphony_plus_plus/mcp/server.ex" => %{max_lines: 14_006},
    "lib/symphony_elixir/symphony_plus_plus/mcp/tool_catalog.ex" => %{max_lines: 1332}
  }

  @legacy_ratchets %{
    "assets/src/App.tsx" => %{max_lines: 7263},
    "assets/src/types/dashboard.ts" => %{max_lines: 624},
    "../plugins/symphony-plus-plus/scripts/diagnose-mcp-lifecycle.ps1" => %{max_lines: 3508},
    "../plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1" => %{max_lines: 2173},
    "../scripts/smoke-sympp-mcp-http.ps1" => %{max_lines: 1652},
    "lib/mix/tasks/sympp.cockpit.ex" => %{max_lines: 676},
    "lib/mix/tasks/sympp.demo_ledger.ex" => %{
      functions: %{"work_package_evidence/0" => %{max_function_lines: 141}},
      max_lines: 1033
    },
    "lib/symphony_elixir/codex/app_server.ex" => %{
      functions: %{"maybe_handle_approval_request/8" => %{max_function_lines: 151}},
      max_lines: 1096
    },
    "lib/symphony_elixir/config/schema.ex" => %{max_lines: 656},
    "lib/symphony_elixir/orchestrator.ex" => %{
      functions: %{"handle_info/2" => %{max_complexity: 33, max_function_lines: 205}},
      max_lines: 2379
    },
    "lib/symphony_elixir/status_dashboard.ex" => %{
      functions: %{
        "humanize_codex_event/3" => %{max_complexity: 22},
        "humanize_codex_method/2" => %{max_complexity: 74, max_function_lines: 175},
        "humanize_codex_wrapper_event/2" => %{max_complexity: 37}
      },
      max_lines: 1952
    },
    "lib/symphony_elixir/symphony_plus_plus/access_grants/repository.ex" => %{max_lines: 1319},
    "lib/symphony_elixir/symphony_plus_plus/create_work.ex" => %{
      functions: %{"error_message/1" => %{max_complexity: 24}},
      max_lines: 901
    },
    "lib/symphony_elixir/symphony_plus_plus/dashboard.ex" => %{max_lines: 3960},
    "lib/symphony_elixir/symphony_plus_plus/mcp/http_state_store.ex" => %{
      functions: %{"handle_call/3" => %{max_complexity: 33}}
    },
    "lib/symphony_elixir/symphony_plus_plus/mcp/tool_catalog.ex" => %{
      functions: %{
        "architect_tool_description/1" => %{max_complexity: 39},
        "architect_tool_input_schema/1" => %{max_complexity: 40, max_function_lines: 360},
        "worker_tool_input_schema/1" => %{max_function_lines: 179}
      },
      max_lines: 1407
    },
    "lib/symphony_elixir/symphony_plus_plus/mcp/server.ex" => %{
      functions: %{
        "architect_tool/3" => %{max_complexity: 195, max_function_lines: 1053},
        "architect_tool_capability/1" => %{max_complexity: 40},
        "dispatch/3" => %{max_complexity: 100, max_function_lines: 255},
        "handle_state/2" => %{max_complexity: 22},
        "invalid_params_error/2" => %{max_complexity: 21, max_function_lines: 204},
        "worker_tool/3" => %{max_complexity: 69, max_function_lines: 245}
      },
      max_lines: 14_008
    },
    "lib/symphony_elixir/symphony_plus_plus/planning/repository.ex" => %{max_lines: 981},
    "lib/symphony_elixir/symphony_plus_plus/solo_sessions/repository.ex" => %{max_lines: 770},
    "lib/symphony_elixir/symphony_plus_plus/tracker_adapter.ex" => %{max_lines: 1334},
    "lib/symphony_elixir/symphony_plus_plus/work_packages/worktree_lifecycle.ex" => %{max_lines: 738},
    "lib/symphony_elixir/symphony_plus_plus/work_requests/architect_handoff.ex" => %{max_lines: 1161},
    "lib/symphony_elixir/symphony_plus_plus/work_requests/completion.ex" => %{max_lines: 625},
    "lib/symphony_elixir/symphony_plus_plus/work_requests/delivery_board.ex" => %{max_lines: 1079},
    "lib/symphony_elixir/symphony_plus_plus/work_requests/delivery_closeout.ex" => %{max_lines: 793},
    "lib/symphony_elixir/symphony_plus_plus/work_requests/repository.ex" => %{max_lines: 1345},
    "lib/symphony_elixir_web/controllers/sympp_dashboard_api_controller.ex" => %{
      functions: %{"error_response/2" => %{max_complexity: 24}},
      max_lines: 3222
    },
    "lib/symphony_elixir_web/live/dashboard_live.ex" => %{
      functions: %{"render/1" => %{max_function_lines: 210}}
    },
    "lib/symphony_elixir_web/live/sympp_board_live.ex" => %{
      functions: %{
        "render/1" => %{max_function_lines: 318},
        "work_request_action_hint/2" => %{max_complexity: 26}
      },
      max_lines: 1862
    },
    "lib/symphony_elixir_web/live/sympp_detail_live.ex" => %{
      functions: %{"render/1" => %{max_function_lines: 371}},
      max_lines: 1195
    },
    "lib/symphony_elixir_web/live/sympp_work_request_live.ex" => %{
      functions: %{
        "handle_event/3" => %{max_complexity: 55, max_function_lines: 180},
        "render/1" => %{max_function_lines: 859}
      },
      max_lines: 3220
    },
    "test/symphony_elixir/app_server_test.exs" => %{max_lines: 1450},
    "test/symphony_elixir/core_test.exs" => %{max_lines: 1877},
    "test/symphony_elixir/orchestrator_status_test.exs" => %{max_lines: 1674},
    "test/symphony_elixir/symphony_plus_plus/access_grants_test.exs" => %{max_lines: 1443},
    "test/symphony_elixir/symphony_plus_plus/codex_skill_package_test.exs" => %{max_lines: 3901},
    "test/symphony_elixir/symphony_plus_plus/create_work_test.exs" => %{max_lines: 1103},
    "test/symphony_elixir/symphony_plus_plus/dashboard_api_test.exs" => %{max_lines: 7247},
    "test/symphony_elixir/symphony_plus_plus/mcp/claim_session_transport_03_test.exs" => %{max_lines: 1055},
    "test/symphony_elixir/symphony_plus_plus/mcp/claim_session_transport_04_test.exs" => %{max_lines: 1012},
    "test/symphony_elixir/symphony_plus_plus/mcp/solo_schema_01_test.exs" => %{max_lines: 1388},
    "test/symphony_elixir/symphony_plus_plus/mcp/work_request_tools_02_test.exs" => %{max_lines: 1633},
    "test/symphony_elixir/symphony_plus_plus/mcp/worker_tools_06_test.exs" => %{max_lines: 1660},
    "test/symphony_elixir/symphony_plus_plus/mcp_http_endpoint_test.exs" => %{max_lines: 1310},
    "test/symphony_elixir/symphony_plus_plus/mcp_test.exs" => %{max_lines: 19_703},
    "test/symphony_elixir/symphony_plus_plus/mcp_delivery_tools_test.exs" => %{max_lines: 933},
    "test/symphony_elixir/symphony_plus_plus/tracker_adapter_test.exs" => %{max_lines: 2201},
    "test/symphony_elixir/symphony_plus_plus/work_packages_test.exs" => %{max_lines: 944},
    "test/symphony_elixir/symphony_plus_plus/work_request_architect_handoff_test.exs" => %{max_lines: 1812},
    "test/symphony_elixir/symphony_plus_plus/work_request_delivery_closeout_test.exs" => %{max_lines: 1334},
    "test/symphony_elixir/symphony_plus_plus/work_request_work_packages_test.exs" => %{max_lines: 1104},
    "test/symphony_elixir/symphony_plus_plus/work_requests_test.exs" => %{max_lines: 1168},
    "test/symphony_elixir/workspace_and_config_test.exs" => %{max_lines: 1483}
  }

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)
    reject_invalid_args!(argv, invalid)

    requested_paths = Keyword.get_values(opts, :paths)

    files =
      requested_paths
      |> default_paths()
      |> source_files(skip_missing?: requested_paths == [])

    findings =
      files
      |> Enum.flat_map(&check_file/1)
      |> Enum.sort_by(&{&1.path, &1.line, &1.check})

    if findings == [] do
      Mix.shell().info("code_quality.guard: checked #{length(files)} source file(s); no ratchet regressions")
      :ok
    else
      Enum.each(findings, &Mix.shell().error(format_finding(&1)))
      Mix.raise("code_quality.guard failed with #{length(findings)} ratchet violation(s)")
    end
  end

  defp reject_invalid_args!([], []), do: :ok

  defp reject_invalid_args!(_argv, _invalid) do
    Mix.raise("code_quality.guard accepts only repeated --paths PATH options")
  end

  defp default_paths([]), do: @default_paths
  defp default_paths(paths), do: paths

  defp source_files(paths, opts) do
    paths
    |> Enum.flat_map(&expand_path(&1, opts))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp expand_path(path, opts) do
    cond do
      File.regular?(path) -> [path]
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*")) |> Enum.filter(&source_file?/1)
      opts[:skip_missing?] -> []
      true -> Mix.raise("code_quality.guard path does not exist: #{path}")
    end
  end

  defp source_file?(path), do: File.regular?(path) and Path.extname(path) in @source_extensions

  defp check_file(path) do
    relative_path = relative_path(path)
    source = File.read!(path)
    limits = limits_for(relative_path)

    ratchet =
      Map.merge(
        Map.get(@legacy_ratchets, relative_path, %{}),
        Map.get(@mcp_dispatcher_ratchets, relative_path, %{})
      )

    file_limits = Map.merge(limits, Map.take(ratchet, [:max_lines]))

    line_findings = line_findings(relative_path, source, file_limits)
    function_findings = function_findings(relative_path, source, limits, ratchet)

    line_findings ++ function_findings
  end

  defp line_findings(path, source, limits) do
    actual = source_line_count(source)
    limit = limits.max_lines

    if actual > limit do
      [finding(path, 1, file_line_check(path), file_line_subject(path), actual, limit)]
    else
      []
    end
  end

  defp file_line_check(path) do
    if Map.has_key?(@mcp_dispatcher_ratchets, path), do: :mcp_dispatcher_file_lines, else: :file_lines
  end

  defp file_line_subject(path) do
    if Map.has_key?(@mcp_dispatcher_ratchets, path), do: "MCP dispatcher file", else: "file"
  end

  defp function_findings(path, source, limits, ratchet) do
    if elixir_source?(path) do
      path
      |> function_metrics(source)
      |> Enum.flat_map(&function_metric_findings(&1, limits, ratchet))
    else
      []
    end
  end

  defp function_metric_findings(%{parse_error: reason} = metric, _limits, _ratchet) do
    [%{actual: reason, check: :parse_error, line: metric.line, path: metric.path}]
  end

  defp function_metric_findings(metric, limits, ratchet) do
    function_limits =
      ratchet
      |> Map.get(:functions, %{})
      |> Map.get(metric.id, %{})
      |> then(&Map.merge(limits, &1))

    [
      metric_finding(metric, :function_lines, metric.lines, function_limits.max_function_lines),
      metric_finding(metric, :complexity, metric.complexity, function_limits.max_complexity)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp metric_finding(metric, check, actual, limit) do
    if actual > limit do
      finding(metric.path, metric.line, check, "function #{metric.id}", actual, limit)
    end
  end

  defp function_metrics(path, source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, ast} ->
        ast
        |> collect_functions(collect_owners(ast))
        |> aggregate_function_clauses()
        |> Enum.map(fn metric -> Map.put(metric, :path, path) end)

      {:error, {location, message, token}} ->
        [%{path: path, line: parse_error_line(location), id: "parse", lines: 0, complexity: 0, parse_error: "#{inspect(message)} #{inspect(token)}"}]
    end
  end

  defp parse_error_line(location), do: Keyword.get(location, :line, 1)

  defp collect_owners(ast) do
    {_ast, owners} =
      Macro.prewalk(ast, [], fn
        {kind, meta, args} = node, owners when kind in @owner_kinds and is_list(args) ->
          line = Keyword.get(meta, :line, 1)
          end_line = function_end_line(meta, node)

          owner = %{
            end_line: end_line,
            id: {kind, owner_name(args), line, end_line},
            line: line
          }

          {node, [owner | owners]}

        node, owners ->
          {node, owners}
      end)

    Enum.reverse(owners)
  end

  defp collect_functions(ast, owners) do
    {_ast, metrics} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [head, body]} = node, metrics when kind in @function_kinds and is_list(body) ->
          body_ast = Keyword.get(body, :do)
          line = Keyword.get(meta, :line, 1)
          end_line = function_end_line(meta, node)

          metric = %{
            end_line: end_line,
            id: function_id(head),
            line: line,
            lines: end_line - line + 1,
            owner: lexical_owner(owners, line),
            complexity: complexity(body_ast)
          }

          {node, [metric | metrics]}

        node, metrics ->
          {node, metrics}
      end)

    Enum.reverse(metrics)
  end

  defp aggregate_function_clauses(metrics) do
    metrics
    |> Enum.group_by(&{&1.owner, &1.id})
    |> Enum.map(fn {_id, clauses} -> aggregate_function_metric(clauses) end)
    |> Enum.sort_by(& &1.line)
  end

  defp aggregate_function_metric(clauses) do
    clauses = Enum.sort_by(clauses, & &1.line)
    first = hd(clauses)

    %{
      id: first.id,
      line: first.line,
      lines: Enum.reduce(clauses, 0, &(&1.lines + &2)),
      owner: first.owner,
      complexity: Enum.reduce(clauses, 0, &(&1.complexity + &2))
    }
  end

  defp owner_name(args) do
    args
    |> Enum.map(&owner_arg_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp owner_arg_name(arg) when is_list(arg) do
    arg
    |> Keyword.delete(:do)
    |> case do
      [] -> ""
      keyword -> Macro.to_string(keyword)
    end
  end

  defp owner_arg_name(arg), do: Macro.to_string(arg)

  defp lexical_owner(owners, line) do
    owners
    |> Enum.filter(&(line >= &1.line and line <= &1.end_line))
    |> Enum.min_by(&(&1.end_line - &1.line), fn -> :top_level end)
    |> case do
      :top_level -> :top_level
      module -> module.id
    end
  end

  defp function_id({:when, _meta, [head | _guards]}), do: function_id(head)
  defp function_id({name, _meta, args}) when is_atom(name), do: "#{name}/#{arity(args)}"
  defp function_id(_head), do: "unknown/0"

  defp arity(nil), do: 0
  defp arity(args) when is_list(args), do: length(args)

  defp function_end_line(meta, ast) do
    metadata_line(meta, :end) ||
      metadata_line(meta, :end_of_expression) ||
      max_ast_line(ast) ||
      Keyword.get(meta, :line, 1)
  end

  defp metadata_line(meta, key) do
    meta
    |> Keyword.get(key, [])
    |> Keyword.get(:line)
  end

  defp max_ast_line(ast) do
    {_ast, line} =
      Macro.prewalk(ast, nil, fn
        {_, meta, _} = node, max_line when is_list(meta) ->
          {node, max_line(max_line, Keyword.get(meta, :line))}

        node, max_line ->
          {node, max_line}
      end)

    line
  end

  defp max_line(nil, nil), do: nil
  defp max_line(nil, line), do: line
  defp max_line(line, nil), do: line
  defp max_line(first, second), do: max(first, second)

  defp complexity(nil), do: 1

  defp complexity(ast) do
    {_ast, score} =
      Macro.prewalk(ast, 1, fn
        {:->, _meta, _args} = node, score ->
          {node, score + 1}

        {name, _meta, _args} = node, score when name in @complexity_nodes ->
          {node, score + 1}

        {operator, _meta, _args} = node, score when operator in @complexity_operators ->
          {node, score + 1}

        node, score ->
          {node, score}
      end)

    score
  end

  defp limits_for(path) do
    if test_source?(path), do: @test_limits, else: @production_limits
  end

  defp test_source?(path) do
    String.starts_with?(path, "test/") or String.contains?(path, "__tests__/") or String.contains?(path, "_test.") or
      String.contains?(path, ".test.") or String.contains?(path, ".spec.")
  end

  defp elixir_source?(path), do: Path.extname(path) in [".ex", ".exs"]

  defp source_line_count(""), do: 0

  defp source_line_count(source) do
    count = source |> String.split("\n", trim: false) |> length()
    if String.ends_with?(source, "\n"), do: count - 1, else: count
  end

  defp relative_path(path) do
    expanded = normalize_path(path)
    cwd = normalize_path(File.cwd!())
    repo_root = normalize_path(Path.expand("..", cwd))

    cond do
      path_within?(expanded, cwd) ->
        relative_path_from(expanded, cwd)

      path_within?(expanded, repo_root) ->
        "../" <> relative_path_from(expanded, repo_root)

      true ->
        expanded
    end
  end

  defp normalize_path(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> String.replace(~r{/+}, "/")
  end

  defp path_within?(path, root) do
    path_key = path |> String.downcase()
    root_key = root |> String.trim_trailing("/") |> String.downcase()

    path_key == root_key or String.starts_with?(path_key, root_key <> "/")
  end

  defp relative_path_from(path, root) do
    root = String.trim_trailing(root, "/")
    offset = String.length(root) + 1
    String.slice(path, offset..-1//1)
  end

  defp finding(path, line, check, subject, actual, limit) do
    %{actual: actual, check: check, limit: limit, line: line, path: path, subject: subject}
  end

  defp format_finding(%{path: path, line: line, subject: subject, check: :mcp_dispatcher_file_lines, actual: actual, limit: limit}) do
    "#{path}:#{line} #{subject} file_lines #{actual} exceeds MCP dispatcher no-growth ratchet #{limit}; move behavior into focused helper/service modules instead of raising the threshold"
  end

  defp format_finding(%{path: path, line: line, subject: subject, check: check, actual: actual, limit: limit}) do
    "#{path}:#{line} #{subject} #{check} #{actual} exceeds ratchet #{limit}"
  end

  defp format_finding(%{path: path, line: line, check: :parse_error, actual: reason}) do
    "#{path}:#{line} Elixir parse error while measuring quality ratchets: #{reason}"
  end
end
