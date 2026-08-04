defmodule SymphonyElixirWeb.SymppWorkRequestLive do
  @moduledoc """
  Symphony++ WorkRequest browser and clarification surface.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  import SymphonyElixirWeb.SymppWorkRequestLive.Helpers

  import Ecto.Query
  import Phoenix.HTML.Form, only: [input_value: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixirWeb.SymppBoardLive
  alias SymphonyElixirWeb.SymppDashboardApiController

  @local_operator_actor "local-operator"

  @impl true
  def mount(params, session, socket) do
    board_grant_id = Map.get(session, "sympp_board_grant_id")

    authorization = board_grant_authorization(board_grant_id)
    operator_mode? = effective_operator_mode?(local_operator_mode?(session, socket), authorization)

    {:ok,
     socket
     |> assign(:board_grant_id, board_grant_id)
     |> assign(:operator_mode?, operator_mode?)
     |> assign(:board_grant, authorized_grant(authorization))
     |> assign(:path_prefix, "")
     |> assign(:work_request_id, params["work_request_id"])
     |> assign(:page, initial_page(socket.assigns.live_action, authorization, operator_mode?))}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket = assign(socket, :work_request_id, params["work_request_id"])

    if socket.assigns.operator_mode? do
      {:noreply,
       socket
       |> assign(:path_prefix, path_prefix(uri, socket.assigns.live_action, params))
       |> assign(:page, load_page(socket.assigns.live_action, :local_operator, socket.assigns.work_request_id))}
    else
      case board_grant_authorization(socket.assigns.board_grant_id) do
        {:ok, grant} ->
          {:noreply,
           socket
           |> assign(:board_grant, grant)
           |> assign(:path_prefix, path_prefix(uri, socket.assigns.live_action, params))
           |> assign(
             :page,
             load_page(socket.assigns.live_action, grant, socket.assigns.work_request_id)
           )}

        {:error, reason} ->
          {:noreply, assign(socket, :page, unauthorized_page(reason))}
      end
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <section class="sympp-work-request-shell">
      <header class="sympp-work-request-header">
        <div>
          <p class="eyebrow">Symphony++</p>
          <h1 class="sympp-work-request-title">WorkRequests</h1>
        </div>

        <div class="sympp-work-request-header-actions">
          <nav class="sympp-surface-nav" aria-label="Symphony++ surfaces">
            <a href="board">Work packages</a>
            <a class="active" href="work-requests">WorkRequests</a>
            <a :if={@operator_mode?} href="board?auth=work_key">Use work key</a>
          </nav>
          <a :if={can_create_work_request?(@operator_mode?, @board_grant)} class="sympp-primary-link" href="work-requests/new">New WorkRequest</a>
        </div>
      </header>

      <%= if @page.error do %>
        <section class="error-card">
          <h2 class="error-title">WorkRequests unavailable</h2>
          <p class="error-copy"><%= @page.error %></p>
        </section>
      <% else %>
        <section class="sympp-work-request-summary" aria-label="WorkRequest summary">
          <div>
            <span class="sympp-board-count numeric"><%= @page.total_count %></span>
            <span class="muted">total</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= total_questions(@page.work_requests) %></span>
            <span class="muted">questions</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= total_decisions(@page.work_requests) %></span>
            <span class="muted">decisions</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= total_work_packages(@page.work_requests) %></span>
            <span class="muted">slices</span>
          </div>
        </section>

        <%= if @page.work_requests == [] do %>
          <p class="sympp-empty-state">No WorkRequests are visible for this board scope.</p>
        <% else %>
          <div class="sympp-work-request-list" role="list">
            <a :for={request <- @page.work_requests} class="sympp-work-request-row" href={work_request_path(request)} role="listitem">
              <div class="sympp-work-request-row-main">
                <div class="sympp-work-request-row-heading">
                  <span class="sympp-card-id"><%= value(request, :id) %></span>
                  <span class={status_class(operational_badge_key(request))}><%= operational_badge_label(request) %></span>
                </div>
                <h2><%= value(request, :title) || "Untitled WorkRequest" %></h2>
                <dl class="sympp-work-request-meta">
                  <div>
                    <dt>Repo / base</dt>
                    <dd><%= repo_base(request) %></dd>
                  </div>
                  <div>
                    <dt>Work type</dt>
                    <dd><%= label_value(value(request, :work_type)) %></dd>
                  </div>
                  <div>
                    <dt>Dispatch shape</dt>
                    <dd><%= label_value(value(request, :desired_dispatch_shape)) %></dd>
                  </div>
                  <div>
                    <dt>Updated</dt>
                    <dd class="numeric"><%= timestamp_label(value(request, :updated_at)) %></dd>
                  </div>
                </dl>
              </div>

              <dl class="sympp-work-request-counts" aria-label="WorkRequest counts">
                <div>
                  <dt>Open Q</dt>
                  <dd class="numeric"><%= value(request, :open_question_count, 0) %></dd>
                </div>
                <div>
                  <dt>Answered</dt>
                  <dd class="numeric"><%= value(request, :answered_question_count, 0) %></dd>
                </div>
                <div>
                  <dt>Decisions</dt>
                  <dd class="numeric"><%= value(request, :decision_count, 0) %></dd>
                </div>
                <div>
                  <dt>Slices</dt>
                  <dd class="numeric"><%= work_package_total(request) %></dd>
                </div>
              </dl>
            </a>
          </div>
        <% end %>
      <% end %>
    </section>
    """
  end

  def render(%{live_action: :new} = assigns) do
    ~H"""
    <section class="sympp-work-request-shell">
      <header class="sympp-work-request-header">
        <div>
          <p class="eyebrow">Symphony++ WorkRequest</p>
          <h1 class="sympp-work-request-title">New WorkRequest</h1>
        </div>

        <nav class="sympp-surface-nav" aria-label="Symphony++ surfaces">
          <a href="../board">Work packages</a>
          <a href="../work-requests">WorkRequests</a>
          <a :if={@operator_mode?} href="../board?auth=work_key">Use work key</a>
        </nav>
      </header>

      <%= if @page.error do %>
        <section class="error-card">
          <h2 class="error-title">WorkRequest intake unavailable</h2>
          <p class="error-copy"><%= @page.error %></p>
        </section>
      <% else %>
        <.form :let={f} for={@page.form} as={:work_request} phx-submit="create_work_request" class="sympp-work-request-form">
          <section :if={!@operator_mode?} class="sympp-locked-scope" aria-label="Locked WorkRequest scope">
            <div>
              <span>Repo</span>
              <strong><%= @page.intake_scope.repo %></strong>
            </div>
            <div>
              <span>Base branch</span>
              <strong><%= @page.intake_scope.base_branch %></strong>
            </div>
          </section>

          <p :if={@page.form_error} class="sympp-form-error"><%= @page.form_error %></p>

          <div class="sympp-form-grid">
            <label>
              <span>Title</span>
              <input name={f[:title].name} value={input_value(f, :title)} required maxlength="160" />
            </label>

            <label :if={@operator_mode?}>
              <span>Repo</span>
              <input name={f[:repo].name} value={input_value(f, :repo)} required maxlength="240" />
            </label>

            <label :if={@operator_mode?}>
              <span>Base branch</span>
              <input name={f[:base_branch].name} value={input_value(f, :base_branch)} required maxlength="240" />
            </label>

            <fieldset class="sympp-work-type-options sympp-form-wide">
              <legend>Work type</legend>
              <div class="sympp-choice-grid">
                <label :for={work_type <- WorkRequest.work_types()} class="sympp-choice-card">
                  <input type="radio" name={f[:work_type].name} value={work_type} checked={input_value(f, :work_type) == work_type} required />
                  <span>
                    <strong><%= work_type_label(work_type) %></strong>
                    <small><%= work_type_help(work_type) %></small>
                  </span>
                </label>
              </div>
            </fieldset>

            <label>
              <span>Agent workflow</span>
              <select name={f[:desired_dispatch_shape].name} required>
                <option
                  :for={shape <- WorkRequest.dispatch_shapes()}
                  value={shape}
                  selected={input_value(f, :desired_dispatch_shape) == shape}
                >
                  <%= dispatch_shape_label(shape) %>
                </option>
              </select>
              <small class="sympp-field-help">Choose one package, a feature branch with slices, or an investigation-first pass.</small>
            </label>

            <label class="sympp-form-wide">
              <span>Description</span>
              <textarea name={f[:human_description].name} required rows="6"><%= input_value(f, :human_description) %></textarea>
            </label>

            <details
              class="sympp-form-section sympp-form-wide sympp-advanced-intake"
              aria-label="Optional boundaries and advanced details"
              open={advanced_intake_open?(f, @page.form_error)}
            >
              <summary>
                <span>Optional boundaries and advanced details</span>
                <small>Add path limits, stop conditions, or raw JSON only when the request needs them.</small>
              </summary>

              <div class="sympp-form-grid sympp-form-grid-constraints">
                <label>
                  <span>Allowed paths</span>
                  <textarea name={f[:allowed_paths].name} rows="4" spellcheck="false"><%= input_value(f, :allowed_paths) %></textarea>
                </label>

                <label>
                  <span>Forbidden paths</span>
                  <textarea name={f[:forbidden_paths].name} rows="4" spellcheck="false"><%= input_value(f, :forbidden_paths) %></textarea>
                </label>

                <label>
                  <span>Stop conditions</span>
                  <textarea name={f[:stop_conditions].name} rows="4"><%= input_value(f, :stop_conditions) %></textarea>
                </label>

                <label>
                  <span>Compatibility stance</span>
                  <input name={f[:compatibility_stance].name} value={input_value(f, :compatibility_stance)} maxlength="320" />
                </label>

                <label>
                  <span>Validation expectations</span>
                  <textarea name={f[:validation_expectations].name} rows="4"><%= input_value(f, :validation_expectations) %></textarea>
                </label>

                <label>
                  <span>Dependencies / notes</span>
                  <textarea name={f[:dependencies_notes].name} rows="4"><%= input_value(f, :dependencies_notes) %></textarea>
                </label>

                <label class="sympp-form-wide">
                  <span>Advanced constraints JSON</span>
                  <textarea name={f[:constraints_json].name} rows="5" spellcheck="false"><%= input_value(f, :constraints_json) %></textarea>
                  <small class="sympp-field-help">Optional extra keys. The fields above win when both set the same key.</small>
                </label>
              </div>
            </details>
          </div>

          <div class="sympp-form-actions">
            <button type="submit">Create draft</button>
            <a class="sympp-secondary-link" href="../work-requests">Cancel</a>
          </div>
        </.form>
      <% end %>
    </section>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <section class="sympp-work-request-shell">
      <header class="sympp-work-request-header">
        <div>
          <p class="eyebrow">Symphony++ WorkRequest</p>
          <h1 class="sympp-work-request-title"><%= detail_title(@page) %></h1>
        </div>

        <nav class="sympp-surface-nav" aria-label="Symphony++ surfaces">
          <a href="../board">Work packages</a>
          <a href="../work-requests">WorkRequests</a>
          <a :if={@operator_mode?} href="../board?auth=work_key">Use work key</a>
        </nav>
      </header>

      <%= if @page.error do %>
        <section class="error-card">
          <h2 class="error-title">WorkRequest unavailable</h2>
          <p class="error-copy"><%= @page.error %></p>
        </section>
      <% else %>
        <section class="sympp-work-request-detail">
          <div class="sympp-work-request-detail-main">
            <section class={detail_status_panel_class(@page)} aria-label="WorkRequest state">
              <div class="sympp-detail-status-main">
                <div class="sympp-detail-signal-row">
                  <span class={status_class(operational_badge_key(@page.work_request))}><%= operational_badge_label(@page.work_request) %></span>
                  <span class="sympp-readiness"><%= label_value(value(@page.work_request, :work_type)) %></span>
                  <span class="sympp-readiness"><%= label_value(value(@page.work_request, :desired_dispatch_shape)) %></span>
                </div>
                <h2><%= detail_next_action(@page, @operator_mode?) %></h2>
                <p><%= detail_state_summary(@page, @operator_mode?) %></p>
              </div>
              <dl class="sympp-detail-status-rail">
                <div class={detail_guidance_class(@page)}>
                  <dt><%= detail_guidance_heading(@page, @operator_mode?) %></dt>
                  <dd><%= detail_guidance_label(@page) %></dd>
                </div>
                <div>
                  <dt>Slices</dt>
                  <dd><%= detail_slicing_label(@page) %></dd>
                </div>
                <div>
                  <dt>Handoff</dt>
                  <dd><%= detail_handoff_label(@page, @operator_mode?) %></dd>
                </div>
              </dl>
            </section>
            <p :if={@page.action_error} class="sympp-form-error"><%= @page.action_error %></p>
            <div :if={@page.dispatch_notice} class="sympp-stack-item sympp-dispatch-notice">
              <div class="sympp-work-request-row-heading">
                <span class="state-badge state-badge-active">dispatched</span>
                <span class="sympp-readiness">Worker ledger claim ready</span>
              </div>
              <dl class="sympp-work-request-meta">
                <div>
                  <dt>WorkPackage</dt>
                  <dd>
                    <a href={work_package_route(@path_prefix, @page.dispatch_notice.work_package_id)}>
                      <%= @page.dispatch_notice.work_package_id %>
                    </a>
                  </dd>
                </div>
                <div>
                  <dt>Package status</dt>
                  <dd><%= status_label(@page.dispatch_notice.work_package_status) %></dd>
                </div>
                <div :for={{label, value} <- @page.dispatch_notice.handoff_items}>
                  <dt><%= label %></dt>
                  <dd class="mono"><%= exact_value(value) %></dd>
                </div>
              </dl>
            </div>
            <div :if={can_start_agent_questions?(@operator_mode?, @board_grant, @page.work_request)} class="sympp-action-row">
              <button type="button" phx-click="mark_ready_for_clarification">
                Start agent questions
              </button>
            </div>
            <div :if={show_architect_work_request_controls?(@operator_mode?, @board_grant)} class="sympp-action-row">
              <button
                :if={value(@page.work_request, :status) == "draft"}
                type="button"
                phx-click="mark_ready_for_clarification"
              >
                Mark ready for clarification
              </button>
              <button
                :if={can_mark_human_info_needed?(@page.work_request)}
                type="button"
                class="secondary"
                phx-click="mark_human_info_needed"
              >
                Mark human info needed
              </button>
              <button
                :if={can_mark_ready_for_slicing?(@page.work_request)}
                type="button"
                phx-click="mark_ready_for_slicing"
              >
                Mark ready for slicing
              </button>
            </div>
            <div :if={can_create_architect_handoff?(@operator_mode?, @board_grant, @page.work_request)} class="sympp-action-row">
              <button
                type="button"
                class="secondary"
                phx-click="create_architect_handoff"
              >
                Prepare architect handoff
              </button>
            </div>
            <div class="sympp-copy-row">
              <label for="sympp-work-request-id">WorkRequest ID</label>
              <input id="sympp-work-request-id" class="mono" readonly value={value(@page.work_request, :id)} />
            </div>
            <p><%= value(@page.work_request, :human_description) %></p>
          </div>

          <dl class="sympp-work-request-detail-side">
            <div>
              <dt>Repo / base</dt>
              <dd><%= repo_base(@page.work_request) %></dd>
            </div>
            <div>
              <dt>Created</dt>
              <dd class="numeric"><%= timestamp_label(value(@page.work_request, :inserted_at)) %></dd>
            </div>
            <div>
              <dt>Updated</dt>
              <dd class="numeric"><%= timestamp_label(value(@page.work_request, :updated_at)) %></dd>
            </div>
          </dl>
        </section>

        <section class="sympp-work-request-summary" aria-label="WorkRequest detail counts">
          <div>
            <span class="sympp-board-count numeric"><%= value(@page.summary, :open_question_count, 0) %></span>
            <span class="muted">open questions</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= value(@page.summary, :answered_question_count, 0) %></span>
            <span class="muted">answered</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= value(@page.summary, :decision_count, 0) %></span>
            <span class="muted">decisions</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= summary_work_package_total(@page.summary) %></span>
            <span class="muted">WorkPackages</span>
          </div>
        </section>

        <section :if={@page.architect_handoff} class="sympp-work-request-grid" aria-label="Architect handoff">
          <article class="sympp-panel sympp-panel-wide">
            <div class="sympp-work-request-row-heading">
              <span class="state-badge state-badge-active"><%= handoff_status_label(@page.architect_handoff.status) %></span>
              <span class="sympp-readiness">Private architect handoff stored</span>
            </div>
            <dl class="sympp-work-request-meta sympp-slice-detail-grid">
              <div>
                <dt>WorkRequest</dt>
                <dd class="mono"><%= value(@page.architect_handoff.work_request, :id) %></dd>
              </div>
              <div>
                <dt>Phase</dt>
                <dd class="mono"><%= value(@page.architect_handoff.phase, :id) %></dd>
              </div>
              <div>
                <dt>Anchor package</dt>
                <dd>
                  <a href={work_package_route(@path_prefix, value(@page.architect_handoff.anchor_package, :id))}>
                    <%= value(@page.architect_handoff.anchor_package, :id) %>
                  </a>
                </dd>
              </div>
              <div>
                <dt>Grant</dt>
                <dd class="mono"><%= value(@page.architect_handoff.grant, :id) %></dd>
              </div>
              <div>
                <dt>Scope</dt>
                <dd><%= architect_handoff_scope(@page.architect_handoff) %></dd>
              </div>
              <div>
                <dt>Capabilities</dt>
                <dd><%= list_label(value(@page.architect_handoff.grant, :capabilities, [])) %></dd>
              </div>
              <div>
                <dt>Expires</dt>
                <dd class="numeric"><%= exact_value(value(@page.architect_handoff.grant, :expires_at)) %></dd>
              </div>
            </dl>
            <div :if={architect_launch_brief(@page, @operator_mode?)} class="sympp-launch-brief">
              <div class="sympp-launch-brief-header">
                <label><%= architect_launch_brief_label(@page, @operator_mode?) %></label>
                <button
                  type="button"
                  class="subtle-button sympp-copy-button"
                  aria-label="Copy architect launch prompt"
                  data-label="Copy"
                  onclick="const button = this; const label = button.dataset.label; const reset = (text) => { button.textContent = text; clearTimeout(button._copyTimer); button._copyTimer = setTimeout(() => { button.textContent = label }, 1200); }; const pre = button.closest('.sympp-launch-brief').querySelector('pre'); if (!navigator.clipboard || !navigator.clipboard.writeText) { reset('Copy failed'); return; } navigator.clipboard.writeText(pre.textContent).then(() => reset('Copied'), () => reset('Copy failed'));"
                >
                  Copy
                </button>
              </div>
              <pre class="sympp-copyable-block mono"><%= architect_launch_brief(@page, @operator_mode?) %></pre>
            </div>
            <div :if={safe_architect_prompt(@page, @operator_mode?)} class="sympp-launch-brief">
              <label>Safe architect prompt</label>
              <pre class="sympp-json-block sympp-copyable-block"><%= safe_architect_prompt(@page, @operator_mode?) %></pre>
            </div>
          </article>
        </section>

        <section class="sympp-work-request-grid">
          <article class="sympp-panel sympp-panel-wide">
            <h2>Constraints</h2>
            <pre class="sympp-json-block"><%= json_block(value(@page.work_request, :constraints, %{})) %></pre>
          </article>

          <article class="sympp-panel">
            <h2><%= if @operator_mode?, do: "Questions for you", else: "Clarification questions" %></h2>
            <p :if={@operator_mode?} class="sympp-panel-intro">
              Answer the items that need a human call. Architect authoring controls stay out of the local cockpit.
            </p>
            <.form
              :if={show_architect_work_request_controls?(@operator_mode?, @board_grant) && can_clarify?(@page.work_request)}
              :let={f}
              for={%{}}
              as={:question}
              phx-submit="ask_question"
              class="sympp-compact-form"
            >
              <div class="sympp-form-grid sympp-form-grid-compact">
                <label>
                  <span>Category</span>
                  <input name={f[:category].name} required maxlength="80" />
                </label>
                <label class="sympp-form-wide">
                  <span>Question</span>
                  <textarea name={f[:question].name} required rows="3"></textarea>
                </label>
                <label class="sympp-form-wide">
                  <span>Why needed</span>
                  <textarea name={f[:why_needed].name} required rows="2"></textarea>
                </label>
              </div>
              <div class="sympp-form-actions">
                <button type="submit">Ask question</button>
              </div>
            </.form>
            <div :if={@page.clarification_questions != []} class="sympp-stack-list">
              <div :for={question <- @page.clarification_questions} class="sympp-stack-item">
                <div class="sympp-work-request-row-heading">
                  <span class="sympp-card-id"><%= sequence_label(question) %></span>
                  <span class={status_class(value(question, :status))}><%= status_label(value(question, :status)) %></span>
                </div>
                <%= if @operator_mode? and value(question, :status) == "open" do %>
                  <section class="sympp-human-decision-card">
                    <header class="sympp-human-decision-header">
                      <p class="sympp-human-kicker">Human answer needed</p>
                      <div>
                        <span class="sympp-human-section-label">TL;DR</span>
                        <h3><%= human_question_summary(question) %></h3>
                      </div>
                    </header>
                    <section class="sympp-human-section sympp-human-question-section">
                      <span class="sympp-human-section-label">Question</span>
                      <p class="sympp-human-question"><%= human_question_text(question) %></p>
                    </section>
                    <dl class="sympp-human-decision-details">
                      <div :for={{label, detail} <- human_question_detail_rows(question)}>
                        <dt><%= label %></dt>
                        <dd><%= detail %></dd>
                      </div>
                    </dl>
                    <div :if={decision_prompt_options(value(question, :decision_prompt)) != []} class="sympp-decision-option-list">
                      <article :for={option <- decision_prompt_options(value(question, :decision_prompt))} class="sympp-decision-option-card">
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
                    <.form :let={f} for={%{}} as={:question} phx-submit="answer_question" class="sympp-human-answer-form">
                      <input type="hidden" name={f[:id].name} value={value(question, :id)} />
                      <input type="hidden" name={f[:current_status].name} value={value(question, :status)} />
                      <div class="sympp-choice-list" role="radiogroup" aria-label="Answer direction">
                        <div :for={choice <- human_answer_choices(question)} class="sympp-choice-option">
                          <% choice_input_id = question_choice_input_id(value(question, :id), choice.note_key) %>
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
                  </section>
                <% else %>
                  <p class="mono"><%= value(question, :id) %></p>
                  <h3><%= value(question, :question) %></h3>
                  <p><%= value(question, :why_needed) %></p>
                <% end %>
                <p :if={value(question, :answer)}><strong>Answer:</strong> <%= value(question, :answer) %></p>
                <div :if={show_architect_work_request_controls?(@operator_mode?, @board_grant) && value(question, :status) == "open"} class="sympp-question-actions">
                  <.form :let={f} for={%{}} as={:question} phx-submit="answer_question" class="sympp-inline-answer-form">
                    <input type="hidden" name={f[:id].name} value={value(question, :id)} />
                    <input type="hidden" name={f[:current_status].name} value={value(question, :status)} />
                    <label>
                      <span>Answer</span>
                      <textarea name={f[:answer].name} required rows="2"></textarea>
                    </label>
                    <label>
                      <span>Answered by</span>
                      <input name={f[:answered_by].name} value={default_actor(@operator_mode?, @board_grant)} required maxlength="120" />
                    </label>
                    <div class="sympp-form-actions">
                      <button type="submit">Answer</button>
                    </div>
                  </.form>
                  <.form :let={f} for={%{}} as={:question} phx-submit="close_question" class="sympp-close-form">
                    <input type="hidden" name={f[:id].name} value={value(question, :id)} />
                    <input type="hidden" name={f[:current_status].name} value={value(question, :status)} />
                    <button type="submit" class="secondary">Close unanswered</button>
                  </.form>
                </div>
              </div>
            </div>
            <p :if={@page.clarification_questions == []} class="sympp-empty-inline">No clarification questions recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2><%= if @operator_mode?, do: "Decision history", else: "Decision log" %></h2>
            <p :if={@operator_mode?} class="sympp-panel-intro">
              Past calls stay visible for context. New architecture decisions are recorded through the architect flow.
            </p>
            <.form
              :if={show_architect_work_request_controls?(@operator_mode?, @board_grant) && can_clarify?(@page.work_request)}
              :let={f}
              for={%{}}
              as={:decision}
              phx-submit="record_decision"
              class="sympp-compact-form"
            >
              <div class="sympp-form-grid sympp-form-grid-compact">
                <label>
                  <span>Source</span>
                  <select name={f[:source_type].name} required>
                    <option :for={source <- decision_source_types()} value={source}><%= label_value(source) %></option>
                  </select>
                </label>
                <label>
                  <span>Created by</span>
                  <input name={f[:created_by].name} value={default_actor(@operator_mode?, @board_grant)} required maxlength="120" />
                </label>
                <label class="sympp-form-wide">
                  <span>Decision</span>
                  <textarea name={f[:decision].name} required rows="2"></textarea>
                </label>
                <label class="sympp-form-wide">
                  <span>Rationale</span>
                  <textarea name={f[:rationale].name} required rows="2"></textarea>
                </label>
                <label class="sympp-form-wide">
                  <span>Scope impact</span>
                  <textarea name={f[:scope_impact].name} required rows="2"></textarea>
                </label>
              </div>
              <div class="sympp-form-actions">
                <button type="submit">Record decision</button>
              </div>
            </.form>
            <div :if={@page.decision_logs != []} class="sympp-stack-list">
              <div :for={decision <- @page.decision_logs} class="sympp-stack-item">
                <div class="sympp-work-request-row-heading">
                  <span class="sympp-card-id"><%= sequence_label(decision) %></span>
                  <span class="sympp-readiness"><%= label_value(value(decision, :source_type)) %></span>
                </div>
                <p class="mono"><%= value(decision, :id) %></p>
                <h3><%= value(decision, :decision) %></h3>
                <p><%= value(decision, :rationale) %></p>
                <p><%= value(decision, :scope_impact) %></p>
              </div>
            </div>
            <p :if={@page.decision_logs == []} class="sympp-empty-inline">No decisions recorded.</p>
          </article>

          <article class="sympp-panel sympp-panel-wide">
            <h2>WorkPackages</h2>
            <p :if={@operator_mode?} class="sympp-panel-intro">
              The architect creates the WorkRequest plan atomically. Planned WorkPackages can be dispatched here.
            </p>
            <.form
              :if={show_architect_work_request_controls?(@operator_mode?, @board_grant) && can_author_work_package?(@page)}
              :let={f}
              for={@page.work_package_form}
              as={:work_package}
              phx-submit="add_work_package"
              class="sympp-compact-form sympp-work-package-form"
            >
              <p :if={@page.work_package_form_error} class="sympp-form-error"><%= @page.work_package_form_error %></p>
              <div class="sympp-form-grid sympp-form-grid-slice">
                <label>
                  <span>Title</span>
                  <input name={f[:title].name} value={input_value(f, :title)} required maxlength="160" />
                </label>
                <label>
                  <span>Kind</span>
                  <select name={f[:kind].name} required>
                    <option
                      :for={kind <- executable_kinds()}
                      value={kind}
                      selected={input_value(f, :kind) == kind}
                    >
                      <%= label_value(kind) %>
                    </option>
                  </select>
                </label>
                <label>
                  <span>Target base</span>
                  <input name={f[:base_branch].name} value={input_value(f, :base_branch)} required maxlength="160" />
                </label>
                <label class="sympp-form-wide">
                  <span>Goal</span>
                  <textarea name={f[:goal].name} required rows="3"><%= input_value(f, :goal) %></textarea>
                </label>
                <label class="sympp-form-wide">
                  <span>Branch pattern</span>
                  <input name={f[:branch_pattern].name} value={input_value(f, :branch_pattern)} maxlength="220" />
                </label>
                <label>
                  <span>Owned files</span>
                  <textarea name={f[:allowed_file_globs].name} rows="4"><%= input_value(f, :allowed_file_globs) %></textarea>
                </label>
                <label>
                  <span>Forbidden files</span>
                  <textarea name={f[:forbidden_file_globs].name} rows="4"><%= input_value(f, :forbidden_file_globs) %></textarea>
                </label>
                <label>
                  <span>Review (optional JSON)</span>
                  <textarea name={f[:review_json].name} rows="4" placeholder={~s({"type":"human","args":{"role":"maintainer"}})}><%= input_value(f, :review_json) %></textarea>
                </label>
                <label class="sympp-form-wide">
                  <span>Acceptance criteria</span>
                  <textarea name={f[:acceptance_criteria].name} rows="4"><%= input_value(f, :acceptance_criteria) %></textarea>
                </label>
                <label class="sympp-form-wide">
                  <span>Validation steps</span>
                  <textarea name={f[:validation_steps].name} rows="4"><%= input_value(f, :validation_steps) %></textarea>
                </label>
                <label class="sympp-form-wide">
                  <span>Stop conditions</span>
                  <textarea name={f[:stop_conditions].name} rows="3"><%= input_value(f, :stop_conditions) %></textarea>
                </label>
              </div>
              <div class="sympp-form-actions">
                <button type="submit">Create WorkRequest plan</button>
              </div>
            </.form>
            <div :if={@page.work_packages != []} class="sympp-slice-list">
              <div :for={slice <- @page.work_packages} class="sympp-slice-row">
                <div>
                  <div class="sympp-work-request-row-heading">
                    <span class="sympp-card-id"><%= sequence_label(slice) %></span>
                    <span class={status_class(operational_badge_key(slice))}><%= operational_badge_label(slice) %></span>
                  </div>
                  <p class="mono"><%= value(slice, :id) %></p>
                  <h3><%= value(slice, :title) %></h3>
                  <p><%= value(slice, :goal) %></p>
                  <div class="sympp-slice-actions">
                    <.form
                      :if={show_architect_work_request_controls?(@operator_mode?, @board_grant) && can_skip_work_package?(@page.work_request, slice)}
                      :let={f}
                      for={%{}}
                      as={:slice}
                      phx-submit="skip_work_package"
                      class="sympp-inline-slice-form"
                    >
                      <input type="hidden" name={f[:id].name} value={value(slice, :id)} />
                      <input type="hidden" name={f[:current_status].name} value={value(slice, :status)} />
                      <button type="submit" class="secondary">Skip</button>
                    </.form>
                    <.form
                      :if={can_dispatch_work_package?(@operator_mode?, @board_grant, @page.work_request, slice)}
                      :let={f}
                      for={%{}}
                      as={:slice}
                      phx-submit="dispatch_work_package"
                      class="sympp-inline-slice-form"
                    >
                      <input type="hidden" name={f[:id].name} value={value(slice, :id)} />
                      <button type="submit">Dispatch</button>
                    </.form>
                  </div>
                </div>
                <dl class="sympp-work-request-meta sympp-slice-detail-grid">
                  <div>
                    <dt>Kind</dt>
                    <dd><%= label_value(value(slice, :kind)) %></dd>
                  </div>
                  <div>
                    <dt>Target base</dt>
                    <dd><%= exact_value(value(slice, :base_branch)) %></dd>
                  </div>
                  <div>
                    <dt>Branch pattern</dt>
                    <dd><%= exact_value(value(slice, :branch_pattern)) %></dd>
                  </div>
                  <div :if={value(slice, :work_package_id)}>
                    <dt>WorkPackage</dt>
                    <dd>
                      <a href={work_package_route(@path_prefix, value(slice, :work_package_id))}>
                        <%= value(slice, :work_package_id) %>
                      </a>
                    </dd>
                  </div>
                  <div :if={value(slice, :work_package_status)}>
                    <dt>Package status</dt>
                    <dd><%= status_label(value(slice, :work_package_status)) %></dd>
                  </div>
                  <div :if={value(slice, :dispatched_at)}>
                    <dt>Dispatched</dt>
                    <dd class="numeric"><%= timestamp_label(value(slice, :dispatched_at)) %></dd>
                  </div>
                  <div>
                    <dt>Owned files</dt>
                    <dd><%= list_label(value(slice, :allowed_file_globs, [])) %></dd>
                  </div>
                  <div>
                    <dt>Forbidden files</dt>
                    <dd><%= list_label(value(slice, :forbidden_file_globs, [])) %></dd>
                  </div>
                  <div>
                    <dt>Acceptance</dt>
                    <dd><%= list_label(value(slice, :acceptance_criteria, [])) %></dd>
                  </div>
                  <div>
                    <dt>Validation</dt>
                    <dd><%= list_label(value(slice, :validation_steps, [])) %></dd>
                  </div>
                  <div>
                    <dt>Review</dt>
                    <dd><%= value(slice, :review) |> json_block() %></dd>
                  </div>
                  <div>
                    <dt>Stop conditions</dt>
                    <dd><%= list_label(value(slice, :stop_conditions, [])) %></dd>
                  </div>
                </dl>
              </div>
            </div>
            <p :if={@page.work_packages == []} class="sympp-empty-inline">No WorkPackages recorded.</p>
          </article>
        </section>
      <% end %>
    </section>
    """
  end

  @impl true
  def handle_event("create_work_request", %{"work_request" => params}, socket) do
    case action_actor(socket) do
      {:ok, actor, socket} ->
        case create_work_request(actor, params) do
          {:ok, work_request} ->
            {:noreply,
             socket
             |> put_flash(:info, "WorkRequest draft created.")
             |> push_navigate(to: work_request_route(socket, work_request.id))}

          {:error, reason, form} ->
            {:noreply, assign(socket, :page, new_page(actor, form, form_error_message(reason)))}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :page, unauthorized_page(reason))}
    end
  end

  def handle_event("mark_ready_for_clarification", _params, socket) do
    case action_actor(socket) do
      {:ok, actor, socket} ->
        case mark_ready_for_clarification(actor, socket.assigns.work_request_id) do
          {:ok, _work_request} ->
            {:noreply,
             socket
             |> put_flash(:info, mark_ready_for_clarification_flash(actor))
             |> assign(:page, load_page(:show, actor, socket.assigns.work_request_id))}

          {:error, reason} ->
            page =
              :show
              |> load_page(actor, socket.assigns.work_request_id)
              |> Map.put(:action_error, action_error_message(reason))

            {:noreply, assign(socket, :page, page)}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :page, unauthorized_page(reason))}
    end
  end

  def handle_event("ask_question", %{"question" => params}, socket) do
    handle_scoped_action(socket, fn grant ->
      ask_question(grant, socket.assigns.work_request_id, params)
    end)
  end

  def handle_event("answer_question", %{"question" => params}, socket) do
    handle_scoped_action(socket, fn grant ->
      answer_question(grant, socket.assigns.work_request_id, params)
    end)
  end

  def handle_event("close_question", %{"question" => params}, socket) do
    handle_scoped_action(socket, fn grant ->
      close_question(grant, socket.assigns.work_request_id, params)
    end)
  end

  def handle_event("record_decision", %{"decision" => params}, socket) do
    handle_scoped_action(socket, fn grant ->
      record_decision(grant, socket.assigns.work_request_id, params)
    end)
  end

  def handle_event("add_work_package", %{"work_package" => params}, socket) do
    case action_actor(socket) do
      {:ok, actor, socket} ->
        case add_work_package(actor, socket.assigns.work_request_id, params) do
          {:ok, _work_package} ->
            {:noreply,
             socket
             |> put_flash(:info, "WorkRequest sliced with one planned WorkPackage.")
             |> assign(:page, load_page(:show, actor, socket.assigns.work_request_id))}

          {:error, reason, form} ->
            page =
              :show
              |> load_page(actor, socket.assigns.work_request_id)
              |> Map.put(:work_package_form, form)
              |> Map.put(:work_package_form_error, work_package_form_error_message(reason))
              |> maybe_put_architect_control_error(reason)

            {:noreply, assign(socket, :page, page)}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :page, unauthorized_page(reason))}
    end
  end

  def handle_event("skip_work_package", %{"slice" => params}, socket) do
    handle_scoped_action(socket, fn grant ->
      skip_work_package(grant, socket.assigns.work_request_id, params)
    end)
  end

  def handle_event("dispatch_work_package", %{"slice" => params}, socket) do
    case action_actor(socket) do
      {:ok, :local_operator, socket} ->
        case dispatch_work_package(:local_operator, socket.assigns.work_request_id, params) do
          {:ok, dispatch} ->
            page =
              :show
              |> load_page(:local_operator, socket.assigns.work_request_id)
              |> Map.put(:dispatch_notice, dispatch_notice(dispatch))

            {:noreply, socket |> put_flash(:info, "WorkPackage dispatched.") |> assign(:page, page)}

          {:error, reason} ->
            page =
              :show
              |> load_page(:local_operator, socket.assigns.work_request_id)
              |> Map.put(:action_error, dispatch_error_message(reason))

            {:noreply, assign(socket, :page, page)}
        end

      {:ok, actor, socket} ->
        page =
          :show
          |> load_page(actor, socket.assigns.work_request_id)
          |> Map.put(:action_error, dispatch_error_message(:forbidden))

        {:noreply, assign(socket, :page, page)}

      {:error, reason} ->
        {:noreply, assign(socket, :page, unauthorized_page(reason))}
    end
  end

  def handle_event("create_architect_handoff", _params, socket) do
    case action_actor(socket) do
      {:ok, :local_operator, socket} ->
        case create_architect_handoff(:local_operator, socket.assigns.work_request_id) do
          {:ok, handoff} ->
            page =
              :show
              |> load_page(:local_operator, socket.assigns.work_request_id)
              |> Map.put(:architect_handoff, handoff)

            {:noreply,
             socket
             |> put_flash(:info, architect_handoff_flash(handoff.status))
             |> assign(:page, page)}

          {:error, reason} ->
            page =
              :show
              |> load_page(:local_operator, socket.assigns.work_request_id)
              |> Map.put(:action_error, architect_handoff_error_message(reason))

            {:noreply, assign(socket, :page, page)}
        end

      {:ok, actor, socket} ->
        page =
          :show
          |> load_page(actor, socket.assigns.work_request_id)
          |> Map.put(:action_error, architect_handoff_error_message(:forbidden))

        {:noreply, assign(socket, :page, page)}

      {:error, reason} ->
        {:noreply, assign(socket, :page, unauthorized_page(reason))}
    end
  end

  def handle_event("mark_human_info_needed", _params, socket) do
    handle_scoped_action(socket, fn grant ->
      mark_human_info_needed(grant, socket.assigns.work_request_id)
    end)
  end

  def handle_event("mark_ready_for_slicing", _params, socket) do
    handle_scoped_action(socket, fn grant ->
      mark_ready_for_slicing(grant, socket.assigns.work_request_id)
    end)
  end

  defp handle_scoped_action(socket, action) when is_function(action, 1) do
    case action_actor(socket) do
      {:ok, actor, socket} ->
        case action.(actor) do
          {:ok, _result} ->
            {:noreply, assign(socket, :page, load_page(:show, actor, socket.assigns.work_request_id))}

          {:error, reason} ->
            page =
              :show
              |> load_page(actor, socket.assigns.work_request_id)
              |> Map.put(:action_error, action_error_message(reason))

            {:noreply, assign(socket, :page, page)}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :page, unauthorized_page(reason))}
    end
  end

  defp action_actor(socket) do
    case board_grant_authorization(socket.assigns.board_grant_id) do
      {:ok, %AccessGrant{} = grant} -> {:ok, grant, assign(socket, :board_grant, grant)}
      {:error, _reason} when socket.assigns.operator_mode? -> {:ok, :local_operator, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_operator_mode?(session, socket) do
    SymppDashboardApiController.local_operator_session?(session) and
      if connected?(socket) do
        SymppDashboardApiController.local_operator_live_connect_info?(%{
          peer_data: get_connect_info(socket, :peer_data),
          uri: get_connect_info(socket, :uri),
          x_headers: get_connect_info(socket, :x_headers)
        })
      else
        true
      end
  end

  defp effective_operator_mode?(true, {:ok, %AccessGrant{}}), do: false
  defp effective_operator_mode?(operator_mode?, _authorization), do: operator_mode?

  defp board_grant_authorization(grant_id) do
    case SymppDashboardApiController.authorize_board_grant_id(grant_id) do
      {:ok, grant} -> {:ok, grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorized_grant({:ok, grant}), do: grant
  defp authorized_grant(_authorization), do: nil

  defp initial_page(_live_action, _authorization, true), do: loading_page()
  defp initial_page(_live_action, {:ok, _grant}, false), do: loading_page()
  defp initial_page(_live_action, {:error, reason}, false), do: unauthorized_page(reason)

  defp load_page(:index, %AccessGrant{} = grant, _work_request_id) do
    case SymppBoardLive.with_dashboard_repo(&Dashboard.work_requests_for_grant(&1, grant)) do
      {:ok, payload} -> loading_page() |> Map.merge(payload) |> Map.put(:error, nil)
      {:error, reason} -> error_page(reason)
    end
  end

  defp load_page(:index, :local_operator, _work_request_id) do
    case SymppBoardLive.with_dashboard_repo(&Dashboard.work_requests/1) do
      {:ok, payload} -> loading_page() |> Map.merge(payload) |> Map.put(:error, nil)
      {:error, reason} -> error_page(reason)
    end
  end

  defp load_page(:new, :local_operator, _work_request_id), do: new_page(:local_operator)

  defp load_page(:new, %AccessGrant{} = grant, _work_request_id), do: new_page(grant)

  defp load_page(:show, %AccessGrant{} = grant, work_request_id)
       when is_binary(work_request_id) do
    case SymppBoardLive.with_dashboard_repo(&Dashboard.work_request_detail_for_grant(&1, work_request_id, grant)) do
      {:ok, payload} ->
        loading_page()
        |> Map.merge(payload)
        |> Map.put(:error, nil)
        |> put_work_package_form()

      {:error, reason} ->
        error_page(reason)
    end
  end

  defp load_page(:show, :local_operator, work_request_id) when is_binary(work_request_id) do
    case SymppBoardLive.with_dashboard_repo(&local_operator_work_request_detail(&1, work_request_id)) do
      {:ok, payload} ->
        loading_page()
        |> Map.merge(payload)
        |> Map.put(:error, nil)
        |> put_work_package_form()

      {:error, reason} ->
        error_page(reason)
    end
  end

  defp load_page(:show, %AccessGrant{}, _work_request_id), do: error_page(:not_found)
  defp load_page(:show, :local_operator, _work_request_id), do: error_page(:not_found)

  defp local_operator_work_request_detail(repo, work_request_id) do
    with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo),
         {:ok, payload} <-
           Dashboard.work_request_detail(repo, work_request_id, repo_identity_catalog: repo_identity_catalog) do
      {:ok, Map.put(payload, :architect_handoff, existing_architect_handoff(repo, work_request_id))}
    end
  end

  defp existing_architect_handoff(repo, work_request_id) do
    case ArchitectHandoff.existing_display(repo, work_request_id,
           local_operator?: true,
           handoff_opts: architect_handoff_opts(repo)
         ) do
      {:ok, handoff} -> handoff
      {:error, _reason} -> nil
    end
  end

  defp loading_page do
    %{
      error: nil,
      total_count: 0,
      work_requests: [],
      work_request: %{},
      clarification_questions: [],
      decision_logs: [],
      work_packages: [],
      summary: %{},
      form: work_request_form(),
      form_error: nil,
      work_package_form: work_package_form(),
      work_package_form_error: nil,
      intake_scope: nil,
      action_error: nil,
      dispatch_notice: nil,
      architect_handoff: nil
    }
  end

  defp put_work_package_form(%{work_package_form: form, work_request: work_request} = page)
       when is_map(form) do
    Map.put(page, :work_package_form, work_package_form(form, work_request))
  end

  defp new_page(actor, form \\ work_request_form(), form_error \\ nil)

  defp new_page(%AccessGrant{} = grant, form, form_error) do
    case intake_scope(grant) do
      {:ok, scope} ->
        loading_page()
        |> Map.put(:form, work_request_form(form))
        |> Map.put(:form_error, form_error)
        |> Map.put(:intake_scope, scope)

      {:error, reason} ->
        error_page(reason)
    end
  end

  defp new_page(:local_operator, form, form_error) do
    loading_page()
    |> Map.put(:form, work_request_form(form))
    |> Map.put(:form_error, form_error)
  end

  defp unauthorized_page(reason) when reason in [:unauthorized, :forbidden] do
    Map.put(
      loading_page(),
      :error,
      "Board access expired. Reload and enter a current board work key."
    )
  end

  defp unauthorized_page(reason), do: error_page(reason)

  defp error_page(reason), do: Map.put(loading_page(), :error, error_message(reason))

  defp error_message(:not_found), do: "The WorkRequest was not found in this board scope."

  defp error_message(:forbidden),
    do: "This board grant cannot create WorkRequests for a frozen repo and base branch."

  defp error_message(:database_busy), do: "The Symphony++ ledger is busy. Refresh shortly."
  defp error_message({:storage_failed, _reason}), do: "The Symphony++ ledger could not be read."
  defp error_message(_reason), do: "The WorkRequest surface could not be loaded."

  defp form_error_message(:invalid_constraints_json), do: "Constraints must be valid JSON."
  defp form_error_message(:constraints_not_object), do: "Constraints JSON must be an object."
  defp form_error_message(:forbidden), do: error_message(:forbidden)
  defp form_error_message(:database_busy), do: "The Symphony++ ledger is busy. Try again shortly."

  defp form_error_message({:storage_failed, _reason}),
    do: "The Symphony++ ledger could not store the WorkRequest."

  defp form_error_message(%Ecto.Changeset{}), do: "Check the required fields and selected values."
  defp form_error_message(_reason), do: "The WorkRequest could not be created."

  defp work_package_form_error_message(:forbidden), do: error_message(:forbidden)
  defp work_package_form_error_message(:architect_control), do: action_error_message(:architect_control)
  defp work_package_form_error_message(:database_busy), do: "The Symphony++ ledger is busy. Try again shortly."
  defp work_package_form_error_message(:not_found), do: action_error_message(:not_found)
  defp work_package_form_error_message(:invalid_status), do: action_error_message(:invalid_status)
  defp work_package_form_error_message(:open_questions), do: action_error_message(:open_questions)

  defp work_package_form_error_message({:storage_failed, _reason}),
    do: "The Symphony++ ledger could not store the WorkPackage."

  defp work_package_form_error_message(%Ecto.Changeset{}),
    do: "Check the required fields and selected values."

  defp work_package_form_error_message(_reason), do: "The WorkPackage could not be created."

  defp maybe_put_architect_control_error(page, :architect_control),
    do: Map.put(page, :action_error, action_error_message(:architect_control))

  defp maybe_put_architect_control_error(page, _reason), do: page

  defp action_error_message(:stale_status),
    do: "The WorkRequest status changed. Refresh and try again."

  defp action_error_message(:already_answered), do: "That question is already answered."
  defp action_error_message(:already_closed), do: "That question is already closed."

  defp action_error_message(:open_questions),
    do: "Close or answer all open questions before marking ready for slicing."

  defp action_error_message(:no_work_packages),
    do: "Add at least one WorkPackage before marking sliced."

  defp action_error_message(:last_active_work_package),
    do: "A sliced WorkRequest must keep at least one active WorkPackage."

  defp action_error_message(:invalid_status),
    do: "That action is not available from the current status."

  defp action_error_message(:invalid_answer_choice),
    do: "Select one of the listed answer choices."

  defp action_error_message(:missing_answer),
    do: "Select an answer before submitting."

  defp action_error_message(:missing_custom_redirect_note),
    do: "Add replacement guidance before redirecting."

  defp action_error_message(:not_found), do: "The WorkRequest was not found in this board scope."

  defp action_error_message(:architect_control),
    do: "That action belongs in the architect workflow."

  defp action_error_message(:database_busy),
    do: "The Symphony++ ledger is busy. Try again shortly."

  defp action_error_message({:storage_failed, _reason}),
    do: "The Symphony++ ledger could not update the WorkRequest."

  defp action_error_message(:forbidden), do: error_message(:forbidden)

  defp action_error_message(%Ecto.Changeset{}),
    do: "Check the required fields and selected values."

  defp action_error_message(_reason), do: "The WorkRequest could not be updated."

  defp dispatch_error_message(:forbidden),
    do: "WorkPackage dispatch is only available in local operator mode."

  defp dispatch_error_message(reason), do: "WorkPackage dispatch failed: #{WorkPackageDispatch.error_message(reason)}"

  defp architect_handoff_error_message(:forbidden),
    do: "Architect handoff is only available in local operator mode."

  defp architect_handoff_error_message(reason), do: ArchitectHandoff.error_message(reason)

  defp mark_ready_for_clarification_flash(:local_operator), do: "WorkRequest ready for agent questions."
  defp mark_ready_for_clarification_flash(_actor), do: "WorkRequest marked ready for clarification."

  defp architect_handoff_flash(:replayed), do: "Existing architect handoff replayed."
  defp architect_handoff_flash(:renewed), do: "Architect handoff renewed."
  defp architect_handoff_flash(_status), do: "Architect handoff ready."

  defp create_work_request(%AccessGrant{} = grant, params) do
    form = work_request_form(params)

    with {:ok, scope} <- intake_scope(grant),
         {:ok, constraints} <- constraints_from_form(form) do
      attrs =
        form
        |> Map.take(["title", "work_type", "human_description", "desired_dispatch_shape"])
        |> Map.put("repo", scope.repo)
        |> Map.put("base_branch", scope.base_branch)
        |> Map.put("constraints", constraints)
        |> Map.merge(work_request_provenance("human", default_actor(grant), "cockpit"))

      case SymppBoardLive.with_dashboard_repo(&WorkRequestService.create(&1, attrs)) do
        {:ok, work_request} -> {:ok, work_request}
        {:error, reason} -> {:error, reason, form}
      end
    else
      {:error, reason} -> {:error, reason, form}
    end
  end

  defp create_work_request(:local_operator, params) do
    form = work_request_form(params)

    with {:ok, repo} <- filled_form_value(form["repo"], :repo_required),
         {:ok, base_branch} <- filled_form_value(form["base_branch"], :base_branch_required),
         {:ok, constraints} <- constraints_from_form(form) do
      attrs =
        form
        |> Map.take(["title", "work_type", "human_description", "desired_dispatch_shape"])
        |> Map.put("repo", repo)
        |> Map.put("base_branch", base_branch)
        |> Map.put("constraints", constraints)
        |> Map.merge(work_request_provenance("human", @local_operator_actor, "cockpit"))

      case SymppBoardLive.with_dashboard_repo(&WorkRequestService.create(&1, attrs)) do
        {:ok, work_request} -> {:ok, work_request}
        {:error, reason} -> {:error, reason, form}
      end
    else
      {:error, reason} -> {:error, reason, form}
    end
  end

  defp mark_ready_for_clarification(%AccessGrant{} = grant, work_request_id)
       when is_binary(work_request_id) do
    SymppBoardLive.with_dashboard_repo(&mark_ready_in_repo(&1, grant, work_request_id))
  end

  defp mark_ready_for_clarification(:local_operator, work_request_id)
       when is_binary(work_request_id) do
    SymppBoardLive.with_dashboard_repo(&mark_ready_in_repo(&1, :local_operator, work_request_id))
  end

  defp mark_ready_for_clarification(_grant, _work_request_id), do: {:error, :not_found}

  defp work_request_provenance(kind, name, via) do
    %{
      "creator_kind" => kind,
      "creator_name" => name,
      "created_via" => via
    }
  end

  defp ask_question(:local_operator, work_request_id, params)
       when is_binary(work_request_id) and is_map(params),
       do: {:error, :architect_control}

  defp ask_question(actor, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    SymppBoardLive.with_dashboard_repo(&ask_question_in_repo(&1, actor, work_request_id, params))
  end

  defp ask_question(_grant, _work_request_id, _params), do: {:error, :not_found}

  defp answer_question(actor, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    SymppBoardLive.with_dashboard_repo(&answer_question_in_repo(&1, actor, work_request_id, params))
  end

  defp answer_question(_grant, _work_request_id, _params), do: {:error, :not_found}

  defp close_question(:local_operator, work_request_id, params)
       when is_binary(work_request_id) and is_map(params),
       do: {:error, :architect_control}

  defp close_question(actor, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    SymppBoardLive.with_dashboard_repo(&close_question_in_repo(&1, actor, work_request_id, params))
  end

  defp close_question(_grant, _work_request_id, _params), do: {:error, :not_found}

  defp record_decision(:local_operator, work_request_id, params)
       when is_binary(work_request_id) and is_map(params),
       do: {:error, :architect_control}

  defp record_decision(actor, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    SymppBoardLive.with_dashboard_repo(&record_decision_in_repo(&1, actor, work_request_id, params))
  end

  defp record_decision(_grant, _work_request_id, _params), do: {:error, :not_found}

  defp mark_human_info_needed(:local_operator, work_request_id)
       when is_binary(work_request_id),
       do: {:error, :architect_control}

  defp mark_human_info_needed(actor, work_request_id)
       when is_binary(work_request_id) do
    SymppBoardLive.with_dashboard_repo(&mark_human_info_needed_in_repo(&1, actor, work_request_id))
  end

  defp mark_human_info_needed(_grant, _work_request_id), do: {:error, :not_found}

  defp mark_ready_for_slicing(:local_operator, work_request_id)
       when is_binary(work_request_id),
       do: {:error, :architect_control}

  defp mark_ready_for_slicing(actor, work_request_id)
       when is_binary(work_request_id) do
    SymppBoardLive.with_dashboard_repo(&mark_ready_for_slicing_in_repo(&1, actor, work_request_id))
  end

  defp mark_ready_for_slicing(_grant, _work_request_id), do: {:error, :not_found}

  defp add_work_package(%AccessGrant{} = grant, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    form = work_package_form(params)
    attrs = work_package_attrs(form)

    case SymppBoardLive.with_dashboard_repo(&add_work_package_in_repo(&1, grant, work_request_id, attrs)) do
      {:ok, work_package} -> {:ok, work_package}
      {:error, reason} -> {:error, reason, form}
    end
  end

  defp add_work_package(:local_operator, work_request_id, params)
       when is_binary(work_request_id) and is_map(params),
       do: {:error, :architect_control, work_package_form(params)}

  defp add_work_package(_grant, _work_request_id, _params), do: {:error, :not_found, work_package_form()}

  defp skip_work_package(:local_operator, work_request_id, params)
       when is_binary(work_request_id) and is_map(params),
       do: {:error, :architect_control}

  defp skip_work_package(actor, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    SymppBoardLive.with_dashboard_repo(&skip_work_package_in_repo(&1, actor, work_request_id, params))
  end

  defp skip_work_package(_grant, _work_request_id, _params), do: {:error, :not_found}

  defp dispatch_work_package(:local_operator, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    with {:ok, work_package_id} <- filled_form_value(Map.get(params, "id"), :not_found) do
      SymppBoardLive.with_dashboard_repo(&dispatch_work_package_in_repo(&1, work_request_id, work_package_id))
    end
  end

  defp dispatch_work_package(_actor, _work_request_id, _params), do: {:error, :not_found}

  defp create_architect_handoff(:local_operator, work_request_id)
       when is_binary(work_request_id) do
    SymppBoardLive.with_dashboard_repo(fn repo ->
      ArchitectHandoff.create_or_replay(repo, work_request_id,
        local_operator?: true,
        handoff_opts: architect_handoff_opts(repo)
      )
    end)
  end

  defp create_architect_handoff(_actor, _work_request_id), do: {:error, :forbidden}

  defp mark_ready_in_repo(repo, %AccessGrant{} = grant, work_request_id) do
    with {:ok, scope} <- intake_scope(repo, grant),
         {:ok, work_request} <- WorkRequestService.get(repo, work_request_id),
         :ok <- work_request_in_scope?(work_request, scope),
         :ok <- visible_work_request?(repo, work_request, grant) do
      WorkRequestService.update_status(repo, work_request_id, "draft", "ready_for_clarification")
    end
  end

  defp mark_ready_in_repo(repo, :local_operator, work_request_id) do
    WorkRequestService.update_status(repo, work_request_id, "draft", "ready_for_clarification")
  end

  defp ask_question_in_repo(repo, actor, work_request_id, params) do
    with {:ok, work_request} <- scoped_work_request(repo, actor, work_request_id),
         :ok <- require_clarification_status(work_request.status),
         attrs <- question_attrs(params, actor) do
      ask_question_transaction(repo, work_request, attrs)
    end
  end

  defp answer_question_in_repo(repo, actor, work_request_id, params) do
    with {:ok, work_request} <- scoped_work_request(repo, actor, work_request_id),
         :ok <- require_clarification_status(work_request.status),
         {:ok, question} <- scoped_question(repo, work_request.id, Map.get(params, "id")),
         :ok <- require_open_question(question),
         {:ok, attrs} <- answer_attrs(params, actor, question) do
      WorkRequestService.answer_question(
        repo,
        question.id,
        Map.get(params, "current_status", ""),
        attrs
      )
    end
  end

  defp close_question_in_repo(repo, actor, work_request_id, params) do
    with {:ok, work_request} <- scoped_work_request(repo, actor, work_request_id),
         :ok <- require_clarification_status(work_request.status),
         {:ok, question} <- scoped_question(repo, work_request.id, Map.get(params, "id")) do
      WorkRequestService.close_question(repo, question.id, Map.get(params, "current_status", ""))
    end
  end

  defp record_decision_in_repo(repo, actor, work_request_id, params) do
    with {:ok, work_request} <- scoped_work_request(repo, actor, work_request_id),
         :ok <- require_clarification_status(work_request.status) do
      WorkRequestService.record_decision(repo, work_request.id, decision_attrs(params, actor))
    end
  end

  defp mark_human_info_needed_in_repo(repo, actor, work_request_id) do
    with {:ok, work_request} <- scoped_work_request(repo, actor, work_request_id),
         :ok <- require_status(work_request.status, ["ready_for_clarification", "clarifying"]) do
      WorkRequestService.update_status(
        repo,
        work_request.id,
        work_request.status,
        "human_info_needed"
      )
    end
  end

  defp mark_ready_for_slicing_in_repo(repo, actor, work_request_id) do
    with {:ok, work_request} <- scoped_work_request(repo, actor, work_request_id),
         :ok <-
           require_status(work_request.status, [
             "ready_for_clarification",
             "clarifying",
             "human_info_needed"
           ]) do
      mark_ready_for_slicing_transaction(repo, work_request)
    end
  end

  defp add_work_package_in_repo(repo, actor, work_request_id, attrs) do
    with {:ok, work_request} <- scoped_work_request(repo, actor, work_request_id) do
      case WorkRequestService.slice_work_request(repo, work_request.id, [attrs]) do
        {:ok, %{work_packages: [work_package]}} -> {:ok, work_package}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp skip_work_package_in_repo(repo, actor, work_request_id, params) do
    with {:ok, work_request} <- scoped_work_request(repo, actor, work_request_id),
         :ok <- require_work_package_authoring_status(work_request.status),
         {:ok, work_package} <- scoped_work_package(repo, work_request.id, Map.get(params, "id")) do
      WorkRequestService.skip_work_package(
        repo,
        work_request.id,
        work_package.id,
        Map.get(params, "current_status", "")
      )
    end
  end

  defp dispatch_work_package_in_repo(repo, work_request_id, work_package_id) do
    WorkPackageDispatch.dispatch(repo, work_request_id, work_package_id, dispatch_handoff_opts(repo))
  end

  defp ask_question_transaction(repo, work_request, attrs) do
    repo.transaction(fn ->
      with {:ok, work_request} <- transition_to_clarifying(repo, work_request),
           {:ok, question} <- WorkRequestService.ask_question(repo, work_request.id, attrs) do
        question
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp mark_ready_for_slicing_transaction(repo, work_request) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      work_request.id
      |> ready_for_slicing_update_query(work_request.status)
      |> repo.update_all(set: [status: "ready_for_slicing", updated_at: now])
      |> case do
        {1, _rows} -> repo.get!(WorkRequest, work_request.id)
        {0, _rows} -> repo.rollback(ready_for_slicing_blocker(repo, work_request))
      end
    end)
    |> normalize_transaction_result()
  end

  defp ready_for_slicing_update_query(work_request_id, current_status) do
    from(work_request in WorkRequest,
      where: work_request.id == ^work_request_id and work_request.status == ^current_status,
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1
            FROM sympp_work_request_clarification_questions AS question
            WHERE question.work_request_id = ? AND question.status = 'open'
          )
          """,
          work_request.id
        )
    )
  end

  defp ready_for_slicing_blocker(repo, work_request) do
    cond do
      open_questions?(repo, work_request.id) ->
        :open_questions

      stale_work_request_status?(repo, work_request) ->
        :stale_status

      true ->
        :not_found
    end
  end

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp scoped_work_request(repo, %AccessGrant{} = grant, work_request_id) do
    with {:ok, scope} <- intake_scope(repo, grant),
         {:ok, work_request} <- WorkRequestService.get(repo, work_request_id),
         :ok <- work_request_in_scope?(work_request, scope),
         :ok <- visible_work_request?(repo, work_request, grant) do
      {:ok, work_request}
    end
  end

  defp scoped_work_request(repo, :local_operator, work_request_id) do
    WorkRequestService.get(repo, work_request_id)
  end

  defp scoped_question(repo, work_request_id, question_id) when is_binary(question_id) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request_id) do
      case Enum.find(questions, &(&1.id == question_id)) do
        nil -> {:error, :not_found}
        question -> {:ok, question}
      end
    end
  end

  defp scoped_question(_repo, _work_request_id, _question_id), do: {:error, :not_found}

  defp scoped_work_package(repo, work_request_id, work_package_id) when is_binary(work_package_id) do
    with {:ok, work_packages} <- WorkRequestService.list_work_packages(repo, work_request_id) do
      case Enum.find(work_packages, &(&1.id == work_package_id)) do
        nil -> {:error, :not_found}
        work_package -> {:ok, work_package}
      end
    end
  end

  defp scoped_work_package(_repo, _work_request_id, _work_package_id), do: {:error, :not_found}

  defp transition_to_clarifying(repo, %{status: "ready_for_clarification"} = work_request) do
    WorkRequestService.update_status(
      repo,
      work_request.id,
      "ready_for_clarification",
      "clarifying"
    )
  end

  defp transition_to_clarifying(repo, %{status: status} = work_request)
       when status in ["clarifying", "human_info_needed"] do
    WorkRequestService.update_status(repo, work_request.id, status, status)
  end

  defp transition_to_clarifying(_repo, _work_request), do: {:error, :invalid_status}

  defp require_clarification_status(status),
    do: require_status(status, ["ready_for_clarification", "clarifying", "human_info_needed"])

  defp require_work_package_authoring_status(status),
    do: require_status(status, ["ready_for_slicing", "sliced"])

  defp require_status(status, allowed_statuses) do
    if status in allowed_statuses, do: :ok, else: {:error, :invalid_status}
  end

  defp require_open_question(%{status: "open"}), do: :ok
  defp require_open_question(%{status: "answered"}), do: {:error, :already_answered}
  defp require_open_question(%{status: "closed"}), do: {:error, :already_closed}
  defp require_open_question(_question), do: {:error, :invalid_status}

  defp open_questions?(repo, work_request_id) do
    case WorkRequestService.list_questions(repo, work_request_id) do
      {:ok, questions} -> Enum.any?(questions, &(&1.status == "open"))
      {:error, _reason} -> false
    end
  end

  defp stale_work_request_status?(repo, work_request) do
    case repo.get(WorkRequest, work_request.id) do
      %WorkRequest{status: status} -> status != work_request.status
      nil -> false
    end
  end

  defp visible_work_request?(repo, work_request, %AccessGrant{} = grant) do
    with {:ok, filters} <- Dashboard.work_request_filters_for_grant(repo, grant) do
      if work_request_matches_filters?(work_request, filters) do
        :ok
      else
        {:error, :not_found}
      end
    end
  end

  defp work_request_matches_filters?(work_request, filters) do
    Enum.all?(filters, fn
      {:repo, repo} when is_binary(repo) ->
        work_request.repo == repo

      {:base_branch, base_branch} when is_binary(base_branch) ->
        work_request.base_branch == base_branch

      _filter ->
        false
    end)
  end

  defp can_create_work_request?(%AccessGrant{} = grant),
    do: match?({:ok, _scope}, intake_scope(grant))

  defp can_create_work_request?(_grant), do: false

  defp can_create_work_request?(true, _grant), do: true
  defp can_create_work_request?(_operator_mode?, grant), do: can_create_work_request?(grant)

  defp intake_scope(%AccessGrant{} = grant) do
    case SymppBoardLive.with_dashboard_repo(&intake_scope(&1, grant)) do
      {:ok, scope} -> {:ok, scope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp intake_scope(repo, %AccessGrant{} = grant) do
    with {:ok, grant_scope} <- grant_frozen_scope(grant),
         {:ok, filters} <- Dashboard.work_request_filters_for_grant(repo, grant),
         {:ok, filter_scope} <- supported_intake_filter_scope(filters),
         :ok <- matching_intake_scopes?(grant_scope, filter_scope) do
      {:ok, grant_scope}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp work_request_in_scope?(work_request, %{repo: repo, base_branch: base_branch}) do
    if work_request.repo == repo and work_request.base_branch == base_branch do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp grant_frozen_scope(%AccessGrant{scope_repo: repo, scope_base_branch: base_branch}) do
    with {:ok, repo} <- locked_scope_value(repo),
         {:ok, base_branch} <- locked_scope_value(base_branch) do
      {:ok, %{repo: repo, base_branch: base_branch}}
    end
  end

  defp supported_intake_filter_scope(filters) when is_list(filters) do
    Enum.reduce_while(filters, {:ok, %{}}, fn
      {:repo, repo}, {:ok, scope} ->
        {:cont, {:ok, Map.put(scope, :repo, repo)}}

      {:base_branch, base_branch}, {:ok, scope} ->
        {:cont, {:ok, Map.put(scope, :base_branch, base_branch)}}

      _filter, _acc ->
        {:halt, {:error, :forbidden}}
    end)
    |> case do
      {:ok, %{repo: repo, base_branch: base_branch}} ->
        with {:ok, repo} <- locked_scope_value(repo),
             {:ok, base_branch} <- locked_scope_value(base_branch) do
          {:ok, %{repo: repo, base_branch: base_branch}}
        end

      {:ok, _scope} ->
        {:error, :forbidden}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp matching_intake_scopes?(scope, scope), do: :ok
  defp matching_intake_scopes?(_grant_scope, _filter_scope), do: {:error, :forbidden}

  defp locked_scope_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :forbidden}
      trimmed -> {:ok, trimmed}
    end
  end

  defp locked_scope_value(_value), do: {:error, :forbidden}

  if Mix.env() == :test do
    @doc false
    @spec __test_work_request_route(URI.t(), atom(), map(), String.t()) :: String.t()
    def __test_work_request_route(uri, action, params, work_request_id) do
      uri
      |> path_prefix(action, params)
      |> prefixed_path("/sympp/work-requests/#{path_segment(work_request_id)}")
    end
  end
end
