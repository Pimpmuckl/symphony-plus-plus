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
    Repository,
    Response,
    Session,
    SessionBindingTools,
    ToolCatalog
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @agent_text_mime_type "text/vnd.toon"
  @assignment_resource "sympp://assignment/current"
  @bootstrap_tools ToolCatalog.bootstrap_tools()
  @version_resource "sympp://health/version"

  @spec tool_specs_for_server(map()) :: {:ok, [map()]} | {:error, term()}
  def tool_specs_for_server(%{session_refresh_required: true, config: %Config{} = config} = server) do
    {:ok, effective_tool_specs(claimable_tool_specs(config), server)}
  end

  def tool_specs_for_server(%{config: %Config{} = config, session: session} = server) do
    surface_session = if(is_nil(session), do: {:ok, nil}, else: SessionBindingTools.tool_surface_session(server))

    with {:ok, session} <- surface_session,
         {:ok, specs} <- tool_specs_for_session(config, session) do
      {:ok, effective_tool_specs(specs, server)}
    end
  end

  @spec surface_revision(map()) :: {:ok, String.t()} | {:error, term()}
  def surface_revision(server) do
    with {:ok, specs} <- tool_specs_for_server(server) do
      revision = specs |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)
      {:ok, "sha256:" <> revision}
    end
  end

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

  defp tool_specs_for_session(%Config{} = config, nil) do
    {:ok, ToolCatalog.callable_unbound_tool_specs_for_config(config)}
  end

  defp tool_specs_for_session(%Config{repo: repo} = config, session) do
    with :ok <- Repository.ensure_migrated(repo) do
      session
      |> Auth.require_session(repo)
      |> tool_specs_for_session_result(config)
    end
  end

  defp tool_specs_for_session_result({:ok, %Session{assignment: %{grant_role: "architect"}} = session}, %Config{}) do
    {:ok, architect_session_tool_specs(session)}
  end

  defp tool_specs_for_session_result({:ok, %Session{assignment: %{grant_role: "worker"}} = session}, %Config{repo: repo}),
    do: {:ok, worker_session_tool_specs(repo, session)}

  defp tool_specs_for_session_result({:ok, %Session{}}, %Config{}), do: {:error, {:unauthorized, :unsupported_grant_role}}

  defp tool_specs_for_session_result({:error, {:service_unavailable, _reason} = reason}, %Config{}), do: {:error, reason}

  defp tool_specs_for_session_result({:error, _reason}, %Config{} = config) do
    {:ok, claimable_tool_specs(config)}
  end

  defp claimable_tool_specs(%Config{} = config), do: ToolCatalog.callable_claim_tool_specs(config)

  defp architect_session_tool_specs(%Session{} = session) do
    ToolCatalog.architect_session_tool_specs(current_work_request?: CurrentWorkRequest.single_scope?(session))
  end

  defp worker_session_tool_specs(repo, %Session{} = session) do
    ToolCatalog.worker_session_tool_specs()
    |> maybe_advertise_compact_attach_branch(repo, session)
  end

  defp maybe_advertise_compact_attach_branch(specs, repo, %Session{} = session) do
    if compact_attach_branch_available?(repo, session) do
      map_tool_spec(specs, "attach_branch", &put_in(&1, ["inputSchema", "required"], ["head_sha"]))
    else
      specs
    end
  end

  defp compact_attach_branch_available?(repo, %Session{} = session) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, Session.work_package_id(session)),
         branch when is_binary(branch) <- normalize_optional_value(work_package.branch_pattern) do
      not local_branch_template_pattern?(branch)
    else
      _missing_or_template -> false
    end
  end

  defp map_tool_spec(specs, name, fun) do
    Enum.map(specs, fn
      %{"name" => ^name} = spec -> fun.(spec)
      spec -> spec
    end)
  end

  defp effective_tool_specs(specs, server) do
    specs
    |> role_scoped_claim_tool_specs(server)
    |> advertised_tool_specs(server)
    |> Kernel.++(local_trusted_tool_specs(server))
    |> Enum.filter(&(&1["name"] in profile_tool_names(server.config.surface_profile)))
    |> dedupe_tool_specs()
    |> ToolCatalog.lean_tool_specs()
  end

  defp advertised_tool_specs(specs, %{session: nil, session_refresh_required: false} = server) do
    if local_trusted_tools_enabled?(server), do: specs, else: hide_trusted_local_tool_specs(specs)
  end

  defp advertised_tool_specs(specs, _server), do: hide_trusted_local_tool_specs(specs)

  defp hide_trusted_local_tool_specs(specs), do: Enum.reject(specs, &(&1["name"] in @bootstrap_tools))

  defp dedupe_tool_specs(specs) do
    Enum.uniq_by(specs, & &1["name"])
  end

  defp role_scoped_claim_tool_specs(specs, server) do
    case assignment_role(server) do
      role when role in ["worker", "architect"] ->
        claim_tool =
          if role == "worker",
            do: ToolCatalog.local_assignment_claim_tool(),
            else: ToolCatalog.local_architect_assignment_claim_tool()

        claim_spec =
          server.config
          |> ToolCatalog.callable_claim_tool_specs()
          |> Enum.find(&(&1["name"] == claim_tool))

        specs
        |> Enum.reject(&(&1["name"] in ToolCatalog.session_claim_tools()))
        |> maybe_prepend_tool_spec(claim_spec)

      _unbound ->
        specs
    end
  end

  defp assignment_role(%{session: %Session{assignment: %{grant_role: role}}}), do: role
  defp assignment_role(%{stale_assignment_role: role}), do: role
  defp assignment_role(_server), do: nil

  defp maybe_prepend_tool_spec(specs, nil), do: specs
  defp maybe_prepend_tool_spec(specs, spec), do: [spec | specs]

  defp local_trusted_tool_specs(
         %{
           session: nil,
           session_refresh_required: false,
           config: %Config{surface_profile: :full}
         } = server
       ) do
    if local_trusted_tools_enabled?(server) do
      LocalTrustedTools.tool_specs(server.config)
    else
      []
    end
  end

  defp local_trusted_tool_specs(_server), do: []

  defp profile_tool_names(:full), do: ToolCatalog.known_tools()

  defp profile_tool_names(:worker) do
    [
      ToolCatalog.health_tool(),
      ToolCatalog.assignment_release_tool(),
      ToolCatalog.local_assignment_claim_tool()
      | ToolCatalog.worker_tools()
    ]
  end

  defp profile_tool_names(:architect) do
    [
      ToolCatalog.health_tool(),
      ToolCatalog.assignment_release_tool(),
      "get_current_assignment",
      ToolCatalog.local_architect_assignment_claim_tool()
      | ToolCatalog.bootstrap_tools() ++ ToolCatalog.local_operator_tools() ++ ToolCatalog.architect_tools()
    ]
  end

  defp profile_tool_names(profile) when profile in [:coordinator, :solo] do
    [ToolCatalog.health_tool(), ToolCatalog.assignment_release_tool(), "get_current_assignment" | ToolCatalog.solo_tools()]
  end

  defp valid_resource_path?(resource_path) when is_binary(resource_path) do
    String.trim(resource_path) != "" and not String.contains?(resource_path, "/")
  end

  defp assignment_resources(nil, _repo), do: {:ok, []}

  defp assignment_resources(%Session{} = session, repo) do
    case Auth.require_session(session, repo) do
      {:ok, %Session{} = session} ->
        assignment_resources_for_session(session)

      {:error, {:service_unavailable, reason}} ->
        service_error(reason, @assignment_resource)

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp assignment_resources(_session, _repo), do: {:ok, []}

  defp assignment_resources_for_session(%Session{assignment: %{grant_role: "worker"}} = session) do
    case require_worker_assignment(session.assignment) do
      :ok -> listed_assignment_resources(session)
      {:error, _reason} -> {:ok, []}
    end
  end

  defp assignment_resources_for_session(%Session{assignment: %{grant_role: "architect"}} = session) do
    case require_assignment_introspection(session.assignment) do
      :ok -> listed_current_assignment_resource(session)
      {:error, _reason} -> {:ok, []}
    end
  end

  defp assignment_resources_for_session(%Session{}), do: {:ok, []}

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

  defp local_branch_template_pattern?(pattern) when is_binary(pattern) do
    Regex.match?(~r/\{\{\s*[a-zA-Z0-9_]+\s*\}\}/, pattern)
  end

  defp normalize_optional_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_value(nil), do: nil

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
