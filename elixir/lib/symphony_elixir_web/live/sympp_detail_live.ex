defmodule SymphonyElixirWeb.SymppDetailLive do
  @moduledoc """
  Read-only Symphony++ work package detail view.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Service, as: GuidanceRequestService
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt
  alias SymphonyElixirWeb.SymppBoardLive
  alias SymphonyElixirWeb.SymppDashboardApiController

  @known_keys ~w(
    access_grant_id active_agent_run_count active_blocker_count active_grant_count
    active alert_indicators agent_run_count agent_runs artifact_count artifacts base_branch
    answer answered_at answered_by blocker_id body branch branch_pattern capabilities claimed_at claimed_by codex_total_tokens
    claimed_by_required completed_count context created_at detail display_key engineering_scope
    events expires_at failed_count finding_count findings finished_at grant_count
    grant_id grant_role grants guidance_request_count guidance_requests human_info_reason mode
    head_sha id inserted_at kind label latest last_seen_at latest_progress_at metadata
    missing open_count path placeholder plan position pr product_description progress_event_count
    question queued_agent_run_count reason recommended_language repo requested_by revoked_at runtime runtime_state
    scope severity sequence session_id stale stale_after_seconds stale_agent_run_count
    stale_heartbeat_after_seconds status stopped_agent_run_count summary terminal_count
    suggested_claimed_by target timeline_order title total_count turn_count type updated_at
    uri url work_package worker_host worker_task_handle workspace_path
  )
  @known_key_atoms Map.new(@known_keys, &{&1, String.to_atom(&1)})

  @impl true
  def mount(params, session, socket) do
    work_package_id = params |> Map.get("work_package_id") |> SymppDashboardApiController.normalize_package_route_id()
    package_grant_id = session |> Map.get("sympp_package_grant_ids") |> package_session_grant_id(work_package_id)
    board_grant_id = Map.get(session, "sympp_board_grant_id")

    operator_mode? = local_operator_mode?(session, socket)

    {:ok,
     socket
     |> assign(:work_package_id, work_package_id)
     |> assign(:package_grant_id, package_grant_id)
     |> assign(:board_grant_id, board_grant_id)
     |> assign(:operator_mode?, operator_mode?)
     |> assign(:grant, nil)
     |> assign(:phase_reader?, false)
     |> assign(:detail, empty_detail(error: nil))
     |> assign(:timeline, %{events: []})
     |> assign(:action_error, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(%{"work_package_id" => work_package_id}, _uri, socket) do
    work_package_id = SymppDashboardApiController.normalize_package_route_id(work_package_id)

    case authorize_session(socket, work_package_id) do
      :local_operator ->
        {:noreply,
         socket
         |> assign(:work_package_id, work_package_id)
         |> assign(:grant, nil)
         |> assign(:phase_reader?, true)
         |> assign_detail()}

      {:ok, %AccessGrant{} = grant} ->
        {:noreply,
         socket
         |> assign(:work_package_id, work_package_id)
         |> assign(:grant, grant)
         |> assign(:phase_reader?, phase_reader?(grant))
         |> assign_detail()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:work_package_id, work_package_id)
         |> assign(:grant, nil)
         |> assign(:phase_reader?, false)
         |> assign(:detail, empty_detail(error: error_message(reason)))
         |> assign(:timeline, %{events: []})
         |> assign(:error, error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    assigns = Map.put_new(assigns, :operator_mode?, false)
    assigns = Map.put_new(assigns, :action_error, nil)

    ~H"""
    <section class="sympp-detail-shell">
      <header class="sympp-detail-header">
        <div>
          <p class="eyebrow">Symphony++</p>
          <h1 class="sympp-detail-title"><%= package_title(@detail.work_package) %></h1>
        </div>

        <div class="sympp-detail-header-actions">
          <a :if={@operator_mode?} class="sympp-back-link" href="?auth=work_key">Use work key</a>
          <a :if={@phase_reader?} class="sympp-back-link" href="../board">Board</a>
        </div>
      </header>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">Package unavailable</h2>
          <p class="error-copy"><%= @error %></p>
        </section>
      <% else %>
        <section class="sympp-detail-overview">
          <div class="sympp-detail-main">
            <div class="sympp-copy-row">
              <label for="sympp-package-id">Package ID</label>
              <input id="sympp-package-id" class="mono" readonly value={@detail.work_package.id || @work_package_id} />
            </div>

            <div class="sympp-detail-signal-row">
              <span class="state-badge"><%= status_label(@detail.work_package.status) %></span>
              <span class={detail_plan_signal_class(@detail.summary.plan)}>
                Plan <%= plan_progress(@detail.summary.plan) %>
              </span>
              <span class={if @detail.summary.active_blocker_count > 0, do: "state-badge state-badge-danger", else: "state-badge state-badge-active"}>
                <%= @detail.summary.active_blocker_count %> blockers
              </span>
              <span class={if review_evidence_present?(@detail.metadata), do: "state-badge state-badge-active", else: "state-badge"}>
                Review <%= if review_evidence_present?(@detail.metadata), do: "recorded", else: "pending" %>
              </span>
            </div>
            <p :if={@action_error} class="sympp-form-error"><%= @action_error %></p>

            <dl class="sympp-detail-meta">
              <div>
                <dt>Kind</dt>
                <dd><%= present(@detail.work_package.kind) %></dd>
              </div>
              <div>
                <dt>Repo</dt>
                <dd><%= repo_base(@detail.work_package) %></dd>
              </div>
              <div>
                <dt>Base branch</dt>
                <dd><%= @detail.work_package |> Map.get(:base_branch) |> present() %></dd>
              </div>
              <div>
                <dt>Updated</dt>
                <dd class="numeric"><%= present(@detail.summary.latest_progress_at || @detail.work_package.updated_at) %></dd>
              </div>
            </dl>
          </div>

          <aside class="sympp-detail-side">
            <a :if={pr_url(@detail.metadata)} class="sympp-pr-link" href={pr_url(@detail.metadata)} target="_blank" rel="noopener noreferrer">
              Open PR
            </a>
            <p :if={!pr_url(@detail.metadata)} class="sympp-empty-inline">No PR attached.</p>
            <p class="mono sympp-branch"><%= branch_label(@detail.metadata) %></p>
            <p :if={pr_state_label(@detail.metadata)} class="mono sympp-branch"><%= pr_state_label(@detail.metadata) %></p>
            <p :if={review_completion_label(@detail.metadata)} class="mono sympp-branch"><%= review_completion_label(@detail.metadata) %></p>
            <dl :if={pr_summary_items(@detail.metadata) != []} class="sympp-pr-state-list">
              <div :for={{label, value} <- pr_summary_items(@detail.metadata)}>
                <dt><%= label %></dt>
                <dd><%= value %></dd>
              </div>
            </dl>
          </aside>
        </section>

        <section class="sympp-detail-grid">
          <article class="sympp-panel sympp-panel-wide">
            <h2>Scope</h2>
            <dl class="sympp-detail-list">
              <div>
                <dt>Product</dt>
                <dd><%= present(@detail.work_package.product_description) %></dd>
              </div>
              <div>
                <dt>Engineering</dt>
                <dd><%= present(@detail.work_package.engineering_scope) %></dd>
              </div>
              <div>
                <dt>Files</dt>
                <dd><%= list_text(@detail.work_package.allowed_file_globs) %></dd>
              </div>
            </dl>
          </article>

          <article class="sympp-panel">
            <h2>Acceptance</h2>
            <ul :if={@detail.work_package.acceptance_criteria != []} class="sympp-plain-list">
              <li :for={criterion <- @detail.work_package.acceptance_criteria}><%= criterion %></li>
            </ul>
            <p :if={@detail.work_package.acceptance_criteria == []} class="sympp-empty-inline">No acceptance criteria recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2>Summary</h2>
            <dl class="sympp-count-grid">
              <div><dt>Plan</dt><dd class="numeric"><%= plan_progress(@detail.summary.plan) %></dd></div>
              <div><dt>Findings</dt><dd class="numeric"><%= @detail.summary.finding_count %></dd></div>
              <div><dt>Events</dt><dd class="numeric"><%= @detail.summary.progress_event_count %></dd></div>
              <div><dt>Artifacts</dt><dd class="numeric"><%= @detail.summary.artifact_count %></dd></div>
              <div><dt>Active blockers</dt><dd class="numeric"><%= @detail.summary.active_blocker_count %></dd></div>
              <div><dt>Active runs</dt><dd class="numeric"><%= @detail.summary.active_agent_run_count %></dd></div>
              <div><dt>Queued runs</dt><dd class="numeric"><%= @detail.summary.queued_agent_run_count %></dd></div>
              <div><dt>Stale runs</dt><dd class="numeric"><%= @detail.summary.stale_agent_run_count %></dd></div>
            </dl>
          </article>

          <article class="sympp-panel">
            <h2>Runtime Alerts</h2>
            <div class="sympp-stack-list">
              <div :for={alert <- @detail.alert_indicators} class="sympp-mini-row">
                <span class={alert_badge_class(alert)}><%= alert.label %></span>
                <span><%= alert_state(alert) %></span>
                <span class="muted"><%= alert.detail %></span>
              </div>
            </div>
          </article>

          <article id="guidance-requests" class="sympp-panel sympp-panel-wide">
            <h2><%= if @operator_mode?, do: "Questions for you", else: "Guidance Requests" %></h2>
            <div :if={guidance_requests(@detail) != []} class="sympp-stack-list">
              <div :for={guidance <- guidance_requests(@detail)} id={guidance_request_dom_id(guidance.id)} class="sympp-stack-item">
                <div class="sympp-work-request-row-heading">
                  <span class={guidance_status_class(guidance.status)}><%= status_label(guidance.status) %></span>
                  <span class="sympp-card-id"><%= guidance.id %></span>
                </div>
                <%= if @operator_mode? and guidance.status == "human_info_needed" do %>
                  <section class="sympp-human-decision-card">
                    <header class="sympp-human-decision-header">
                      <p class="sympp-human-kicker">Human answer needed</p>
                      <div>
                        <span class="sympp-human-section-label">TL;DR</span>
                        <h3><%= human_guidance_summary(guidance) %></h3>
                      </div>
                    </header>
                    <section class="sympp-human-section sympp-human-question-section">
                      <span class="sympp-human-section-label">Question</span>
                      <p class="sympp-human-question"><%= human_guidance_question(guidance) %></p>
                    </section>
                    <dl class="sympp-human-decision-details">
                      <div :for={{label, detail} <- human_guidance_detail_rows(guidance)}>
                        <dt><%= label %></dt>
                        <dd><%= detail %></dd>
                      </div>
                    </dl>
                    <div :if={decision_prompt_options(map_value(guidance, :decision_prompt)) != []} class="sympp-decision-option-list">
                      <article :for={option <- decision_prompt_options(map_value(guidance, :decision_prompt))} class="sympp-decision-option-card">
                        <h4><%= decision_option_label(option) %></h4>
                        <p :if={decision_option_description(option)}><%= decision_option_description(option) %></p>
                        <div class="sympp-decision-option-rationale">
                          <section :if={decision_option_pros(option) != []}>
                            <h5>Pros</h5>
                            <ul>
                              <li :for={pro <- decision_option_pros(option)}><%= pro %></li>
                            </ul>
                          </section>
                          <section :if={decision_option_cons(option) != []}>
                            <h5>Cons</h5>
                            <ul>
                              <li :for={con <- decision_option_cons(option)}><%= con %></li>
                            </ul>
                          </section>
                        </div>
                      </article>
                    </div>
                  </section>
                <% else %>
                  <h3><%= present(guidance.summary) %></h3>
                <% end %>
                <dl class="sympp-detail-list">
                  <div>
                    <dt>Requested by</dt>
                    <dd><%= present(guidance.requested_by) %></dd>
                  </div>
                  <div>
                    <dt>Blocker</dt>
                    <dd class="mono"><%= present(guidance.blocker_id) %></dd>
                  </div>
                  <div>
                    <dt>Answered by</dt>
                    <dd><%= present(guidance.answered_by) %></dd>
                  </div>
                </dl>
                <p :if={!(@operator_mode? and guidance.status == "human_info_needed")}><strong>Question:</strong> <%= present(guidance.question) %></p>
                <p :if={!(@operator_mode? and guidance.status == "human_info_needed")}><strong>Context:</strong> <%= present(guidance.context) %></p>
                <p :if={!(@operator_mode? and guidance.status == "human_info_needed") and guidance.human_info_reason}>
                  <strong>Escalation:</strong> <%= guidance.human_info_reason %>
                </p>
                <p :if={!(@operator_mode? and guidance.status == "human_info_needed") and guidance.recommended_language}>
                  <strong>Recommended language:</strong> <%= guidance.recommended_language %>
                </p>
                <p :if={guidance.answer}><strong>Answer:</strong> <%= guidance.answer %></p>
                <.form
                  :if={can_answer_guidance?(@operator_mode?, guidance)}
                  :let={f}
                  for={%{}}
                  as={:guidance_request}
                  phx-submit="answer_guidance_request"
                  class="sympp-human-answer-form sympp-guidance-answer-form"
                >
                  <input type="hidden" name={f[:id].name} value={guidance.id} />
                  <input type="hidden" name={f[:work_package_id].name} value={@detail.work_package.id || @work_package_id} />
                  <div class="sympp-choice-list" role="radiogroup" aria-label="Answer direction">
                    <div :for={choice <- human_answer_choices(guidance)} class="sympp-choice-option">
                      <% choice_input_id = guidance_choice_input_id(guidance.id, choice.note_key) %>
                      <label>
                        <input id={choice_input_id} type="radio" name={f[:answer_choice].name} value={choice.value} checked={choice.checked} />
                        <span>
                          <strong><%= choice.label %></strong>
                          <small><%= choice.help %></small>
                        </span>
                      </label>
                      <input type="hidden" name={"#{f[:answer_note_choices].name}[#{choice.note_key}]"} value={choice.value} />
                      <textarea
                        name={"#{f[:answer_notes].name}[#{choice.note_key}]"}
                        rows="2"
                        placeholder={choice_note_placeholder(choice)}
                        aria-label={"Note for #{choice.label}"}
                        data-choice-input={choice_input_id}
                        onfocus="document.getElementById(this.dataset.choiceInput)?.click()"
                        onclick="document.getElementById(this.dataset.choiceInput)?.click()"
                        oninput="document.getElementById(this.dataset.choiceInput)?.click()"
                      ></textarea>
                    </div>
                  </div>
                  <div class="sympp-form-actions">
                    <button type="submit">Send answer</button>
                  </div>
                </.form>
              </div>
            </div>
            <p :if={guidance_requests(@detail) == []} class="sympp-empty-inline">No guidance requests recorded.</p>
          </article>

          <article class="sympp-panel sympp-panel-wide">
            <h2>Virtual Task Plan</h2>
            <div :if={@detail.plan != []} class="sympp-plan-list">
              <div :for={node <- @detail.plan} class="sympp-plan-row">
                <span class={plan_status_class(node.status)}><%= status_label(node.status) %></span>
                <div>
                  <h3><%= node.title %></h3>
                  <p><%= present(node.body) %></p>
                </div>
              </div>
            </div>
            <p :if={@detail.plan == []} class="sympp-empty-inline">No virtual plan nodes recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2>Findings</h2>
            <div :if={@detail.findings != []} class="sympp-stack-list">
              <div :for={finding <- @detail.findings} class="sympp-stack-item">
                <span class="state-badge"><%= finding.severity || "unknown" %></span>
                <h3><%= finding.title %></h3>
                <p><%= present(finding.body) %></p>
              </div>
            </div>
            <p :if={@detail.findings == []} class="sympp-empty-inline">No findings recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2>Artifacts</h2>
            <div :if={@detail.artifacts != []} class="sympp-stack-list">
              <div :for={artifact <- @detail.artifacts} class="sympp-stack-item">
                <span class="state-badge"><%= artifact.kind || "artifact" %></span>
                <h3><%= artifact.title %></h3>
                <p class="mono"><%= artifact.path %></p>
                <a :if={public_http_url(artifact.uri)} href={artifact.uri} target="_blank" rel="noopener noreferrer">Open artifact</a>
              </div>
            </div>
            <p :if={@detail.artifacts == []} class="sympp-empty-inline">No artifacts recorded.</p>
          </article>

          <article class="sympp-panel sympp-panel-wide">
            <h2>Timeline</h2>
            <ol :if={@timeline.events != []} class="sympp-timeline">
              <li :for={event <- @timeline.events}>
                <time class="numeric"><%= present(event.created_at) %></time>
                <div>
                  <span class="state-badge"><%= event.type %></span>
                  <h3><%= timeline_title(event) %></h3>
                  <p><%= timeline_body(event) %></p>
                </div>
              </li>
            </ol>
            <p :if={@timeline.events == []} class="sympp-empty-inline">No progress or finding timeline events recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2>Grants</h2>
            <dl class="sympp-count-grid">
              <div><dt>Total</dt><dd class="numeric"><%= @detail.summary.grant_count %></dd></div>
              <div><dt>Active</dt><dd class="numeric"><%= @detail.summary.active_grant_count %></dd></div>
            </dl>
            <div :if={@detail.grants != []} class="sympp-stack-list">
              <div :for={grant <- @detail.grants} class="sympp-mini-row">
                <span class="state-badge"><%= grant.status %></span>
                <span><%= grant.grant_role %></span>
                <span class="mono"><%= grant.display_key %></span>
              </div>
            </div>
          </article>

          <article class="sympp-panel">
            <h2>Agent Runs</h2>
            <dl class="sympp-count-grid">
              <div><dt>Total</dt><dd class="numeric"><%= @detail.summary.agent_run_count %></dd></div>
              <div><dt>Active</dt><dd class="numeric"><%= @detail.summary.active_agent_run_count %></dd></div>
              <div><dt>Queued</dt><dd class="numeric"><%= @detail.summary.queued_agent_run_count %></dd></div>
              <div><dt>Stopped</dt><dd class="numeric"><%= @detail.summary.stopped_agent_run_count %></dd></div>
            </dl>
            <div :if={@detail.agent_runs != []} class="sympp-stack-list">
              <div :for={run <- @detail.agent_runs} class="sympp-stack-item">
                <span class={run_badge_class(run)}><%= run_status_label(run) %></span>
                <h3><%= present(run.worker_task_handle) %></h3>
                <p class="mono"><%= run.session_id || run.id %></p>
                <p class="mono"><%= present(run.workspace_path) %></p>
                <p class="muted"><%= token_summary(run) %> / last seen <%= present(run.last_seen_at) %></p>
                <p :if={run.status == "failed"} class="muted"><%= present(run.reason) %></p>
              </div>
            </div>
            <p :if={@detail.agent_runs == []} class="sympp-empty-inline">No agent runs recorded.</p>
          </article>
        </section>
      <% end %>
    </section>
    """
  end

  @impl true
  def handle_event("answer_guidance_request", %{"guidance_request" => params}, socket) do
    if socket.assigns.operator_mode? do
      answer_guidance_request(socket, params)
    else
      {:noreply, assign(socket, :action_error, guidance_answer_error_message(:forbidden))}
    end
  end

  defp answer_guidance_request(socket, params) when is_map(params) do
    with {:ok, guidance_request_id} <- required_param(params, "id"),
         answer_params <-
           params
           |> put_selected_choice_answer_note()
           |> Map.put("work_package_id", socket.assigns.work_package_id),
         {:ok, _result} <-
           SymppBoardLive.with_dashboard_repo(fn repo ->
             GuidanceRequestService.answer_human_info_needed_for_local_operator(
               repo,
               local_operator_answer_context(socket),
               guidance_request_id,
               answer_params
             )
           end) do
      {:noreply,
       socket
       |> put_flash(:info, "Guidance answer recorded.")
       |> assign_detail()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign_detail()
         |> assign(:action_error, guidance_answer_error_message(reason))}
    end
  end

  defp authorize_session(socket, work_package_id) do
    if socket.assigns.operator_mode? do
      :local_operator
    else
      package_result =
        SymppDashboardApiController.authorize_package_grant_id(socket.assigns.package_grant_id, work_package_id)

      board_result =
        SymppDashboardApiController.authorize_package_grant_id(socket.assigns.board_grant_id, work_package_id)

      case {package_result, board_result} do
        {_package_result, {:ok, %AccessGrant{}} = authorized} -> authorized
        {{:ok, %AccessGrant{}} = authorized, _board_result} -> authorized
        {{:error, _package_reason}, {:error, :not_found}} -> {:error, :not_found}
        {{:error, :unauthorized}, {:error, reason}} -> {:error, reason}
        {{:error, reason}, _board_result} -> {:error, reason}
      end
    end
  end

  defp package_session_grant_id(sessions, work_package_id) when is_map(sessions) and is_binary(work_package_id) do
    Map.get(sessions, work_package_id)
  end

  defp package_session_grant_id(_sessions, _work_package_id), do: nil

  defp phase_reader?(%AccessGrant{capabilities: capabilities}) do
    is_list(capabilities) and "read:phase" in capabilities
  end

  defp local_operator_answer_context(%{assigns: %{operator_mode?: true}}), do: :local_operator
  defp local_operator_answer_context(_socket), do: nil

  defp local_operator_mode?(session, socket) do
    SymppDashboardApiController.local_operator_session?(session) and
      if connected?(socket) do
        SymppDashboardApiController.local_operator_live_connect_info?(%{
          peer_data: get_connect_info(socket, :peer_data),
          uri: get_connect_info(socket, :uri),
          x_headers: get_connect_info(socket, :x_headers)
        })
      else
        SymppDashboardApiController.local_operator_enabled?()
      end
  end

  defp assign_detail(socket) do
    work_package_id = socket.assigns.work_package_id
    grant = socket.assigns.grant

    case SymppBoardLive.with_dashboard_repo(fn repo -> load_detail(repo, work_package_id, grant) end) do
      {:ok, %{detail: detail, timeline: timeline}} ->
        socket
        |> assign(:detail, detail_view(detail))
        |> assign(:timeline, timeline_view(timeline))
        |> assign(:action_error, nil)
        |> assign(:error, nil)

      {:error, reason} ->
        socket
        |> assign(:detail, empty_detail(error: error_message(reason)))
        |> assign(:timeline, %{events: []})
        |> assign(:error, error_message(reason))
    end
  end

  defp load_detail(repo, work_package_id, %AccessGrant{} = grant) do
    with {:ok, detail} <- Dashboard.detail(repo, work_package_id),
         {:ok, timeline} <- Dashboard.timeline(repo, work_package_id) do
      {:ok,
       %{
         detail: SymppDashboardApiController.scope_package_payload_for_grant(grant, detail),
         timeline: SymppDashboardApiController.scope_package_payload_for_grant(grant, timeline)
       }}
    end
  end

  defp load_detail(repo, work_package_id, nil) do
    with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo),
         {:ok, detail} <- Dashboard.detail(repo, work_package_id, repo_identity_catalog: repo_identity_catalog),
         {:ok, timeline} <- Dashboard.timeline(repo, work_package_id) do
      {:ok, %{detail: detail, timeline: timeline}}
    end
  end

  defp detail_view(payload) do
    payload
    |> atomize_payload()
    |> Map.put_new(:work_package, %{})
    |> Map.put_new(:summary, %{})
    |> Map.put_new(:metadata, %{})
    |> Map.put_new(:plan, [])
    |> Map.put_new(:findings, [])
    |> Map.put_new(:artifacts, [])
    |> Map.put_new(:guidance_requests, [])
    |> Map.put_new(:grants, [])
    |> Map.put_new(:agent_runs, [])
    |> Map.put_new(:alert_indicators, [])
    |> then(fn detail ->
      detail
      |> Map.update!(:work_package, &atomize_payload/1)
      |> Map.update!(:summary, &summary_view/1)
      |> Map.update!(:metadata, &atomize_payload/1)
      |> Map.update!(:plan, &atomize_list/1)
      |> Map.update!(:findings, &atomize_list/1)
      |> Map.update!(:artifacts, &atomize_list/1)
      |> Map.update!(:guidance_requests, &atomize_list/1)
      |> Map.update!(:grants, &atomize_list/1)
      |> Map.update!(:agent_runs, &atomize_list/1)
      |> Map.update!(:alert_indicators, &atomize_list/1)
    end)
  end

  defp summary_view(summary) do
    summary
    |> atomize_payload()
    |> Map.put_new(:artifact_count, 0)
    |> Map.put_new(:finding_count, 0)
    |> Map.put_new(:progress_event_count, 0)
    |> Map.put_new(:active_blocker_count, 0)
    |> Map.put_new(:guidance_request_count, 0)
    |> Map.put_new(:grant_count, 0)
    |> Map.put_new(:active_grant_count, 0)
    |> Map.put_new(:agent_run_count, 0)
    |> Map.put_new(:active_agent_run_count, 0)
    |> Map.put_new(:queued_agent_run_count, 0)
    |> Map.put_new(:stopped_agent_run_count, 0)
    |> Map.put_new(:failed_agent_run_count, 0)
    |> Map.put_new(:stale_agent_run_count, 0)
    |> Map.put_new(:latest_progress_at, nil)
    |> Map.update(:runtime, %{}, &atomize_payload/1)
    |> Map.update(:plan, %{total_count: 0, completed_count: 0, open_count: 0}, &atomize_payload/1)
  end

  defp timeline_view(payload) do
    events =
      payload
      |> atomize_payload()
      |> Map.get(:events, [])
      |> atomize_list()

    %{events: events}
  end

  defp empty_detail(_opts) do
    detail_view(%{
      work_package: %{},
      summary: %{},
      metadata: %{},
      plan: [],
      findings: [],
      artifacts: [],
      guidance_requests: [],
      grants: [],
      agent_runs: [],
      alert_indicators: []
    })
  end

  defp atomize_list(values) when is_list(values), do: Enum.map(values, &atomize_payload/1)
  defp atomize_list(_values), do: []

  defp atomize_payload(%{} = payload) do
    Map.new(payload, fn {key, value} -> {atom_key(key), atomize_value(value)} end)
  end

  defp atomize_payload(_payload), do: %{}

  defp atomize_value(%{} = value), do: atomize_payload(value)
  defp atomize_value(values) when is_list(values), do: Enum.map(values, &atomize_value/1)
  defp atomize_value(value), do: value

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: Map.get(@known_key_atoms, key, key)

  defp package_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp package_title(_work_package), do: "Work package detail"

  defp repo_base(work_package) do
    [Map.get(work_package, :repo), Map.get(work_package, :base_branch)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" / ")
    |> present()
  end

  defp list_text(values) when is_list(values) and values != [], do: Enum.join(values, ", ")
  defp list_text(_values), do: "n/a"

  defp plan_progress(%{total_count: total, completed_count: completed}) when is_integer(total) and total > 0 do
    "#{completed}/#{total}"
  end

  defp plan_progress(_plan), do: "n/a"

  defp detail_plan_signal_class(%{total_count: total, open_count: 0}) when is_integer(total) and total > 0 do
    "state-badge state-badge-active"
  end

  defp detail_plan_signal_class(_plan), do: "state-badge"

  defp plan_status_class(status) when status in ["done", "completed", "skipped"], do: "state-badge state-badge-active"
  defp plan_status_class(_status), do: "state-badge"

  defp branch_label(metadata) do
    branch_metadata = map_value(metadata, :branch)
    branch = map_value(branch_metadata, :branch)
    head_sha = map_value(branch_metadata, :head_sha)

    branch_label(branch, head_sha)
  end

  defp branch_label(branch, head_sha) when is_binary(branch) do
    [branch, short_sha(head_sha)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" @ ")
  end

  defp branch_label(_branch, _head_sha), do: "No branch attached"

  defp pr_url(metadata), do: metadata |> map_value(:pr) |> map_value(:url) |> public_http_url()

  defp pr_state_label(metadata) do
    pr = map_value(metadata, :pr)
    stale? = map_value(pr, :stale)
    head_sha = map_value(pr, :head_sha)
    current_head_sha = map_value(pr, :current_head_sha)

    cond do
      stale? == true -> "PR stale @ #{display_sha(head_sha) || "unknown"}; branch @ #{display_sha(current_head_sha) || "unknown"}"
      is_binary(head_sha) -> "PR head @ #{display_sha(head_sha) || head_sha}"
      true -> nil
    end
  end

  defp review_completion_label(metadata) do
    completion = map_value(metadata, :review_completion)
    review = map_value(completion, :review)
    type = map_value(review, :type)
    head_sha = map_value(completion, :head_sha)

    if is_binary(type), do: "#{type} review complete @ #{display_sha(head_sha) || "unknown"}"
  end

  defp review_evidence_present?(metadata) do
    not is_nil(review_completion_label(metadata))
  end

  defp pr_summary_items(metadata) do
    pr = map_value(metadata, :pr)

    [
      {"Checks", pr_summary_value(pr, "check_summary", ["conclusion", "state", "status"])},
      {"Reviews", pr_summary_value(pr, "review_state", ["state", "decision", "status"])},
      {"Merge", pr_summary_value(pr, "merge_state", ["mergeable_state", "state", "status"])}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  defp pr_summary_value(pr, key, fields) do
    case map_value(pr, key) do
      %{} = state when map_size(state) > 0 ->
        Enum.find_value(fields, &compact_state_value(Map.get(state, &1))) || "recorded"

      _state ->
        nil
    end
  end

  defp compact_state_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp compact_state_value(value) when is_boolean(value), do: to_string(value)
  defp compact_state_value(value) when is_atom(value), do: Atom.to_string(value)
  defp compact_state_value(value) when is_number(value), do: to_string(value)
  defp compact_state_value(_value), do: nil

  defp guidance_requests(detail) do
    case map_value(detail, :guidance_requests) do
      values when is_list(values) -> atomize_list(values)
      _values -> []
    end
  end

  defp map_value(%{} = map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_value(%{} = map, key) when is_binary(key), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil

  defp public_http_url(nil), do: nil
  defp public_http_url("[REDACTED]"), do: nil

  defp public_http_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      url
    end
  rescue
    _error in URI.Error -> nil
  end

  defp public_http_url(_url), do: nil

  defp short_sha(head_sha) when is_binary(head_sha) and byte_size(head_sha) >= 7, do: String.slice(head_sha, 0, 7)
  defp short_sha(_head_sha), do: nil

  defp display_sha(head_sha) when is_binary(head_sha) do
    head_sha = String.trim(head_sha)

    cond do
      head_sha == "" -> nil
      byte_size(head_sha) >= 7 -> String.slice(head_sha, 0, 7)
      true -> head_sha
    end
  end

  defp display_sha(_head_sha), do: nil

  defp timeline_title(%{type: "finding"} = event), do: event.title || "Finding"
  defp timeline_title(event), do: event.summary || event.status || "Progress"

  defp timeline_body(%{type: "finding"} = event), do: present(event.body)
  defp timeline_body(event), do: present(event.body || event.status)

  defp token_summary(run) do
    total = run.codex_total_tokens || 0
    turns = run.turn_count || 0
    "#{total} tokens / #{turns} turns"
  end

  defp alert_badge_class(%{active: true, severity: "critical"}), do: "state-badge state-badge-danger"
  defp alert_badge_class(%{active: true, severity: "warning"}), do: "state-badge state-badge-warning"
  defp alert_badge_class(%{active: true}), do: "state-badge state-badge-active"
  defp alert_badge_class(_alert), do: "state-badge"

  defp alert_state(%{active: true}), do: "active"
  defp alert_state(_alert), do: "clear"

  defp run_badge_class(%{status: "failed"}), do: "state-badge state-badge-danger"
  defp run_badge_class(%{stale: true}), do: "state-badge state-badge-warning"
  defp run_badge_class(%{runtime_state: runtime_state}) when runtime_state in ["active", "queued"], do: "state-badge state-badge-active"
  defp run_badge_class(_run), do: "state-badge"

  defp guidance_status_class("answered"), do: "state-badge state-badge-active"
  defp guidance_status_class("human_info_needed"), do: "state-badge state-badge-warning"
  defp guidance_status_class(_status), do: "state-badge"

  defp can_answer_guidance?(true, %{status: "human_info_needed"}), do: true
  defp can_answer_guidance?(_operator_mode?, _guidance), do: false

  defp human_guidance_summary(guidance) do
    guidance
    |> map_value(:decision_prompt)
    |> prompt_text(:tl_dr)
    |> case do
      summary when is_binary(summary) and summary != "" -> summary
      _summary -> fallback_human_guidance_summary(guidance)
    end
  end

  defp fallback_human_guidance_summary(guidance) do
    guidance
    |> map_value(:summary)
    |> case do
      summary when is_binary(summary) and summary != "" -> summary
      _summary -> "The agent needs your call before it can continue."
    end
  end

  defp human_guidance_question(guidance) do
    present(map_value(guidance, :question))
  end

  defp human_guidance_context(guidance) do
    guidance
    |> map_value(:decision_prompt)
    |> prompt_text(:details)
    |> case do
      details when is_binary(details) -> details
      _details -> present(map_value(guidance, :context))
    end
  end

  defp human_guidance_detail_rows(guidance) do
    rows =
      if structured_prompt?(map_value(guidance, :decision_prompt)) do
        [
          {"Context", present(map_value(guidance, :context))},
          {"Decision context", human_guidance_context(guidance)},
          {"Suggested path", map_value(guidance, :recommended_language)},
          {"Why it is blocked", map_value(guidance, :human_info_reason)},
          {"Freeform redirect", custom_redirect_label(map_value(guidance, :decision_prompt))}
        ]
      else
        [
          {"Context", present(map_value(guidance, :context))},
          {"Suggested path", map_value(guidance, :recommended_language)},
          {"Why it is blocked", map_value(guidance, :human_info_reason)}
        ]
      end

    Enum.reject(rows, fn {_label, detail} -> detail in [nil, ""] end)
  end

  defp human_answer_choices(record) do
    choices =
      case decision_prompt_options(map_value(record, :decision_prompt)) do
        [] ->
          [
            %{value: "continue", label: "Continue", help: "Use the suggested path.", checked: true},
            %{value: "narrow", label: "Narrow scope", help: "Keep the work smaller or safer.", checked: false},
            %{
              value: "redirect",
              label: custom_redirect_label(nil),
              help: "Tell the agent what to do differently.",
              checked: false,
              note_required: true
            }
          ]

        options ->
          options
          |> Enum.map(&decision_prompt_choice/1)
          |> maybe_append_custom_redirect_choice(map_value(record, :decision_prompt))
          |> mark_first_choice_checked()
      end

    with_note_keys(choices)
  end

  defp structured_prompt?(prompt), do: is_map(prompt) and decision_prompt_options(prompt) != []

  defp prompt_text(prompt, key) when is_map(prompt) do
    case map_value(prompt, key) do
      text when is_binary(text) and text != "" -> text
      _text -> nil
    end
  end

  defp prompt_text(_prompt, _key), do: nil

  defp decision_prompt_options(prompt) when is_map(prompt) do
    case map_value(prompt, :options) do
      options when is_list(options) -> Enum.filter(options, &is_map/1)
      _options -> []
    end
  end

  defp decision_prompt_options(_prompt), do: []

  defp decision_prompt_choice(option) do
    %{
      value: present(map_value(option, :id)),
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

  defp decision_option_label(option), do: present(map_value(option, :label))

  defp decision_option_description(option) do
    case map_value(option, :description) do
      description when is_binary(description) and description != "" -> description
      _description -> nil
    end
  end

  defp decision_option_pros(option), do: option_list(option, :pros)
  defp decision_option_cons(option), do: option_list(option, :cons)

  defp option_list(option, key) do
    case map_value(option, key) do
      values when is_list(values) -> values
      _values -> []
    end
  end

  defp custom_redirect_label(prompt), do: prompt_text(prompt, :custom_redirect_label) || "No, and tell the agent what to do differently"

  defp choice_note_placeholder(%{note_required: true}), do: "Required: tell the agent what to do differently."
  defp choice_note_placeholder(_choice), do: "Optional: add specifics or boundaries for this choice."

  defp put_selected_choice_answer_note(params) when is_map(params) do
    choice = map_value(params, "answer_choice")
    notes = map_value(params, "answer_notes")
    note_choices = map_value(params, "answer_note_choices")

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

    case note_key && map_value(notes, note_key) do
      note when is_binary(note) -> note
      _note -> nil
    end
  end

  defp selected_choice_note(_notes, _note_choices, _choice), do: nil

  defp guidance_request_dom_id(id) do
    encoded = id |> to_string() |> Base.url_encode64(padding: false)
    "guidance-request-#{encoded}"
  end

  defp guidance_choice_input_id(guidance_id, note_key),
    do: "#{guidance_request_dom_id(guidance_id)}-#{note_key}"

  defp required_param(params, key) do
    case map_value(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_guidance_request}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, :missing_guidance_request}
    end
  end

  defp guidance_answer_error_message(:forbidden), do: "Only the local operator cockpit can answer human info guidance."
  defp guidance_answer_error_message(:invalid_status), do: "Only human-info-needed guidance can be answered here."
  defp guidance_answer_error_message(:invalid_answer_choice), do: "Select one of the listed answer choices."
  defp guidance_answer_error_message(:missing_answer), do: "Enter an answer before submitting."
  defp guidance_answer_error_message(:missing_custom_redirect_note), do: "Add replacement guidance before redirecting."
  defp guidance_answer_error_message(:missing_guidance_request), do: "The selected guidance request could not be found."
  defp guidance_answer_error_message(:not_found), do: "The selected guidance request could not be found."
  defp guidance_answer_error_message(:work_package_scope_mismatch), do: "The selected guidance request is outside this package."
  defp guidance_answer_error_message(:database_busy), do: "The Symphony++ package ledger is busy. Try again shortly."
  defp guidance_answer_error_message({:storage_failed, _reason}), do: "The Symphony++ package ledger could not be updated."
  defp guidance_answer_error_message(_reason), do: "The guidance answer could not be recorded."

  defp run_status_label(%{status: status}) when status in ["completed", "failed"], do: status
  defp run_status_label(%{runtime_state: runtime_state}) when is_binary(runtime_state), do: runtime_state
  defp run_status_label(%{status: status}), do: status

  defp status_label(nil), do: "n/a"

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp present(nil), do: "n/a"
  defp present(""), do: "n/a"
  defp present(value), do: value

  defp error_message(:not_found), do: "The Symphony++ work package could not be found."
  defp error_message(:database_busy), do: "The Symphony++ package ledger is busy. Refresh shortly."
  defp error_message({:repo_database_mismatch, _repo}), do: "The configured Symphony++ repo does not match the package ledger."
  defp error_message({:storage_failed, _reason}), do: "The Symphony++ package ledger could not be read."
  defp error_message(_reason), do: "The Symphony++ work package could not be loaded."
end
