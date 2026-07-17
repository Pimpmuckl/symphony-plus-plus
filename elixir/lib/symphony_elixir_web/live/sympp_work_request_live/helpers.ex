defmodule SymphonyElixirWeb.SymppWorkRequestLive.Helpers do
  @moduledoc false

  import Phoenix.HTML.Form, only: [input_value: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff

  @work_package_scalar_fields [
    "title",
    "goal",
    "kind",
    "base_branch",
    "branch_pattern",
    "review_json"
  ]
  @work_package_list_fields [
    "allowed_file_globs",
    "forbidden_file_globs",
    "acceptance_criteria",
    "validation_steps",
    "stop_conditions"
  ]
  @work_request_constraint_list_fields [
    "allowed_paths",
    "forbidden_paths",
    "stop_conditions"
  ]
  @work_request_constraint_text_fields [
    "compatibility_stance",
    "validation_expectations",
    "dependencies_notes"
  ]
  @local_operator_actor "local-operator"
  @local_operator_worker "local-operator-worker"

  @spec work_request_form(any()) :: any()
  def work_request_form(attrs \\ %{}) do
    attrs = normalize_keys(attrs)
    constraints_json = Map.get(attrs, "constraints_json", "{}")

    form = %{
      "title" => Map.get(attrs, "title", ""),
      "repo" => Map.get(attrs, "repo", ""),
      "base_branch" => Map.get(attrs, "base_branch", ""),
      "work_type" => Map.get(attrs, "work_type", "feature"),
      "desired_dispatch_shape" => Map.get(attrs, "desired_dispatch_shape", "single_package"),
      "human_description" => Map.get(attrs, "human_description", ""),
      "allowed_paths" => multiline_form_value(Map.get(attrs, "allowed_paths", "")),
      "forbidden_paths" => multiline_form_value(Map.get(attrs, "forbidden_paths", "")),
      "compatibility_stance" => Map.get(attrs, "compatibility_stance", ""),
      "validation_expectations" => Map.get(attrs, "validation_expectations", ""),
      "dependencies_notes" => Map.get(attrs, "dependencies_notes", ""),
      "stop_conditions" => multiline_form_value(Map.get(attrs, "stop_conditions", "")),
      "constraints_json" => constraints_json
    }

    hydrate_structured_constraint_defaults(form)
  end

  defp hydrate_structured_constraint_defaults(%{"constraints_json" => constraints_json} = form) do
    case decode_constraints(constraints_json) do
      {:ok, constraints} ->
        {form, promoted_fields} =
          form
          |> hydrate_list_constraint_defaults(constraints)
          |> hydrate_text_constraint_defaults(constraints)

        if promoted_fields == [] do
          form
        else
          Map.put(form, "constraints_json", Jason.encode!(Map.drop(constraints, promoted_fields), pretty: true))
        end

      {:error, _reason} ->
        form
    end
  end

  defp hydrate_list_constraint_defaults(form, constraints) do
    Enum.reduce(@work_request_constraint_list_fields, {form, []}, fn field, {form, promoted_fields} ->
      hydrate_list_constraint_default(form, promoted_fields, field, Map.get(constraints, field))
    end)
  end

  defp hydrate_list_constraint_default(form, promoted_fields, field, values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      form =
        if values != [] and blank_form_value?(Map.get(form, field)) do
          Map.put(form, field, Enum.join(values, "\n"))
        else
          form
        end

      {form, [field | promoted_fields]}
    else
      {form, promoted_fields}
    end
  end

  defp hydrate_list_constraint_default(form, promoted_fields, _field, _value), do: {form, promoted_fields}

  defp hydrate_text_constraint_defaults({form, promoted_fields}, constraints) do
    Enum.reduce(@work_request_constraint_text_fields, {form, promoted_fields}, fn field, {form, promoted_fields} ->
      case Map.get(constraints, field) do
        value when is_binary(value) ->
          {put_form_value_if_blank(form, field, value), [field | promoted_fields]}

        _other ->
          {form, promoted_fields}
      end
    end)
  end

  defp put_form_value_if_blank(form, field, value) do
    if blank_form_value?(Map.get(form, field)) do
      Map.put(form, field, value)
    else
      form
    end
  end

  defp blank_form_value?(value), do: value |> string_or_empty() |> String.trim() == ""

  @spec work_package_form(any(), any()) :: any()
  def work_package_form(attrs \\ %{}, work_request \\ %{}) do
    attrs = normalize_keys(attrs)

    %{
      "title" => "",
      "goal" => "",
      "kind" => "standard_pr",
      "base_branch" => value(work_request, :base_branch, ""),
      "branch_pattern" => "",
      "review_json" => review_form_value(Map.get(attrs, "review_requirement"))
    }
    |> Map.merge(Map.take(attrs, @work_package_scalar_fields))
    |> Map.merge(work_package_list_form_values(attrs))
  end

  @spec work_package_attrs(any()) :: any()
  def work_package_attrs(form) do
    form = normalize_keys(form)

    scalar_attrs =
      form
      |> Map.take(@work_package_scalar_fields)
      |> trim_string_values()
      |> Map.delete("review_json")
      |> maybe_put_review_requirement(Map.get(form, "review_json"))

    list_attrs =
      Map.new(@work_package_list_fields, fn field ->
        {field, newline_list(Map.get(form, field, ""))}
      end)

    Map.merge(scalar_attrs, list_attrs)
  end

  defp work_package_list_form_values(attrs) do
    Map.new(@work_package_list_fields, fn field ->
      value =
        attrs
        |> Map.get(field, "")
        |> multiline_form_value()

      {field, value}
    end)
  end

  defp review_form_value(nil), do: ""
  defp review_form_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
  defp review_form_value(value) when is_binary(value), do: value
  defp review_form_value(_value), do: ""

  defp maybe_put_review_requirement(attrs, value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        attrs

      json ->
        case Jason.decode(json) do
          {:ok, requirement} -> Map.put(attrs, "review_requirement", requirement)
          {:error, _reason} -> Map.put(attrs, "review_requirement", json)
        end
    end
  end

  defp maybe_put_review_requirement(attrs, _value), do: attrs

  defp multiline_form_value(values) when is_list(values), do: Enum.map_join(values, "\n", &to_string/1)
  defp multiline_form_value(value) when is_binary(value), do: value
  defp multiline_form_value(_value), do: ""

  defp newline_list(value) when is_binary(value) do
    value
    |> String.split(~r/\r\n|\n|\r/, trim: false)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp newline_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp newline_list(_value), do: []

  defp trim_string_values(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(value) -> {key, String.trim(value)}
      pair -> pair
    end)
  end

  @spec constraints_from_form(any()) :: any()
  def constraints_from_form(form) do
    with {:ok, advanced_constraints} <- decode_constraints(form["constraints_json"]) do
      {:ok, Map.merge(advanced_constraints, structured_constraints(form))}
    end
  end

  defp structured_constraints(form) do
    form
    |> structured_list_constraints()
    |> Map.merge(structured_text_constraints(form))
  end

  defp structured_list_constraints(form) do
    @work_request_constraint_list_fields
    |> Enum.map(fn field -> {field, newline_list(Map.get(form, field, ""))} end)
    |> Enum.reject(fn {_field, values} -> values == [] end)
    |> Map.new()
  end

  defp structured_text_constraints(form) do
    @work_request_constraint_text_fields
    |> Enum.map(fn field -> {field, form |> Map.get(field, "") |> string_or_empty() |> String.trim()} end)
    |> Enum.reject(fn {_field, value} -> value == "" end)
    |> Map.new()
  end

  defp string_or_empty(value) when is_binary(value), do: value
  defp string_or_empty(_value), do: ""

  defp decode_constraints(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, %{}}

      json ->
        case Jason.decode(json) do
          {:ok, constraints} when is_map(constraints) -> {:ok, constraints}
          {:ok, _value} -> {:error, :constraints_not_object}
          {:error, _reason} -> {:error, :invalid_constraints_json}
        end
    end
  end

  defp decode_constraints(_value), do: {:error, :invalid_constraints_json}

  @spec filled_form_value(any(), any()) :: any()
  def filled_form_value(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  def filled_form_value(_value, error), do: {:error, error}

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  @spec question_attrs(any(), any()) :: any()
  def question_attrs(params, %AccessGrant{} = grant) do
    params
    |> normalize_keys()
    |> Map.take(["category", "question", "why_needed"])
    |> put_if_filled("asked_by_agent_run_id", default_actor(grant))
  end

  def question_attrs(params, :local_operator) do
    params
    |> normalize_keys()
    |> Map.take(["category", "question", "why_needed"])
    |> put_if_filled("asked_by_agent_run_id", @local_operator_actor)
  end

  @spec answer_attrs(any(), any(), any()) :: any()
  def answer_attrs(params, %AccessGrant{} = grant, _question) do
    attrs =
      params
      |> normalize_keys()
      |> Map.take(["answer", "answered_by"])
      |> put_if_filled("answered_by", default_actor(grant))

    {:ok, attrs}
  end

  def answer_attrs(params, :local_operator, question) do
    params
    |> put_selected_choice_answer_note()
    |> normalize_keys()
    |> local_operator_answer_attrs(value(question, :decision_prompt))
  end

  defp local_operator_answer_attrs(params, decision_prompt) do
    case HumanDecisionPrompt.answer_text_result(decision_prompt, params) do
      {:ok, answer} ->
        case String.trim(answer) do
          "" -> {:error, :missing_answer}
          answer -> {:ok, %{"answer" => answer, "answered_by" => @local_operator_actor}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec decision_attrs(any(), any()) :: any()
  def decision_attrs(params, %AccessGrant{} = grant) do
    params
    |> normalize_keys()
    |> Map.take([
      "source_type",
      "source_id",
      "decision",
      "rationale",
      "scope_impact",
      "created_by"
    ])
    |> put_if_filled("created_by", default_actor(grant))
  end

  def decision_attrs(params, :local_operator) do
    params
    |> normalize_keys()
    |> Map.take([
      "source_type",
      "source_id",
      "decision",
      "rationale",
      "scope_impact"
    ])
    |> Map.put("created_by", @local_operator_actor)
  end

  defp put_if_filled(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] and filled_string?(value) do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  @spec human_answer_choices(any()) :: any()
  def human_answer_choices(record) do
    choices =
      case decision_prompt_options(value(record, :decision_prompt)) do
        [] ->
          [
            %{value: "continue", label: "Continue", help: "Use the suggested path.", checked: true},
            %{value: "narrow", label: "Narrow scope", help: "Keep the work smaller or safer.", checked: false},
            %{
              value: "redirect",
              label: default_custom_redirect_label(),
              help: "Tell the agent what to do differently.",
              checked: false,
              note_required: true
            }
          ]

        options ->
          options
          |> Enum.map(&decision_prompt_choice/1)
          |> maybe_append_custom_redirect_choice(value(record, :decision_prompt))
          |> mark_first_choice_checked()
      end

    with_note_keys(choices)
  end

  @spec human_question_summary(any()) :: any()
  def human_question_summary(question) do
    value(question, :decision_prompt)
    |> prompt_text(:tl_dr)
    |> case do
      summary when is_binary(summary) -> summary
      _summary -> fallback_human_question_summary(question)
    end
  end

  defp fallback_human_question_summary(question) do
    case value(question, :category) do
      category when is_binary(category) and category != "" -> "The agent needs your #{label_value(category)} call."
      _category -> "The agent needs your call before it can continue."
    end
  end

  @spec human_question_text(any()) :: any()
  def human_question_text(question) do
    value(question, :question)
  end

  defp human_question_context(question) do
    value(question, :decision_prompt)
    |> prompt_text(:details)
    |> case do
      details when is_binary(details) -> details
      _details -> value(question, :why_needed)
    end
  end

  @spec human_question_detail_rows(any()) :: any()
  def human_question_detail_rows(question) do
    if structured_prompt?(value(question, :decision_prompt)) do
      [
        {"Context", human_question_context(question)},
        {"Why it matters", exact_value(value(question, :why_needed))},
        {"Freeform redirect", custom_redirect_label(value(question, :decision_prompt))}
      ]
    else
      [
        {"Why it matters", exact_value(value(question, :why_needed))},
        {"Useful answer shape", default_custom_redirect_label()}
      ]
    end
    |> Enum.reject(fn {_label, detail} -> detail in [nil, ""] end)
  end

  defp structured_prompt?(prompt), do: is_map(prompt) and decision_prompt_options(prompt) != []

  defp prompt_text(prompt, key) when is_map(prompt) do
    case value(prompt, key) do
      text when is_binary(text) and text != "" -> text
      _text -> nil
    end
  end

  defp prompt_text(_prompt, _key), do: nil

  @spec decision_prompt_options(any()) :: any()
  def decision_prompt_options(prompt) when is_map(prompt) do
    case value(prompt, :options, []) do
      options when is_list(options) -> Enum.filter(options, &is_map/1)
      _options -> []
    end
  end

  def decision_prompt_options(_prompt), do: []

  defp decision_prompt_choice(option) do
    %{
      value: exact_value(value(option, :id)),
      label: decision_option_label(option),
      help: decision_option_description(option) || "Use this answer.",
      checked: false,
      note_required: false
    }
  end

  defp maybe_append_custom_redirect_choice(choices, prompt) do
    label = custom_redirect_label(prompt)

    if label == "" do
      choices
    else
      choices ++
        [
          %{
            value: HumanDecisionPrompt.custom_redirect_choice_id(),
            label: label,
            help: "Write a different direction below.",
            checked: false,
            note_required: true
          }
        ]
    end
  end

  defp mark_first_choice_checked([]), do: []

  defp mark_first_choice_checked([first | rest]) do
    [Map.put(first, :checked, true) | rest]
  end

  defp with_note_keys(choices) do
    choices
    |> Enum.with_index()
    |> Enum.map(fn {choice, index} -> Map.put(choice, :note_key, "choice_#{index}") end)
  end

  @spec decision_option_label(any()) :: any()
  def decision_option_label(option), do: exact_value(value(option, :label))

  @spec decision_option_description(any()) :: any()
  def decision_option_description(option) do
    case value(option, :description) do
      description when is_binary(description) and description != "" -> description
      _description -> nil
    end
  end

  @spec decision_option_pros(any()) :: any()
  def decision_option_pros(option), do: option_list(option, :pros)
  @spec decision_option_cons(any()) :: any()
  def decision_option_cons(option), do: option_list(option, :cons)

  defp option_list(option, key) do
    case value(option, key, []) do
      values when is_list(values) -> values
      _values -> []
    end
  end

  defp custom_redirect_label(prompt), do: prompt_text(prompt, :custom_redirect_label) || default_custom_redirect_label()
  defp default_custom_redirect_label, do: "No, and tell the agent what to do differently"

  @spec choice_note_placeholder(any()) :: any()
  def choice_note_placeholder(%{note_required: true}), do: "Required: tell the agent what to do differently."
  def choice_note_placeholder(_choice), do: "Optional: add specifics or boundaries for this choice."

  defp put_selected_choice_answer_note(params) when is_map(params) do
    choice = value(params, :answer_choice)
    notes = value(params, :answer_notes)
    note_choices = value(params, :answer_note_choices)

    case selected_choice_note(notes, note_choices, choice) do
      nil -> params
      note -> Map.put(params, "answer_note", note)
    end
  end

  defp selected_choice_note(notes, note_choices, choice)
       when is_map(notes) and is_map(note_choices) and is_binary(choice) do
    note_key =
      Enum.find_value(note_choices, fn
        {key, ^choice} -> key
        _mapping -> nil
      end)

    case note_key && Map.get(notes, note_key) do
      note when is_binary(note) -> note
      _note -> nil
    end
  end

  defp selected_choice_note(_notes, _note_choices, _choice), do: nil

  @spec question_choice_input_id(any(), any()) :: any()
  def question_choice_input_id(question_id, note_key) do
    encoded = question_id |> to_string() |> Base.url_encode64(padding: false)
    "question-choice-#{encoded}-#{note_key}"
  end

  @spec can_clarify?(any()) :: any()
  def can_clarify?(work_request),
    do:
      value(work_request, :status) in [
        "ready_for_clarification",
        "clarifying",
        "human_info_needed"
      ]

  @spec show_architect_work_request_controls?(any(), any()) :: any()
  def show_architect_work_request_controls?(operator_mode?, board_grant) do
    not operator_mode? and can_manage_work_request?(board_grant)
  end

  defp can_manage_work_request?(%AccessGrant{}), do: true
  defp can_manage_work_request?(_grant), do: false

  @spec can_start_agent_questions?(any(), any(), any()) :: any()
  def can_start_agent_questions?(true, nil, work_request), do: value(work_request, :status) == "draft"
  def can_start_agent_questions?(_operator_mode?, _board_grant, _work_request), do: false

  @spec can_mark_human_info_needed?(any()) :: any()
  def can_mark_human_info_needed?(work_request),
    do: value(work_request, :status) in ["ready_for_clarification", "clarifying"]

  @spec can_mark_ready_for_slicing?(any()) :: any()
  def can_mark_ready_for_slicing?(work_request) do
    value(work_request, :status) in ["ready_for_clarification", "clarifying", "human_info_needed"]
  end

  @spec can_author_work_package?(any()) :: any()
  def can_author_work_package?(%{work_request: work_request}), do: can_author_work_package?(work_request)

  def can_author_work_package?(work_request),
    do:
      value(work_request, :status) in [
        "ready_for_clarification",
        "clarifying",
        "human_info_needed",
        "ready_for_slicing",
        "sliced"
      ]

  @spec can_skip_work_package?(any(), any()) :: any()
  def can_skip_work_package?(work_request, work_package),
    do: value(work_request, :status) == "sliced" and value(work_package, :status) == "planned"

  @spec can_dispatch_work_package?(any(), any(), any(), any()) :: any()
  def can_dispatch_work_package?(true, nil, work_request, work_package) do
    value(work_request, :status) == "sliced" and value(work_package, :status) == "planned" and
      is_nil(value(work_package, :dispatched_at))
  end

  def can_dispatch_work_package?(_operator_mode?, _board_grant, _work_request, _work_package), do: false

  @spec can_create_architect_handoff?(any(), any(), any()) :: any()
  def can_create_architect_handoff?(true, nil, work_request) do
    ArchitectHandoff.eligible_status?(value(work_request, :status)) and
      ArchitectHandoff.eligible_scope?(work_request)
  end

  def can_create_architect_handoff?(_operator_mode?, _board_grant, _work_request), do: false

  @spec executable_kinds() :: any()
  def executable_kinds, do: WorkPackage.executable_kinds()

  @spec decision_source_types() :: any()
  def decision_source_types, do: ["human", "architect", "operator", "ask_pro_advisory"]

  @spec default_actor(any()) :: any()
  def default_actor(%AccessGrant{claimed_by: claimed_by}) when is_binary(claimed_by),
    do: claimed_by

  def default_actor(%AccessGrant{id: id}) when is_binary(id), do: id
  def default_actor(_grant), do: "operator"

  @spec default_actor(any(), any()) :: any()
  def default_actor(true, _grant), do: @local_operator_actor
  def default_actor(_operator_mode?, grant), do: default_actor(grant)

  defp filled_string?(value) when is_binary(value), do: String.trim(value) != ""

  @spec dispatch_handoff_opts(any()) :: any()
  def dispatch_handoff_opts(repo) do
    [
      database: dashboard_ledger_database(repo),
      claimed_by: @local_operator_worker
    ]
  end

  @spec architect_handoff_opts(any()) :: any()
  def architect_handoff_opts(repo) do
    [
      database: dashboard_ledger_database(repo),
      claimed_by: ArchitectHandoff.claimed_by(),
      local_architect_claim?: true
    ]
  end

  defp dashboard_ledger_database(repo) do
    Repo.operator_database_path(repo)
  end

  @spec dispatch_notice(any()) :: any()
  def dispatch_notice(dispatch) do
    payload = WorkPackageDispatch.response_payload(dispatch)
    work_package = Map.fetch!(payload, :work_package)
    create_work = Map.fetch!(payload, :dispatch)

    %{
      work_package_id: value(work_package, :id),
      work_package_status: value(work_package, :status),
      handoff_items: bootstrap_items(Map.get(create_work, :worker_bootstrap))
    }
  end

  defp bootstrap_items(%{claim: %{tool: tool, arguments: arguments}}) when is_map(arguments) do
    [
      {"Claim tool", tool},
      {"Claim args", Jason.encode!(arguments)}
    ]
  end

  defp bootstrap_items(%{"claim" => %{"tool" => tool, "arguments" => arguments}}) when is_map(arguments) do
    [
      {"Claim tool", tool},
      {"Claim args", Jason.encode!(arguments)}
    ]
  end

  defp bootstrap_items(_bootstrap), do: []

  @spec architect_handoff_scope(any()) :: any()
  def architect_handoff_scope(%{grant: grant}) when is_map(grant) do
    [value(grant, :scope_repo), value(grant, :scope_base_branch)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" / ")
    |> case do
      "" -> "n/a"
      scope -> scope
    end
  end

  def architect_handoff_scope(_handoff), do: "n/a"

  @spec architect_launch_brief(any(), any()) :: any()
  def architect_launch_brief(%{architect_handoff: handoff}, true)
      when is_map(handoff) do
    case value(handoff, :prompt) do
      prompt when is_binary(prompt) ->
        prompt = String.trim(prompt)
        if prompt != "", do: prompt

      _prompt ->
        nil
    end
  end

  def architect_launch_brief(_page, _operator_mode?), do: nil

  @spec architect_launch_brief_label(any(), any()) :: any()
  def architect_launch_brief_label(%{work_request: work_request} = page, true) do
    if handoff_next_action_status?(value(work_request, :status)) and detail_open_question_count(page) == 0 do
      "Next action: copy architect launch prompt"
    else
      "Stored architect launch prompt"
    end
  end

  def architect_launch_brief_label(_page, _operator_mode?), do: "Stored architect launch prompt"

  @spec safe_architect_prompt(any(), any()) :: any()
  def safe_architect_prompt(%{architect_handoff: handoff}, false)
      when is_map(handoff) do
    case value(handoff, :prompt) do
      prompt when is_binary(prompt) ->
        prompt = String.trim(prompt)
        if prompt != "", do: prompt

      _prompt ->
        nil
    end
  end

  def safe_architect_prompt(_page, _operator_mode?), do: nil

  @spec handoff_status_label(any()) :: any()
  def handoff_status_label(:replayed), do: "replayed"
  def handoff_status_label(:renewed), do: "renewed"
  def handoff_status_label(_status), do: "created"

  @spec detail_title(any()) :: any()
  def detail_title(%{work_request: work_request}) when is_map(work_request) do
    value(work_request, :title) || value(work_request, :id) || "WorkRequest"
  end

  def detail_title(_page), do: "WorkRequest"

  @spec work_request_path(any()) :: any()
  def work_request_path(request), do: "work-requests/#{path_segment(value(request, :id))}"

  @spec work_package_route(any(), any()) :: any()
  def work_package_route(path_prefix, work_package_id) do
    prefixed_path(path_prefix, "/sympp/work-packages/#{path_segment(work_package_id)}")
  end

  @spec work_request_route(any(), any()) :: any()
  def work_request_route(socket, work_request_id) do
    prefixed_path(
      socket.assigns.path_prefix,
      "/sympp/work-requests/#{path_segment(work_request_id)}"
    )
  end

  @spec path_prefix(any(), any(), any()) :: any()
  def path_prefix(uri, :new, _params), do: path_prefix(uri, "/sympp/work-requests/new")
  def path_prefix(uri, :index, _params), do: path_prefix(uri, "/sympp/work-requests")

  def path_prefix(uri, :show, %{"work_request_id" => id}),
    do: path_prefix(uri, "/sympp/work-requests/#{path_segment(id)}")

  def path_prefix(_uri, _action, _params), do: ""

  @spec path_prefix(any(), any()) :: any()
  def path_prefix(uri, route_path) do
    path = uri |> URI.parse() |> Map.get(:path) |> Kernel.||("")

    if String.ends_with?(path, route_path) do
      path
      |> String.slice(0, byte_size(path) - byte_size(route_path))
      |> normalize_path_prefix()
    else
      ""
    end
  end

  defp normalize_path_prefix(""), do: ""
  defp normalize_path_prefix("/"), do: ""
  defp normalize_path_prefix(prefix), do: String.trim_trailing(prefix, "/")

  @spec prefixed_path(any(), any()) :: any()
  def prefixed_path("", path), do: path
  def prefixed_path(prefix, path), do: prefix <> path

  @spec path_segment(any()) :: any()
  def path_segment("."), do: "%2E"
  def path_segment(".."), do: "%2E%2E"
  def path_segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  @spec repo_base(any()) :: any()
  def repo_base(item) do
    [value(item, :repo), value(item, :base_branch)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" / ")
    |> case do
      "" -> "n/a"
      label -> label
    end
  end

  @spec total_questions(any()) :: any()
  def total_questions(requests) do
    Enum.reduce(requests, 0, fn request, count ->
      count + value(request, :open_question_count, 0) +
        value(request, :answered_question_count, 0) +
        value(request, :closed_question_count, 0)
    end)
  end

  @spec total_decisions(any()) :: any()
  def total_decisions(requests),
    do: Enum.reduce(requests, 0, &(&2 + value(&1, :decision_count, 0)))

  @spec total_work_packages(any()) :: any()
  def total_work_packages(requests), do: Enum.reduce(requests, 0, &(&2 + work_package_total(&1)))

  @spec work_package_total(any()) :: any()
  def work_package_total(item), do: value(item, :work_package_count, 0)

  @spec summary_work_package_total(any()) :: any()
  def summary_work_package_total(summary), do: work_package_total(summary)

  @spec detail_status_panel_class(any()) :: any()
  def detail_status_panel_class(page) do
    classes = ["sympp-detail-status-panel"]

    classes =
      if detail_guidance_attention?(page) do
        ["sympp-detail-status-attention" | classes]
      else
        classes
      end

    Enum.reverse(classes)
  end

  @spec detail_next_action(any(), any()) :: any()
  def detail_next_action(%{work_request: work_request} = page, operator_mode?) do
    detail_next_action_for_handoff(page, operator_mode?) ||
      detail_next_action_for(
        value(work_request, :status),
        operator_mode?,
        detail_open_question_count(page),
        value(page.summary, :work_package_count, 0),
        value(page.summary, :planned_work_package_count, 0),
        value(page.summary, :dispatched_work_package_count, 0)
      )
  end

  def detail_next_action(_page, _operator_mode?), do: "Review WorkRequest state"

  @spec detail_state_summary(any(), any()) :: any()
  def detail_state_summary(%{work_request: work_request} = page, operator_mode?) do
    detail_state_summary_for_handoff(page, operator_mode?) ||
      detail_state_summary_for(
        value(work_request, :status),
        operator_mode?,
        detail_open_question_count(page),
        value(page.summary, :work_package_count, 0),
        value(page.summary, :planned_work_package_count, 0),
        value(page.summary, :dispatched_work_package_count, 0)
      )
  end

  def detail_state_summary(_page, _operator_mode?), do: "Check the current status, questions, and WorkPackages."

  defp detail_next_action_for_handoff(%{architect_handoff: handoff, work_request: work_request} = page, true)
       when is_map(handoff) do
    if handoff_next_action_status?(value(work_request, :status)) and detail_open_question_count(page) == 0 do
      "Copy architect launch prompt"
    else
      nil
    end
  end

  defp detail_next_action_for_handoff(_page, _operator_mode?), do: nil

  defp detail_next_action_for("draft", _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "Start agent questions"

  defp detail_next_action_for(
         "ready_for_clarification",
         _operator_mode?,
         open_questions,
         _planned,
         _approved,
         _dispatched
       )
       when open_questions > 0,
       do: "Answer open questions"

  defp detail_next_action_for(
         "ready_for_clarification",
         true,
         _open_questions,
         _planned,
         _approved,
         _dispatched
       ),
       do: "Prepare architect handoff"

  defp detail_next_action_for(
         "ready_for_clarification",
         false,
         _open_questions,
         _planned,
         _approved,
         _dispatched
       ),
       do: "Ask clarification questions"

  defp detail_next_action_for("clarifying", _operator_mode?, open_questions, _planned, _approved, _dispatched)
       when open_questions > 0,
       do: "Answer open questions"

  defp detail_next_action_for("clarifying", _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "Mark ready for slicing"

  defp detail_next_action_for("human_info_needed", _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "Human guidance needed"

  defp detail_next_action_for("ready_for_slicing", true, _open_questions, _total, planned, _dispatched)
       when planned > 0,
       do: "Finish slicing"

  defp detail_next_action_for("ready_for_slicing", false, _open_questions, _total, planned, _dispatched)
       when planned > 0,
       do: "Finish slicing"

  defp detail_next_action_for("ready_for_slicing", _operator_mode?, _open_questions, planned, _approved, _dispatched)
       when planned > 0,
       do: "Finish slicing"

  defp detail_next_action_for("ready_for_slicing", _operator_mode?, _open_questions, _planned, _approved, dispatched)
       when dispatched > 0,
       do: "Dispatched WorkPackages active"

  defp detail_next_action_for("ready_for_slicing", _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "Author WorkPackages"

  defp detail_next_action_for("sliced", true, _open_questions, _total, planned, _dispatched)
       when planned > 0,
       do: "Dispatch planned WorkPackages"

  defp detail_next_action_for("sliced", false, _open_questions, _total, planned, _dispatched)
       when planned > 0,
       do: "Local dispatch pending"

  defp detail_next_action_for("sliced", _operator_mode?, _open_questions, _planned, _approved, dispatched)
       when dispatched > 0,
       do: "Dispatched WorkPackages active"

  defp detail_next_action_for("sliced", _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "No dispatchable WorkPackages"

  defp detail_next_action_for(_status, _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "Review WorkRequest state"

  defp detail_state_summary_for_handoff(%{architect_handoff: handoff, work_request: work_request} = page, true)
       when is_map(handoff) do
    if handoff_next_action_status?(value(work_request, :status)) and detail_open_question_count(page) == 0 do
      "Architect handoff is prepared; copy the launch prompt and paste it into the architect agent."
    else
      nil
    end
  end

  defp detail_state_summary_for_handoff(_page, _operator_mode?), do: nil

  defp detail_state_summary_for("draft", true, _open_questions, _planned, _approved, _dispatched),
    do: "Start agent questions to move this draft into the agent-question phase."

  defp detail_state_summary_for("draft", _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "The next step is to start agent questions so clarification can begin."

  defp detail_state_summary_for(
         "ready_for_clarification",
         _operator_mode?,
         open_questions,
         _planned,
         _approved,
         _dispatched
       )
       when open_questions > 0,
       do: "Agent questions are open and need answers before slicing."

  defp detail_state_summary_for(
         "ready_for_clarification",
         true,
         _open_questions,
         _planned,
         _approved,
         _dispatched
       ),
       do: "Agent questions are ready; prepare the paste-ready architect handoff."

  defp detail_state_summary_for(
         "ready_for_clarification",
         false,
         _open_questions,
         _planned,
         _approved,
         _dispatched
       ),
       do: "Agent questions are ready; the architect can ask questions or record decisions before slicing."

  defp detail_state_summary_for("clarifying", _operator_mode?, open_questions, _planned, _approved, _dispatched)
       when open_questions > 0,
       do: "Open questions are blocking the slicing path."

  defp detail_state_summary_for("clarifying", _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "Clarification has no open questions and can move to slicing."

  defp detail_state_summary_for(
         "human_info_needed",
         _operator_mode?,
         _open_questions,
         _planned,
         _approved,
         _dispatched
       ),
       do: "Answer the human guidance question before slicing continues."

  defp detail_state_summary_for("ready_for_slicing", true, _open_questions, _planned, approved, _dispatched)
       when approved > 0,
       do: "Planned WorkPackages are ready for local-operator dispatch."

  defp detail_state_summary_for("ready_for_slicing", false, _open_questions, _planned, approved, _dispatched)
       when approved > 0,
       do: "Planned WorkPackages are waiting for local-operator dispatch."

  defp detail_state_summary_for("ready_for_slicing", _operator_mode?, _open_questions, planned, _approved, _dispatched)
       when planned > 0,
       do: "WorkPackages are present and slicing must finish before dispatch."

  defp detail_state_summary_for("ready_for_slicing", _operator_mode?, _open_questions, _planned, _approved, dispatched)
       when dispatched > 0,
       do: "At least one WorkPackage has been dispatched."

  defp detail_state_summary_for("ready_for_slicing", _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "Slicing is ready but no WorkPackage has been authored."

  defp detail_state_summary_for("sliced", true, _open_questions, _planned, approved, _dispatched)
       when approved > 0,
       do: "Slicing is complete; planned WorkPackages can be dispatched by the local operator."

  defp detail_state_summary_for("sliced", false, _open_questions, _planned, approved, _dispatched)
       when approved > 0,
       do: "Slicing is complete; planned WorkPackages are waiting for local-operator dispatch."

  defp detail_state_summary_for("sliced", _operator_mode?, _open_questions, _planned, _approved, dispatched)
       when dispatched > 0,
       do: "At least one WorkPackage has been dispatched."

  defp detail_state_summary_for("sliced", _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "Slicing is complete with no planned WorkPackages currently dispatchable."

  defp detail_state_summary_for(_status, _operator_mode?, _open_questions, _planned, _approved, _dispatched),
    do: "Check the current status, questions, and WorkPackages."

  defp handoff_next_action_status?("ready_for_clarification"), do: true
  defp handoff_next_action_status?(_status), do: false

  @spec detail_guidance_class(any()) :: any()
  def detail_guidance_class(page) do
    if detail_guidance_attention?(page), do: "sympp-detail-status-hot", else: ""
  end

  @spec detail_guidance_heading(any(), any()) :: any()
  def detail_guidance_heading(%{work_request: work_request}, true) do
    if value(work_request, :status) == "human_info_needed", do: "Questions for you", else: "Questions"
  end

  def detail_guidance_heading(_page, _operator_mode?), do: "Questions"

  defp detail_guidance_attention?(%{work_request: work_request} = page) do
    value(work_request, :status) in ["clarifying", "human_info_needed"] and
      detail_open_question_count(page) > 0
  end

  defp detail_guidance_attention?(_page), do: false

  @spec detail_guidance_label(any()) :: any()
  def detail_guidance_label(%{work_request: work_request} = page) do
    open_count = detail_open_question_count(page)

    cond do
      value(work_request, :status) == "human_info_needed" and open_count > 0 ->
        "#{open_count} open, human needed"

      value(work_request, :status) == "human_info_needed" ->
        "human needed"

      open_count > 0 ->
        "#{open_count} open"

      value(page.summary, :answered_question_count, 0) > 0 ->
        "answered"

      true ->
        "none open"
    end
  end

  def detail_guidance_label(_page), do: "n/a"

  @spec detail_slicing_label(any()) :: any()
  def detail_slicing_label(%{work_request: work_request, summary: summary}) do
    cond do
      value(summary, :planned_work_package_count, 0) > 0 ->
        "#{value(summary, :planned_work_package_count, 0)} planned"

      value(summary, :dispatched_work_package_count, 0) > 0 ->
        "#{value(summary, :dispatched_work_package_count, 0)} dispatched"

      value(work_request, :status) in ["ready_for_slicing", "sliced"] and value(summary, :work_package_count, 0) == 0 ->
        "ready, no WorkPackages"

      value(summary, :work_package_count, 0) > 0 ->
        "#{value(summary, :work_package_count, 0)} planned"

      true ->
        "not ready"
    end
  end

  def detail_slicing_label(_page), do: "n/a"

  @spec detail_handoff_label(any(), any()) :: any()
  def detail_handoff_label(%{architect_handoff: handoff, work_request: work_request} = page, true)
      when is_map(handoff) do
    if handoff_next_action_status?(value(work_request, :status)) and detail_open_question_count(page) == 0 do
      "copy prompt"
    else
      "prepared"
    end
  end

  def detail_handoff_label(%{architect_handoff: handoff}, _operator_mode?) when is_map(handoff),
    do: "prepared"

  def detail_handoff_label(%{work_request: work_request}, true) do
    if can_create_architect_handoff?(true, nil, work_request), do: "available", else: "not eligible"
  end

  def detail_handoff_label(_page, _operator_mode?), do: "local only"

  defp detail_open_question_count(%{summary: summary}), do: value(summary, :open_question_count, 0)
  defp detail_open_question_count(_page), do: 0

  @spec sequence_label(any()) :: any()
  def sequence_label(item), do: "##{value(item, :sequence, "?")}"

  @spec status_label(any()) :: any()
  def status_label(value) when is_binary(value), do: String.replace(value, "_", " ")
  def status_label(value), do: label_value(value)

  @spec operational_badge_key(any()) :: any()
  def operational_badge_key(item), do: operational_state_key(item) || value(item, :status)

  @spec operational_badge_label(any()) :: any()
  def operational_badge_label(item), do: operational_state_label(item) || status_label(value(item, :status))

  defp operational_state_key(item) do
    case value(item, :operational_state) do
      %{key: key} when is_binary(key) -> key
      %{"key" => key} when is_binary(key) -> key
      _state -> nil
    end
  end

  defp operational_state_label(item) do
    case value(item, :operational_state) do
      %{label: label} when is_binary(label) -> label
      %{"label" => label} when is_binary(label) -> label
      _state -> nil
    end
  end

  @spec work_type_label(any()) :: any()
  def work_type_label("bugfix"), do: "Bug fix"
  def work_type_label("docs"), do: "Docs"
  def work_type_label("hotfix"), do: "Hotfix"
  def work_type_label("investigation"), do: "Investigation"
  def work_type_label("refactor"), do: "Refactor"
  def work_type_label("review"), do: "Review"
  def work_type_label(value), do: label_value(value)

  @spec work_type_help(any()) :: any()
  def work_type_help("feature"), do: "Build or change user-visible behavior."
  def work_type_help("bugfix"), do: "Fix something that is not working correctly."
  def work_type_help("hotfix"), do: "Urgent, narrow fix for a production-style issue."
  def work_type_help("refactor"), do: "Improve structure without changing behavior."
  def work_type_help("investigation"), do: "Research, reproduce, and report before changing code."
  def work_type_help("docs"), do: "Update docs, prompts, or operator guidance."
  def work_type_help("review"), do: "Review existing work and return findings."
  def work_type_help(_value), do: "Tell agents what kind of work this is."

  @spec dispatch_shape_label(any()) :: any()
  def dispatch_shape_label("single_package"), do: "One focused package"
  def dispatch_shape_label("architect_led_feature_branch"), do: "Feature branch with slices"
  def dispatch_shape_label("direct_main_fix"), do: "Direct fix on the target branch"
  def dispatch_shape_label("investigation_first"), do: "Investigate before implementation"
  def dispatch_shape_label(value), do: label_value(value)

  @spec advanced_intake_open?(any(), any()) :: any()
  def advanced_intake_open?(form, form_error) do
    constraints_form_error?(form_error) or
      Enum.any?(
        [
          :allowed_paths,
          :forbidden_paths,
          :compatibility_stance,
          :validation_expectations,
          :stop_conditions,
          :dependencies_notes,
          :constraints_json
        ],
        fn field -> advanced_value_present?(field, input_value(form, field)) end
      )
  end

  defp constraints_form_error?("Constraints must be valid JSON."), do: true
  defp constraints_form_error?("Constraints JSON must be an object."), do: true
  defp constraints_form_error?(_form_error), do: false

  defp advanced_value_present?(:constraints_json, value) when is_binary(value) do
    String.trim(value) not in ["", "{}"]
  end

  defp advanced_value_present?(_field, value) when is_binary(value), do: String.trim(value) != ""
  defp advanced_value_present?(_field, _value), do: false

  @spec status_class(any()) :: any()
  def status_class("open"), do: "state-badge state-badge-warning"
  def status_class("human_info_needed"), do: "state-badge state-badge-warning"
  def status_class("needs_attention"), do: "state-badge state-badge-warning"
  def status_class("started_paused"), do: "state-badge state-badge-warning"
  def status_class("ready_for_clarification"), do: "state-badge state-badge-warning"
  def status_class("clarifying"), do: "state-badge state-badge-warning"
  def status_class("ready_for_slicing"), do: "state-badge state-badge-active"
  def status_class("active"), do: "state-badge state-badge-active"
  def status_class("reviewing"), do: "state-badge state-badge-active"
  def status_class("ci_waiting"), do: "state-badge state-badge-active"
  def status_class("merge_ready"), do: "state-badge state-badge-active"
  def status_class("merged"), do: "state-badge state-badge-active"
  def status_class("answered"), do: "state-badge state-badge-active"
  def status_class("approved"), do: "state-badge state-badge-active"
  def status_class("dispatched"), do: "state-badge state-badge-active"
  def status_class("sliced"), do: "state-badge state-badge-active"
  def status_class("closed"), do: "state-badge"
  def status_class(_status), do: "state-badge"

  @spec timestamp_label(any()) :: any()
  def timestamp_label(nil), do: "n/a"
  def timestamp_label(value), do: to_string(value)

  @spec label_value(any()) :: any()
  def label_value(nil), do: "n/a"
  def label_value(""), do: "n/a"
  def label_value(value) when is_binary(value), do: String.replace(value, "_", " ")
  def label_value(value), do: to_string(value)

  @spec exact_value(any()) :: any()
  def exact_value(nil), do: "n/a"
  def exact_value(""), do: "n/a"
  def exact_value(value), do: to_string(value)

  @spec list_label(any()) :: any()
  def list_label([]), do: "n/a"
  def list_label(values) when is_list(values), do: Enum.map_join(values, ", ", &to_string/1)
  def list_label(value), do: label_value(value)

  @spec json_block(any()) :: any()
  def json_block(value), do: Jason.encode!(value, pretty: true)

  def value(map, key, default \\ nil)

  @spec value(any(), any(), any()) :: any()
  def value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def value(_map, _key, default), do: default
end
