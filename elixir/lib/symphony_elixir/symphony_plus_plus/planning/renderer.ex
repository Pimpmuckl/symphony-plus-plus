defmodule SymphonyElixir.SymphonyPlusPlus.Planning.Renderer do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @virtual_files [
    "context.md",
    "task_plan.md",
    "findings.md",
    "progress.md",
    "acceptance.md",
    "review_suite.md",
    "handoff.md"
  ]

  @external_text_limit 4_000
  @render_file_limit 120_000
  @render_item_limit 100

  @type error :: Repository.error() | :unknown_virtual_file

  @spec virtual_files() :: [String.t()]
  def virtual_files, do: @virtual_files

  @spec render(Repository.repo(), String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def render(repo, work_package_id, file_name)
      when is_atom(repo) and is_binary(work_package_id) and is_binary(file_name) do
    with {:ok, state} <- Repository.get_render_state(repo, work_package_id) do
      render_state(state, file_name)
    end
  end

  @spec render_all(Repository.repo(), String.t(), keyword()) :: {:ok, %{String.t() => String.t()}} | {:error, error()}
  def render_all(repo, work_package_id, opts \\ []) when is_atom(repo) and is_binary(work_package_id) do
    with {:ok, state} <- Repository.get_render_state(repo, work_package_id) do
      state = maybe_put_required_review_profiles(state, opts)

      rendered =
        Map.new(@virtual_files, fn file_name ->
          {:ok, markdown} = render_state(state, file_name)
          {file_name, markdown}
        end)

      {:ok, rendered}
    end
  end

  @spec render_state(State.t(), String.t()) :: {:ok, String.t()} | {:error, :unknown_virtual_file}
  def render_state(%State{} = state, "context.md"), do: {:ok, context_markdown(state)}
  def render_state(%State{} = state, "task_plan.md"), do: {:ok, task_plan_markdown(state)}
  def render_state(%State{} = state, "findings.md"), do: {:ok, findings_markdown(state)}
  def render_state(%State{} = state, "progress.md"), do: {:ok, progress_markdown(state)}
  def render_state(%State{} = state, "acceptance.md"), do: {:ok, acceptance_markdown(state)}
  def render_state(%State{} = state, "review_suite.md"), do: {:ok, review_suite_markdown(state)}
  def render_state(%State{} = state, "handoff.md"), do: {:ok, handoff_markdown(state)}
  def render_state(%State{}, _file_name), do: {:error, :unknown_virtual_file}

  defp context_markdown(%State{work_package: work_package}) do
    [
      "# #{source_inline(work_package.title)}",
      "",
      metadata_rows(work_package),
      "## Product Description",
      "",
      source_block(work_package.product_description),
      "",
      "## Engineering Scope",
      "",
      source_block(work_package.engineering_scope),
      "",
      "## Allowed File Globs",
      "",
      source_block(allowed_file_globs_text(work_package))
    ]
    |> flatten_join()
  end

  defp task_plan_markdown(%State{work_package: work_package, plan_nodes: []}) do
    [
      "# Task Plan",
      "",
      "Work package: `#{work_package.id}` - #{source_inline(work_package.title)}",
      "",
      "No plan nodes recorded."
    ]
    |> flatten_join()
  end

  defp task_plan_markdown(%State{work_package: work_package, plan_nodes: plan_nodes} = state) do
    {rendered_nodes, omitted_count} = capped_head_items(plan_nodes, state.plan_nodes_omitted_count)

    [
      "# Task Plan",
      "",
      "Work package: `#{work_package.id}` - #{source_inline(work_package.title)}",
      "",
      omission_notice(omitted_count, "later plan nodes"),
      Enum.map(rendered_nodes, &plan_node_line/1)
    ]
    |> flatten_join()
  end

  defp findings_markdown(%State{findings: []}) do
    flatten_join(["# Findings", "", "No findings recorded."])
  end

  defp findings_markdown(%State{findings: findings} = state) do
    {rendered_findings, omitted_count} = capped_tail_items(findings, state.findings_omitted_count)

    ["# Findings", "", omission_notice(omitted_count, "older findings"), Enum.map(rendered_findings, &finding_block/1)]
    |> flatten_join(:tail)
  end

  defp progress_markdown(%State{progress_events: []}) do
    flatten_join(["# Progress", "", "No progress events recorded."])
  end

  defp progress_markdown(%State{progress_events: progress_events} = state) do
    {rendered_progress, omitted_count} = capped_tail_items(progress_events, state.progress_events_omitted_count)

    ["# Progress", "", omission_notice(omitted_count, "older progress events"), Enum.map(rendered_progress, &progress_block/1)]
    |> flatten_join(:tail)
  end

  defp acceptance_markdown(%State{work_package: %WorkPackage{acceptance_criteria: []}}) do
    flatten_join(["# Acceptance", "", "No acceptance criteria recorded."])
  end

  defp acceptance_markdown(%State{work_package: work_package}) do
    [
      "# Acceptance",
      "",
      "Work package: `#{work_package.id}` - #{source_inline(work_package.title)}",
      "",
      acceptance_lines(work_package)
    ]
    |> flatten_join()
  end

  defp review_suite_markdown(%State{work_package: work_package} = state) do
    case Templates.expand(policy_key(work_package)) do
      {:ok, template} ->
        template = effective_review_policy(state, template)

        [
          "# Review Suite",
          "",
          "Policy template: `#{template.template}`",
          "",
          "## Required Gates",
          "",
          list_or_empty(template.required_gates),
          "## Readiness Requirements",
          "",
          list_or_empty(template.readiness_requirements),
          "## Review Profiles",
          "",
          "- Required: #{inline_list(review_suite_required_profiles(state, template))}",
          "- Optional: #{inline_list(template.review_suite.optional)}"
        ]
        |> flatten_join()

      {:error, :unknown_policy_template} ->
        [
          "# Review Suite",
          "",
          "No policy template is registered for kind `#{work_package.kind}`."
        ]
        |> flatten_join()
    end
  end

  defp effective_review_policy(%State{review_suite_required_profiles: profiles}, template) when is_list(profiles) do
    ReviewProfiles.apply_required_profiles(template, profiles)
  end

  defp effective_review_policy(%State{}, template), do: template

  defp review_suite_required_profiles(%State{review_suite_required_profiles: profiles}, _template) when is_list(profiles),
    do: Redactor.redact_output(profiles)

  defp review_suite_required_profiles(%State{}, template), do: template.review_suite.required

  defp maybe_put_required_review_profiles(%State{} = state, opts) do
    case Keyword.fetch(opts, :review_suite_required_profiles) do
      {:ok, profiles} ->
        %State{state | review_suite_required_profiles: ReviewProfiles.normalize_review_suite_profiles(profiles)}

      :error ->
        state
    end
  end

  defp handoff_markdown(%State{} = state) do
    [
      "# Handoff",
      "",
      "## Work Package",
      "",
      "- ID: `#{state.work_package.id}`",
      "- Title: #{source_inline(state.work_package.title)}",
      "- Status: `#{state.work_package.status}`",
      "",
      "## Acceptance",
      "",
      acceptance_lines(state.work_package),
      "## Latest Progress",
      "",
      latest_progress_lines(state.progress_events),
      "## Findings",
      "",
      finding_summary_lines(state),
      "## Artifacts",
      "",
      artifact_lines(state)
    ]
    |> flatten_join(:tail)
  end

  defp metadata_rows(%WorkPackage{} = work_package) do
    [
      "- ID: `#{work_package.id}`",
      "- Kind: `#{work_package.kind}`",
      "- Policy template: #{source_inline(policy_key(work_package))}",
      "- Status: `#{work_package.status}`",
      "- Repo: #{source_inline(work_package.repo)}",
      "- Base branch: #{source_inline(work_package.base_branch)}",
      "- Branch pattern: #{source_inline(work_package.branch_pattern)}",
      "- Allowed file globs: #{source_inline(allowed_file_globs_text(work_package))}",
      "- Parent: #{source_inline(work_package.parent_id)}",
      "- Owner: #{source_inline(work_package.owner_id)}"
    ]
  end

  defp plan_node_line(%PlanNode{} = plan_node) do
    checkbox =
      case plan_node.status do
        "done" -> "[x]"
        _status -> "[ ]"
      end

    suffix =
      case plan_node.status do
        "skipped" -> " _(skipped)_"
        "pending" -> " _(pending)_"
        _status -> ""
      end

    details =
      if blank?(plan_node.body) do
        []
      else
        plan_node.body
        |> source_lines()
        |> Enum.map(fn
          "" -> "  "
          line -> "  " <> line
        end)
      end

    ["- #{checkbox} #{source_inline(plan_node.title)}#{suffix}", details]
  end

  defp finding_block(%Finding{} = finding) do
    [
      "## #{timestamp(finding.created_at)} - #{source_inline(finding.title)}",
      "",
      "- Severity: `#{finding.severity}`",
      "",
      source_block(finding.body)
    ]
  end

  defp progress_block(%ProgressEvent{} = progress_event) do
    [
      "## #{timestamp(progress_event.created_at)} - #{source_inline(progress_event.summary)}",
      "",
      "- Status: `#{progress_event.status}`",
      actor_line(progress_event),
      "",
      source_block(progress_event.body)
    ]
  end

  defp actor_line(%ProgressEvent{actor_id: actor_id, actor_type: actor_type}) do
    if blank?(actor_id) do
      []
    else
      "- Actor: #{source_inline(actor_id)} (#{source_inline(actor_type || "unknown")})"
    end
  end

  defp acceptance_lines(%WorkPackage{acceptance_criteria: []}), do: ["No acceptance criteria recorded."]

  defp acceptance_lines(%WorkPackage{} = work_package) do
    {rendered_criteria, omitted_count} = capped_head_items(work_package.acceptance_criteria, nil)

    [
      omission_notice(omitted_count, "later acceptance criteria"),
      Enum.map(rendered_criteria, &("- [ ] " <> source_inline(&1)))
    ]
  end

  defp latest_progress_lines([]), do: ["No progress events recorded."]

  defp latest_progress_lines(progress_events) do
    progress_events
    |> Enum.take(-3)
    |> Enum.map(fn progress_event -> "- #{timestamp(progress_event.created_at)}: #{source_inline(progress_event.summary)}" end)
  end

  defp allowed_file_globs_text(%WorkPackage{allowed_file_globs: []}), do: nil
  defp allowed_file_globs_text(%WorkPackage{} = work_package), do: Enum.join(work_package.allowed_file_globs, "\n")

  defp policy_key(%WorkPackage{policy_template: policy_template}) when is_binary(policy_template) and policy_template != "" do
    policy_template
  end

  defp policy_key(%WorkPackage{kind: kind}), do: kind

  defp finding_summary_lines(%State{findings: []}), do: ["No findings recorded."]

  defp finding_summary_lines(%State{findings: findings} = state) do
    {rendered_findings, omitted_count} = capped_tail_items(findings, state.findings_omitted_count)

    [
      omission_notice(omitted_count, "older findings"),
      Enum.map(rendered_findings, fn finding ->
        "- #{timestamp(finding.created_at)}: #{source_inline(finding.title)} (`#{finding.severity}`)"
      end)
    ]
  end

  defp artifact_lines(%State{artifacts: []}), do: ["No artifacts recorded."]

  defp artifact_lines(%State{artifacts: artifacts} = state) do
    {rendered_artifacts, omitted_count} = capped_tail_items(artifacts, state.artifacts_omitted_count)

    [
      omission_notice(omitted_count, "older artifacts"),
      Enum.map(rendered_artifacts, fn %Artifact{} = artifact ->
        uri = if blank?(artifact.uri), do: "", else: " - #{source_inline(artifact.uri)}"
        "- #{source_inline(artifact.path)} - #{source_inline(artifact.title)} (`#{artifact.kind}`)#{uri}"
      end)
    ]
  end

  defp list_or_empty(values), do: Enum.map(values, &("- " <> &1))

  defp inline_list([]), do: "none"
  defp inline_list(values), do: Enum.join(values, ", ")

  defp capped_head_items(items, omitted_count) do
    item_count = length(items)
    omitted_count = omitted_count || 0

    if item_count > @render_item_limit do
      {Enum.take(items, @render_item_limit), omitted_count + item_count - @render_item_limit}
    else
      {items, omitted_count}
    end
  end

  defp capped_tail_items(items, omitted_count) do
    item_count = length(items)
    omitted_count = omitted_count || 0

    if item_count > @render_item_limit do
      {Enum.take(items, -@render_item_limit), omitted_count + item_count - @render_item_limit}
    else
      {items, omitted_count}
    end
  end

  defp omission_notice(0, _label), do: []
  defp omission_notice(count, label), do: ["_#{count} #{label} omitted from this virtual file._", ""]

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp timestamp(_datetime), do: "unknown time"

  defp source_block(value), do: source_lines(value)

  defp source_inline(value) do
    "source: " <>
      (value
       |> text_or_empty()
       |> bound_external_text()
       |> one_line()
       |> code_span())
  end

  defp source_lines(value) do
    [
      "Source material (inert text):",
      "",
      value
      |> text_or_empty()
      |> bound_external_text()
      |> fenced_text()
    ]
    |> List.flatten()
  end

  defp bound_external_text(value) do
    if String.length(value) <= @external_text_limit do
      value
    else
      String.slice(value, 0, @external_text_limit) <> "\n[truncated]"
    end
  end

  defp one_line(value) do
    value
    |> String.replace("\n", " ")
    |> String.replace("\r", " ")
  end

  defp code_span(value) do
    delimiter = backtick_delimiter(value)

    if String.starts_with?(value, "`") or String.ends_with?(value, "`") do
      delimiter <> " " <> value <> " " <> delimiter
    else
      delimiter <> value <> delimiter
    end
  end

  defp fenced_text(value) do
    fence = backtick_delimiter(value, 3)
    [fence <> "text"] ++ String.split(value, "\n", trim: false) ++ [fence]
  end

  defp backtick_delimiter(value, minimum_length \\ 1) do
    longest_run =
      ~r/`+/
      |> Regex.scan(value)
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 0 end)

    String.duplicate("`", max(longest_run + 1, minimum_length))
  end

  defp text_or_empty(value) when is_binary(value) do
    if blank?(value), do: "Not recorded.", else: Redactor.redact_text(value)
  end

  defp text_or_empty(_value), do: "Not recorded."

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp flatten_join(parts, truncation_strategy \\ :head) do
    parts
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
    |> bound_rendered_file(truncation_strategy)
  end

  defp bound_rendered_file(markdown, truncation_strategy) do
    if String.length(markdown) <= @render_file_limit do
      markdown
    else
      markdown
      |> truncate_rendered_file(truncation_strategy)
      |> close_truncated_markdown()
      |> add_truncation_notice(truncation_strategy)
    end
  end

  defp truncate_rendered_file(markdown, :tail) do
    markdown
    |> String.slice(-@render_file_limit, @render_file_limit)
    |> truncate_from_section_boundary()
  end

  defp truncate_rendered_file(markdown, _strategy), do: String.slice(markdown, 0, @render_file_limit)

  defp add_truncation_notice(markdown, :tail), do: "[virtual file truncated]\n\n" <> markdown
  defp add_truncation_notice(markdown, _strategy), do: markdown <> "\n\n[virtual file truncated]\n"

  defp close_truncated_markdown(markdown) do
    markdown
    |> truncate_to_line_boundary()
    |> close_open_fence()
  end

  defp truncate_to_line_boundary(markdown) do
    case :binary.matches(markdown, "\n") do
      [] -> markdown
      matches -> binary_part(markdown, 0, elem(List.last(matches), 0))
    end
  end

  defp truncate_from_section_boundary(markdown) do
    case Regex.run(~r/\n## /, markdown, return: :index) do
      [{index, _length}] -> binary_part(markdown, index + 1, byte_size(markdown) - index - 1)
      nil -> truncate_from_line_boundary(markdown)
    end
  end

  defp truncate_from_line_boundary(markdown) do
    case :binary.match(markdown, "\n") do
      :nomatch -> markdown
      {index, 1} -> binary_part(markdown, index + 1, byte_size(markdown) - index - 1)
    end
  end

  defp close_open_fence(markdown) do
    case open_fence(markdown) do
      nil -> markdown
      {indent, fence} -> markdown <> "\n" <> indent <> fence
    end
  end

  defp open_fence(markdown) do
    markdown
    |> String.split("\n", trim: false)
    |> Enum.reduce(nil, fn line, open ->
      case Regex.run(~r/^(\s*)(`{3,})(?:text)?\s*$/, line) do
        [_, indent, fence] when is_nil(open) -> {indent, fence}
        [_, _indent, fence] -> close_matching_fence(open, fence)
        nil -> open
      end
    end)
  end

  defp close_matching_fence({_indent, open_fence} = open, fence) do
    if String.length(fence) >= String.length(open_fence), do: nil, else: open
  end
end
