defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Surface do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.ActorResolver
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Auth,
    Config,
    CurrentWorkRequest,
    LocalTrustedTools,
    Response,
    Session,
    ToolCatalog,
    WorkRequestScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  @agent_text_mime_type "text/vnd.toon"
  @assignment_resource "sympp://assignment/current"
  @version_resource "sympp://health/version"

  @spec tool_specs_for_server(map()) :: {:ok, [map()]} | {:error, term()}
  def tool_specs_for_server(%{
        config: %Config{surface_profile: :full} = config,
        session: %Session{assignment: %{grant_role: "architect"}}
      }) do
    architect_tools =
      ToolCatalog.startup_tool_specs(:architect, config)
      |> Map.new(&{&1["name"], &1})

    worker_only_tools = ToolCatalog.worker_tools() -- (["get_current_assignment"] ++ ToolCatalog.architect_tools())
    rejected_tools = ToolCatalog.solo_tools() ++ [ToolCatalog.local_assignment_claim_tool()] ++ worker_only_tools
    architect_schema_overrides = ["attach_branch", "sync_pr"] ++ ToolCatalog.architect_planning_tools()

    tools =
      :full
      |> ToolCatalog.startup_tool_specs(config)
      |> Enum.reject(&(&1["name"] in rejected_tools))
      |> Enum.map(fn %{"name" => name} = tool ->
        if name in architect_schema_overrides, do: Map.get(architect_tools, name, tool), else: tool
      end)

    {:ok, tools}
  end

  def tool_specs_for_server(%{config: %Config{} = config}),
    do: {:ok, ToolCatalog.startup_tool_specs(config.surface_profile, config)}

  @spec local_trusted_tools_enabled?(map()) :: boolean()
  def local_trusted_tools_enabled?(server), do: LocalTrustedTools.enabled?(server)

  @spec resource_specs_for_session(Session.t() | nil | term(), module()) ::
          {:ok, [map()]} | {:error, integer(), String.t(), map()}
  def resource_specs_for_session(session, repo) do
    with {:ok, resources} <- assignment_resources(session, repo) do
      {:ok, base_resource_specs() ++ resources}
    end
  end

  @spec work_package_resource_id(binary()) :: {:ok, String.t(), String.t()} | :error
  def work_package_resource_id(rest) when is_binary(rest) do
    case String.split(rest, "/", parts: 2) do
      [work_package_id, resource_path] ->
        if String.trim(work_package_id) != "" and valid_resource_path?(resource_path) do
          {:ok, work_package_id, resource_path}
        else
          :error
        end

      _parts ->
        :error
    end
  end

  @spec read_work_package_virtual_resource(
          module(),
          Session.t() | nil | term(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, integer(), String.t(), map()}
  def read_work_package_virtual_resource(repo, session, work_package_id, file_name, uri, opts \\ []) do
    resource_type = resource_type_for_virtual_file(file_name)
    action = action_for_virtual_file(file_name)

    with {:ok, session} <- Auth.require_session(session, repo),
         {:ok, actor} <- actor_for_package_resource(repo, session, resource_type, work_package_id),
         :ok <- PlanningService.authorize_package_action(repo, actor, action, work_package_id, resource_type) do
      read_virtual_resource(
        repo,
        work_package_id,
        file_name,
        uri,
        agent_text?: worker_session?(session),
        canonical_agent_text?: Keyword.get(opts, :mode, :stdio) == :http or Keyword.get(opts, :surface_profile, :full) != :full
      )
    else
      {:error, {:authorization_policy_denied, %Decision{} = decision}} -> MCPError.from_decision(decision, uri)
      {:error, reason} -> auth_error(reason, uri)
    end
  end

  defp valid_resource_path?(resource_path) when is_binary(resource_path) do
    String.trim(resource_path) != "" and not String.contains?(resource_path, "/")
  end

  defp assignment_resources(nil, _repo), do: {:ok, []}

  defp assignment_resources(%Session{} = session, repo) do
    case Auth.require_session(session, repo) do
      {:ok, %Session{} = session} ->
        assignment_resources_for_session(session, repo)

      {:error, {:service_unavailable, reason}} ->
        service_error(reason, @assignment_resource)

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp assignment_resources(_session, _repo), do: {:ok, []}

  defp assignment_resources_for_session(%Session{assignment: %{grant_role: "worker"}} = session, _repo) do
    case require_worker_assignment(session.assignment) do
      :ok -> listed_assignment_resources(session)
      {:error, _reason} -> {:ok, []}
    end
  end

  defp assignment_resources_for_session(%Session{assignment: %{grant_role: "architect"}} = session, repo) do
    case require_assignment_introspection(session.assignment) do
      :ok -> listed_architect_resources(repo, session)
      {:error, _reason} -> {:ok, []}
    end
  end

  defp assignment_resources_for_session(%Session{}, _repo), do: {:ok, []}

  defp listed_architect_resources(repo, %Session{} = session) do
    with {:ok, work_request_id} <- CurrentWorkRequest.id_argument(%{}, session),
         {:ok, _work_request, _filters, _scope} <-
           WorkRequestScope.authorized_work_request_scope(repo, session, work_request_id, :work_request_read, "resources/list"),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(repo, work_request_id),
         {:ok, current} <- listed_current_assignment_resource(session) do
      {:ok, current ++ Enum.flat_map(work_packages, &work_package_resources(&1.id))}
    else
      _reason -> listed_current_assignment_resource(session)
    end
  end

  defp listed_assignment_resources(%Session{} = session) do
    work_package_id = Session.work_package_id(session)

    with {:ok, assignment_resources} <- listed_current_assignment_resource(session) do
      {:ok, assignment_resources ++ work_package_resources(work_package_id)}
    end
  end

  defp listed_current_assignment_resource(%Session{}) do
    {:ok, current_assignment_resource_specs()}
  end

  defp work_package_resources(work_package_id) do
    Enum.map(PlanningRenderer.virtual_files(), fn file_name ->
      %{
        "uri" => "sympp://work-packages/#{work_package_id}/#{file_name}",
        "name" => file_name,
        "mimeType" => "text/markdown"
      }
    end)
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

  defp read_virtual_resource(repo, work_package_id, file_name, uri, opts) do
    with true <- file_name in PlanningRenderer.virtual_files(),
         {:ok, state} <- PlanningRepository.get_render_state(repo, work_package_id),
         {:ok, markdown} <- PlanningRenderer.render_state(state, file_name),
         {:ok, resource} <- virtual_resource_result(uri, markdown, state, file_name, opts) do
      {:ok, resource}
    else
      false -> {:error, -32_601, "Method not found", %{"resource" => uri, "reason" => "unknown_virtual_file"}}
      {:error, reason} -> service_error(reason, uri)
    end
  end

  defp virtual_resource_result(uri, markdown, state, file_name, opts) do
    if Keyword.get(opts, :agent_text?, false) do
      with {:ok, toon} <- WorkerContext.encode_virtual_file(state, file_name, uri: uri) do
        {:ok, agent_text_resource(uri, markdown, toon, Keyword.get(opts, :canonical_agent_text?, false))}
      end
    else
      {:ok, Response.text_resource(uri, markdown, "text/markdown")}
    end
  end

  defp agent_text_resource(uri, _markdown, toon, true), do: Response.text_resource(uri, toon, @agent_text_mime_type)

  defp agent_text_resource(uri, markdown, toon, false),
    do: Response.agent_text_resource(uri, markdown, toon, "text/markdown", @agent_text_mime_type)

  defp actor_for_package_resource(repo, %Session{} = session, resource_type, work_package_id) do
    with {:ok, target} <- PlanningService.package_resource_target(repo, work_package_id, resource_type) do
      ActorResolver.from_session(session, PlanningService.package_surface_actor_opts(session.assignment, target))
    end
  end

  defp action_for_virtual_file("task_plan.md"), do: :task_plan_read
  defp action_for_virtual_file(_file_name), do: :work_package_read

  defp resource_type_for_virtual_file("task_plan.md"), do: :task_plan
  defp resource_type_for_virtual_file("findings.md"), do: :finding
  defp resource_type_for_virtual_file("progress.md"), do: :progress
  defp resource_type_for_virtual_file("review.md"), do: :review_evidence
  defp resource_type_for_virtual_file(_file_name), do: :work_package

  defp worker_session?(%Session{assignment: %{grant_role: "worker"}}), do: true
  defp worker_session?(%Session{}), do: false

  defp require_worker_assignment(%{grant_role: "worker"}), do: :ok
  defp require_worker_assignment(_assignment), do: {:error, :worker_grant_required}

  defp require_assignment_introspection(%{grant_role: role}) when role in ["worker", "architect"], do: :ok
  defp require_assignment_introspection(_assignment), do: {:error, :unsupported_grant_role}

  defp auth_error(:unauthorized, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  end

  defp auth_error({:unauthorized, reason}, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  end

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)

  defp service_error(_reason, resource) do
    {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
end
