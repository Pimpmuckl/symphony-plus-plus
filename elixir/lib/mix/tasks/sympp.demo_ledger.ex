defmodule Mix.Tasks.Sympp.DemoLedger do
  @moduledoc """
  Creates a deterministic local Symphony++ operator demo ledger.

      mix sympp.demo_ledger --database <sqlite-path> [--scenario <name>] [--force]
  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Repository, as: GuidanceRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.DependencyEdge
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository, as: ProductTreeRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloRepository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.Workflow

  @shortdoc "Creates a deterministic local Symphony++ operator demo ledger"
  @board_path "/sympp/board"
  @demo_repo "nextide/demo-operator"
  @demo_base_branch "main"
  @demo_now ~U[2026-01-02 03:04:05.000000Z]
  @scenarios ~w(simple multi-repo superseded large)
  @switches [
    database: :string,
    force: :boolean,
    help: :boolean,
    scenario: :string
  ]

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      :help ->
        Mix.shell().info(usage())

      {:ok, opts} ->
        run_demo_ledger(opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @spec usage() :: String.t()
  def usage do
    [
      "Usage: mix sympp.demo_ledger --database <sqlite-path> [--scenario <name>] [--force]",
      "",
      "Creates a deterministic, synthetic local operator ledger for cockpit visual QA.",
      "Scenarios: #{Enum.join(@scenarios, ", ")}. Defaults to simple.",
      "Fails when the database already exists unless --force is provided."
    ]
    |> Enum.join("\n")
  end

  @doc false
  @spec parse_args_for_test([String.t()]) :: :help | {:ok, keyword()} | {:error, String.t()}
  def parse_args_for_test(args), do: parse_args(args)

  @doc false
  @spec database_path_for_test(String.t()) :: String.t()
  def database_path_for_test(database), do: resolved_database(database)

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> validate_opts(opts)
      {_opts, _argv, _invalid} -> {:error, usage()}
    end
  end

  defp validate_opts(opts) do
    cond do
      Keyword.get(opts, :help, false) ->
        :help

      blank?(Keyword.get(opts, :database)) ->
        {:error, usage()}

      has_blank_option?(opts, [:database]) ->
        {:error, usage()}

      Keyword.get(opts, :scenario, "simple") not in @scenarios ->
        {:error, usage()}

      true ->
        {:ok, opts |> Keyword.put_new(:force, false) |> Keyword.put_new(:scenario, "simple")}
    end
  end

  defp run_demo_ledger(opts) do
    database = resolved_database(Keyword.fetch!(opts, :database))
    force? = Keyword.get(opts, :force, false)
    scenario = Keyword.fetch!(opts, :scenario)

    with :ok <- prepare_database(database, force?),
         {:ok, payload} <- seed_database(database, scenario) do
      payload
      |> Jason.encode!(pretty: true)
      |> Mix.shell().info()
    else
      {:error, reason} -> Mix.raise(error_message(reason))
    end
  end

  defp prepare_database(database, force?) do
    cond do
      not Repo.filesystem_database_path?(database) ->
        {:error, :unsupported_database}

      File.exists?(database) and not force? ->
        {:error, {:database_exists, database}}

      File.exists?(database) ->
        remove_existing_database(database)

      true ->
        :ok
    end
  end

  defp remove_existing_database(database) do
    [database, database <> "-shm", database <> "-wal", database <> "-journal"]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case remove_existing_file(path, 100) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp remove_existing_file(path, attempts_left) do
    cond do
      not File.exists?(path) ->
        :ok

      attempts_left <= 0 ->
        remove_file_once(path)

      true ->
        case File.rm(path) do
          :ok ->
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} when reason in [:eacces, :eperm] ->
            Process.sleep(50)
            remove_existing_file(path, attempts_left - 1)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp remove_file_once(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_database(database, scenario) do
    original_repo = Repo.get_dynamic_repo()

    case start_repo(database) do
      {:ok, repo_pid} ->
        try do
          case migrate_repositories() do
            :ok -> seed_demo_records(database, scenario)
            {:error, reason} -> {:error, reason}
          end
        after
          stop_repo(repo_pid)
          Repo.put_dynamic_repo(original_repo)
        end

      {:error, reason} ->
        Repo.put_dynamic_repo(original_repo)
        {:error, reason}
    end
  end

  defp migrate_repositories do
    case WorkPackageRepository.migrate(Repo) do
      :ok -> SoloRepository.migrate(Repo)
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_demo_records(database, scenario) do
    Repo.transaction(fn ->
      with {:ok, work_requests} <- seed_work_requests(),
           {:ok, work_packages} <- seed_work_packages(),
           {:ok, guidance_requests} <- seed_human_decision_prompts(),
           {:ok, comments} <- seed_comments(),
           {:ok, _evidence} <- seed_work_package_evidence(),
           {:ok, solo_sessions} <- seed_solo_sessions(),
           {:ok, scenario_records} <- seed_scenario(scenario),
           {_, nil} <- normalize_demo_timestamps() do
        %{
          "database" => database,
          "cockpit_hint" => "mix sympp.cockpit --database #{quote_cli_arg(database)}",
          "cockpit_path" => @board_path,
          "scenario" => scenario,
          "seed" => %{
            "work_requests" => Enum.map(work_requests, & &1.id) ++ scenario_records.work_request_ids,
            "guidance_requests" => Enum.map(guidance_requests, & &1.id),
            "work_packages" => Enum.map(work_packages, & &1.id) ++ scenario_records.work_package_ids,
            "comments" => Enum.map(comments, & &1.id),
            "solo_sessions" => Enum.map(solo_sessions, & &1.id)
          }
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp seed_scenario("simple"), do: {:ok, %{work_request_ids: [], work_package_ids: []}}

  defp seed_scenario(scenario) do
    with {:ok, work_requests} <-
           scenario |> scenario_work_request_specs() |> insert_all(&create_scenario_work_request/1),
         {:ok, work_packages} <-
           scenario |> scenario_work_package_specs() |> insert_all(&create_scenario_work_package/1),
         {:ok, _edges} <- scenario |> scenario_dependency_specs() |> insert_all(&create_scenario_dependency/1),
         {:ok, _deliveries} <- scenario |> scenario_delivery_specs() |> insert_all(&create_scenario_delivery/1) do
      {:ok, %{work_request_ids: Enum.map(work_requests, & &1.id), work_package_ids: Enum.map(work_packages, & &1.id)}}
    end
  end

  defp scenario_work_request_specs("multi-repo") do
    repos = ~w(nextide/demo-contracts nextide/demo-api nextide/demo-web nextide/demo-worker)
    [{"SYMPP-DEMO-WR-MULTI", "Fan out one release across repositories", hd(repos), repos}]
  end

  defp scenario_work_request_specs("superseded"),
    do: [{"SYMPP-DEMO-WR-SUPERSEDED", "Recut superseded and skipped work", @demo_repo}]

  defp scenario_work_request_specs("large"),
    do: [{"SYMPP-DEMO-WR-LARGE", "Render a large execution graph", @demo_repo}]

  defp scenario_work_package_specs("multi-repo") do
    [
      {"SYMPP-DEMO-WP-MULTI-CONTRACT", "SYMPP-DEMO-WR-MULTI", 1, "Publish shared contract", "merged", "nextide/demo-contracts"},
      {"SYMPP-DEMO-WP-MULTI-API", "SYMPP-DEMO-WR-MULTI", 2, "Adopt contract in API", "ready_for_worker", "nextide/demo-api"},
      {"SYMPP-DEMO-WP-MULTI-WEB", "SYMPP-DEMO-WR-MULTI", 3, "Adopt contract in web", "implementing", "nextide/demo-web"},
      {"SYMPP-DEMO-WP-MULTI-WORKER", "SYMPP-DEMO-WR-MULTI", 4, "Adopt contract in worker", "planning", "nextide/demo-worker"}
    ]
  end

  defp scenario_work_package_specs("superseded") do
    [
      {"SYMPP-DEMO-WP-OLD", "SYMPP-DEMO-WR-SUPERSEDED", 1, "Original broad package", "closed", @demo_repo},
      {"SYMPP-DEMO-WP-REPLACEMENT", "SYMPP-DEMO-WR-SUPERSEDED", 2, "Narrow replacement package", "ready_for_worker", @demo_repo},
      {"SYMPP-DEMO-WP-DEFERRED-SKIP", "SYMPP-DEMO-WR-SUPERSEDED", 3, "Skipped speculative follow-up", "skipped", @demo_repo}
    ]
  end

  defp scenario_work_package_specs("large") do
    for index <- 1..30 do
      id = large_package_id(index)
      status = Enum.at(["merged", "implementing", "ready_for_worker", "planning"], rem(index - 1, 4))
      {id, "SYMPP-DEMO-WR-LARGE", index, "Execution graph package #{index}", status, @demo_repo}
    end
  end

  defp scenario_dependency_specs("multi-repo") do
    for suffix <- ~w(API WEB WORKER) do
      {"SYMPP-DEMO-WR-MULTI", "SYMPP-DEMO-WP-MULTI-#{suffix}", "SYMPP-DEMO-WP-MULTI-CONTRACT"}
    end
  end

  defp scenario_dependency_specs("superseded") do
    [{"SYMPP-DEMO-WR-SUPERSEDED", "SYMPP-DEMO-WP-REPLACEMENT", "SYMPP-DEMO-WP-OLD", "recut_from"}]
  end

  defp scenario_dependency_specs("large") do
    chain = for index <- 2..30, do: {"SYMPP-DEMO-WR-LARGE", large_package_id(index), large_package_id(index - 1)}
    joins = for index <- 6..30//3, do: {"SYMPP-DEMO-WR-LARGE", large_package_id(index), large_package_id(index - 4)}
    chain ++ joins
  end

  defp scenario_delivery_specs("superseded") do
    [{"SYMPP-DEMO-WR-SUPERSEDED", "SYMPP-DEMO-WP-OLD", "SYMPP-DEMO-WP-REPLACEMENT"}]
  end

  defp scenario_delivery_specs(_scenario), do: []

  defp create_scenario_work_request({id, title, repo}) do
    create_scenario_work_request({id, title, repo, [repo]})
  end

  defp create_scenario_work_request({id, title, repo, repos}) do
    id
    |> work_request_attrs(title, "sliced", "feature", "architect_led_feature_branch")
    |> Map.put(:repo, repo)
    |> Map.put(:repo_scopes, Enum.map(repos, &%{repo: &1, base_branch: @demo_base_branch}))
    |> then(&WorkRequestRepository.create(Repo, &1))
  end

  defp create_scenario_work_package({id, work_request_id, sequence, title, status, repo}) do
    WorkPackageRepository.create(Repo, %{
      id: id,
      work_request_id: work_request_id,
      sequence: sequence,
      kind: "standard_pr",
      title: title,
      goal: "#{title}. Synthetic WorkPackage for demo ledger visual QA.",
      repo: repo,
      base_branch: @demo_base_branch,
      branch_pattern: "feat/#{String.downcase(id)}/demo",
      product_description: work_request_description(title),
      engineering_scope: "Exercise scenario rendering with deterministic non-secret data.",
      allowed_file_globs: ["demo/**"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "fast"}},
      acceptance_criteria: acceptance_criteria(title),
      status: status,
      dispatched_at: if(status in ["planned", "skipped"], do: nil, else: @demo_now),
      owner_id: "local-demo-worker"
    })
  end

  defp create_scenario_dependency({work_request_id, dependent_id, prerequisite_id}),
    do: create_scenario_dependency({work_request_id, dependent_id, prerequisite_id, "depends_on"})

  defp create_scenario_dependency({work_request_id, dependent_id, prerequisite_id, kind}) do
    ProductTreeRepository.create_dependency_edge(Repo, %{
      id: "SYMPP-DEMO-EDGE-#{dependent_id}-#{prerequisite_id}",
      work_request_id: work_request_id,
      source_kind: "work_package",
      source_id: dependent_id,
      target_kind: "work_package",
      target_id: prerequisite_id,
      kind: kind,
      reason: "Synthetic #{kind} relationship for repeatable visual QA.",
      created_by: "demo-operator",
      created_at: @demo_now
    })
  end

  defp create_scenario_delivery({work_request_id, work_package_id, successor_id}) do
    WorkRequestRepository.record_work_package_delivery(Repo, work_request_id, work_package_id, %{
      outcome: "superseded",
      idempotency_key: "demo-superseded-delivery",
      recorded_by: "demo-operator",
      successor_work_package_id: successor_id,
      superseded_reason: "Synthetic broad package was recut into a narrower successor."
    })
  end

  defp large_package_id(index), do: "SYMPP-DEMO-WP-LARGE-#{String.pad_leading(to_string(index), 2, "0")}"

  defp seed_work_requests do
    [
      work_request_attrs("SYMPP-DEMO-WR-CLARIFY", "Clarify cockpit onboarding copy", "clarifying", "docs", "single_package"),
      work_request_attrs("SYMPP-DEMO-WR-HUMAN", "Resolve package ownership question", "human_info_needed", "feature", "architect_led_feature_branch"),
      work_request_attrs("SYMPP-DEMO-WR-SLICING", "Plan dashboard visual QA sweep", "ready_for_slicing", "investigation", "investigation_first"),
      work_request_attrs("SYMPP-DEMO-WR-SLICED", "Ship operator cockpit polish", "sliced", "feature", "architect_led_feature_branch"),
      work_request_attrs("SYMPP-DEMO-WR-LIFECYCLE", "Coordinate package-to-merge lifecycle", "sliced", "feature", "architect_led_feature_branch")
    ]
    |> insert_all(&WorkRequestRepository.create(Repo, &1))
  end

  defp work_request_attrs(id, title, status, work_type, dispatch_shape) do
    %{
      id: id,
      title: title,
      repo: @demo_repo,
      base_branch: @demo_base_branch,
      work_type: work_type,
      human_description: work_request_description(title),
      constraints: %{
        "allowed_paths" => ["elixir/lib/**", "docs/**"],
        "forbidden_paths" => [".env", "secrets/**"],
        "compatibility_stance" => "Clarify before assuming backward compatibility.",
        "synthetic_demo" => true
      },
      desired_dispatch_shape: dispatch_shape,
      status: status
    }
  end

  defp seed_work_packages do
    [
      work_package_attrs("SYMPP-DEMO-WP-PLANNED", "Planned cockpit filter package", "planned", "mcp"),
      work_package_attrs("SYMPP-DEMO-WP-SKIPPED", "Skipped broad redesign package", "skipped", "mcp"),
      work_package_attrs("SYMPP-DEMO-WP-ACTIVE", "Implement cockpit status filters", "implementing", kind("SYMPP-DEMO-WP-ACTIVE")),
      work_package_attrs("SYMPP-DEMO-WP-QUEUED", "Prepare worker handoff slice", "ready_for_worker", kind("SYMPP-DEMO-WP-QUEUED")),
      work_package_attrs("SYMPP-DEMO-WP-PLANNING", "Plan API bridge smoke coverage", "planning", kind("SYMPP-DEMO-WP-PLANNING")),
      work_package_attrs("SYMPP-DEMO-WP-REVIEW", "Review local operator handoff copy", "reviewing", kind("SYMPP-DEMO-WP-REVIEW")),
      work_package_attrs("SYMPP-DEMO-WP-CI", "Wait for cockpit CI package", "ci_waiting", kind("SYMPP-DEMO-WP-CI")),
      work_package_attrs("SYMPP-DEMO-WP-READY", "Ready merge evidence package", "ready_for_merge", kind("SYMPP-DEMO-WP-READY")),
      work_package_attrs("SYMPP-DEMO-WP-ARCH-READY", "Architect merge approval package", "ready_for_architect_merge", kind("SYMPP-DEMO-WP-ARCH-READY")),
      work_package_attrs("SYMPP-DEMO-WP-BLOCKED", "Blocked product decision package", "blocked", kind("SYMPP-DEMO-WP-BLOCKED")),
      work_package_attrs("SYMPP-DEMO-WP-MERGED", "Merged demo cleanup package", "merged", kind("SYMPP-DEMO-WP-MERGED")),
      work_package_attrs("SYMPP-DEMO-WP-MERGED-DOCS", "Merged operator docs package", "merged", kind("SYMPP-DEMO-WP-MERGED-DOCS")),
      work_package_attrs("SYMPP-DEMO-WP-CLOSED-SPIKE", "Closed duplicate telemetry spike", "closed", kind("SYMPP-DEMO-WP-CLOSED-SPIKE"))
    ]
    |> insert_all(&WorkPackageRepository.create(Repo, &1))
  end

  defp seed_comments do
    [
      demo_comment_attrs(
        "SYMPP-DEMO-COMMENT-WR-SLICED",
        "work_request",
        "SYMPP-DEMO-WR-SLICED",
        "Demo unresolved comment on the WorkRequest card action row."
      ),
      demo_comment_attrs(
        "SYMPP-DEMO-COMMENT-WP-ACTIVE",
        "work_package",
        "SYMPP-DEMO-WP-ACTIVE",
        "Demo unresolved comment on a WorkPackage card."
      )
    ]
    |> insert_all(&CommentService.create(Repo, &1))
  end

  defp demo_comment_attrs(id, target_kind, target_id, body) do
    %{
      id: id,
      target_kind: target_kind,
      target_id: target_id,
      body: body,
      source_type: "operator",
      author_name: "demo-operator"
    }
  end

  defp work_package_attrs(id, title, status, kind) do
    %{
      id: id,
      work_request_id: work_request_id(id),
      sequence: work_package_sequence(id),
      kind: kind,
      title: title,
      goal: "#{title}. Synthetic WorkPackage for demo ledger visual QA.",
      repo: @demo_repo,
      base_branch: @demo_base_branch,
      branch_pattern: branch_pattern(id),
      product_description: product_description(id),
      engineering_scope: "Exercise board/detail rendering with deterministic non-secret data.",
      allowed_file_globs: allowed_file_globs(id),
      review_requirement: review_requirement(id),
      acceptance_criteria: acceptance_criteria(title),
      status: status,
      dispatched_at: if(status in ["planned", "skipped"], do: nil, else: @demo_now),
      parent_id: nil,
      phase_id: nil,
      owner_id: "local-demo-worker"
    }
  end

  defp work_request_description(title), do: "#{title}. Synthetic local demo data only."

  defp work_request_id(id) when id in ["SYMPP-DEMO-WP-PLANNED", "SYMPP-DEMO-WP-SKIPPED"], do: "SYMPP-DEMO-WR-SLICING"
  defp work_request_id("SYMPP-DEMO-WP-ACTIVE"), do: "SYMPP-DEMO-WR-SLICED"
  defp work_request_id("SYMPP-DEMO-WP-BLOCKED"), do: "SYMPP-DEMO-WR-HUMAN"
  defp work_request_id(_id), do: "SYMPP-DEMO-WR-LIFECYCLE"

  defp work_package_sequence("SYMPP-DEMO-WP-PLANNED"), do: 1
  defp work_package_sequence("SYMPP-DEMO-WP-SKIPPED"), do: 2
  defp work_package_sequence("SYMPP-DEMO-WP-ACTIVE"), do: 1
  defp work_package_sequence("SYMPP-DEMO-WP-BLOCKED"), do: 1

  defp work_package_sequence(id) do
    [
      "SYMPP-DEMO-WP-QUEUED",
      "SYMPP-DEMO-WP-PLANNING",
      "SYMPP-DEMO-WP-REVIEW",
      "SYMPP-DEMO-WP-CI",
      "SYMPP-DEMO-WP-READY",
      "SYMPP-DEMO-WP-ARCH-READY",
      "SYMPP-DEMO-WP-MERGED",
      "SYMPP-DEMO-WP-MERGED-DOCS",
      "SYMPP-DEMO-WP-CLOSED-SPIKE"
    ]
    |> Enum.find_index(&(&1 == id))
    |> then(&(&1 + 1))
  end

  defp product_description("SYMPP-DEMO-WP-ACTIVE"), do: work_request_description("Ship operator cockpit polish")
  defp product_description("SYMPP-DEMO-WP-BLOCKED"), do: work_request_description("Resolve package ownership question")

  defp product_description(id)
       when id in [
              "SYMPP-DEMO-WP-QUEUED",
              "SYMPP-DEMO-WP-PLANNING",
              "SYMPP-DEMO-WP-REVIEW",
              "SYMPP-DEMO-WP-CI",
              "SYMPP-DEMO-WP-READY",
              "SYMPP-DEMO-WP-ARCH-READY",
              "SYMPP-DEMO-WP-MERGED",
              "SYMPP-DEMO-WP-MERGED-DOCS",
              "SYMPP-DEMO-WP-CLOSED-SPIKE"
            ],
       do: work_request_description("Coordinate package-to-merge lifecycle")

  defp product_description(_id), do: "Synthetic package for local cockpit visual QA."

  defp kind("SYMPP-DEMO-WP-ACTIVE"), do: "mcp"
  defp kind("SYMPP-DEMO-WP-QUEUED"), do: "mcp"
  defp kind("SYMPP-DEMO-WP-PLANNING"), do: "mcp"
  defp kind("SYMPP-DEMO-WP-REVIEW"), do: "docs"
  defp kind("SYMPP-DEMO-WP-CI"), do: "mcp"
  defp kind("SYMPP-DEMO-WP-READY"), do: "mcp"
  defp kind("SYMPP-DEMO-WP-ARCH-READY"), do: "mcp"
  defp kind("SYMPP-DEMO-WP-BLOCKED"), do: "investigation"
  defp kind("SYMPP-DEMO-WP-MERGED"), do: "mcp"
  defp kind("SYMPP-DEMO-WP-MERGED-DOCS"), do: "docs"
  defp kind("SYMPP-DEMO-WP-CLOSED-SPIKE"), do: "investigation"

  defp review_requirement(id) when id in ["SYMPP-DEMO-WP-BLOCKED", "SYMPP-DEMO-WP-CLOSED-SPIKE"], do: nil
  defp review_requirement(_id), do: %{"type" => "review-suite", "args" => %{"mode" => "normal"}}

  defp branch_pattern(id), do: "feat/#{String.downcase(id)}/demo"

  defp allowed_file_globs(_id), do: ["elixir/lib/**", "docs/**"]

  defp acceptance_criteria(title), do: ["Cockpit displays #{title}.", "Evidence remains synthetic and redacted."]

  defp seed_human_decision_prompts do
    with {:ok, _question} <-
           WorkRequestRepository.ask_question(Repo, "SYMPP-DEMO-WR-HUMAN", %{
             id: "SYMPP-DEMO-WRQ-STRUCTURED",
             category: "ownership",
             question: "Which package should own the cockpit guidance rendering?",
             why_needed: "The architect needs a bounded ownership call before slicing.",
             decision_prompt: demo_work_request_decision_prompt()
           }),
         {:ok, grant} <- AccessGrantRepository.create(Repo, demo_guidance_grant_attrs()),
         {:ok, guidance} <- GuidanceRequestRepository.create(Repo, demo_guidance_request_attrs(grant.id)) do
      {:ok, [guidance]}
    end
  end

  defp demo_guidance_grant_attrs do
    %{
      id: "SYMPP-DEMO-GRANT-GUIDANCE",
      work_package_id: "SYMPP-DEMO-WP-BLOCKED",
      display_key: "DEMO",
      secret_hash: String.duplicate("a", 64),
      grant_role: "worker",
      capabilities: [],
      expires_at: DateTime.add(@demo_now, 7, :day)
    }
  end

  defp demo_guidance_request_attrs(grant_id) do
    %{
      id: "SYMPP-DEMO-GUIDANCE-HUMAN",
      work_package_id: "SYMPP-DEMO-WP-BLOCKED",
      requester_grant_id: grant_id,
      requested_by: "demo-worker",
      idempotency_key: "demo-guidance-human",
      summary: "Choose the cockpit default grouping",
      question: "Should blocked package guidance be grouped by priority or package?",
      context: "The worker has two valid UI paths and should not choose product behavior alone.",
      status: "human_info_needed",
      human_info_reason: "Default grouping changes operator triage behavior.",
      recommended_language: "Choose priority-first grouping unless the operator wants package-first scanning.",
      decision_prompt: demo_guidance_decision_prompt(),
      blocker_id: "demo-product-guidance"
    }
  end

  defp demo_work_request_decision_prompt do
    %{
      "tl_dr" => "Choose who owns the first cockpit guidance slice.",
      "details" => "The WorkRequest is blocked on whether the next package should make a narrow dashboard rendering change or pause for a broader contract pass.",
      "options" => [
        %{
          "id" => "dashboard_first",
          "label" => "Dashboard first",
          "description" => "Ship the visible structured prompt rendering before broader contract cleanup.",
          "pros" => ["Fast operator feedback", "Keeps scope narrow"],
          "cons" => ["Contract wording may need a follow-up"],
          "answer" => "Proceed with the dashboard-first structured prompt rendering slice."
        },
        %{
          "id" => "contract_first",
          "label" => "Contract first",
          "description" => "Update the durable contract before changing cockpit rendering.",
          "pros" => ["Clearer implementation target"],
          "cons" => ["Delays visible validation"],
          "answer" => "Update the durable prompt contract before dashboard rendering work continues."
        }
      ],
      "custom_redirect_label" => "No, and tell the agent what to do differently"
    }
  end

  defp demo_guidance_decision_prompt do
    %{
      "tl_dr" => "Pick the operator triage grouping.",
      "details" => "The package is blocked because priority-first and package-first grouping are both plausible for the local cockpit.",
      "options" => [
        %{
          "id" => "priority_first",
          "label" => "Priority first",
          "description" => "Put human-info-needed and blocked items at the top.",
          "pros" => ["Fastest triage"],
          "cons" => ["Less package-by-package continuity"],
          "answer" => "Use priority-first grouping for the local operator cockpit."
        },
        %{
          "id" => "package_first",
          "label" => "Package first",
          "description" => "Keep every package's state grouped together.",
          "pros" => ["Easier package scanning"],
          "cons" => ["Urgent prompts may be lower on the page"],
          "answer" => "Use package-first grouping for the local operator cockpit."
        }
      ],
      "custom_redirect_label" => "No, and tell the agent what to do differently"
    }
  end

  defp seed_work_package_evidence do
    work_package_evidence()
    |> Enum.reduce_while({:ok, []}, fn {work_package_id, evidence}, {:ok, acc} ->
      case append_evidence(work_package_id, evidence) do
        {:ok, rows} -> {:cont, {:ok, rows ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp work_package_evidence do
    [
      {"SYMPP-DEMO-WP-ACTIVE",
       %{
         plan: [{"Verify board filters", "done"}, {"Capture detail screenshot", "pending"}],
         progress: [{"Implementation started", "running", %{"synthetic_demo" => true}}],
         findings: [{"No secret material required", "info"}],
         artifacts: [{"Visual QA target", "/sympp/work-packages/SYMPP-DEMO-WP-ACTIVE"}]
       }},
      {"SYMPP-DEMO-WP-QUEUED",
       %{
         plan: [{"Dispatch contract approved", "done"}, {"Worker claim pending", "pending"}],
         progress: [{"Queued for worker", "ready_for_worker", %{"handoff" => "synthetic"}}],
         findings: [{"Worker handoff intentionally synthetic", "info"}],
         artifacts: [{"Dispatch packet", "sympp://demo/worker-handoff"}]
       }},
      {"SYMPP-DEMO-WP-PLANNING",
       %{
         plan: [{"Architect scoped smoke path", "done"}, {"Worker plan pending", "pending"}],
         progress: [
           {"Architecture planning started", "planning", %{"slice" => "api-bridge-smoke"}},
           {"Slice sequencing waits on handoff", "blocked",
            %{
              "type" => "blocker",
              "source_tool" => "report_blocker",
              "blocker_id" => "demo-slice-sequencing-dependency",
              "active" => true,
              "blocked_by" => %{"kind" => "work_package", "id" => "SYMPP-DEMO-WP-QUEUED"},
              "blocked_item" => %{"kind" => "work_package", "id" => "SYMPP-DEMO-WP-PLANNING"},
              "summary" => "Plan API bridge smoke coverage after the worker handoff package is ready."
            }}
         ],
         findings: [{"API bridge path remains local-only", "info"}],
         artifacts: [{"Planning note", "docs/operations.md"}]
       }},
      {"SYMPP-DEMO-WP-REVIEW",
       %{
         plan: [{"Review prompt copy", "done"}, {"Run local signoff", "pending"}],
         progress: [
           {"Review branch attached", "branch_attached",
            %{
              "type" => "branch",
              "source_tool" => "attach_branch",
              "branch" => "agent/sympp-demo-wp-review/demo",
              "head_sha" => "2222222222222222222222222222222222222222"
            }},
           {"Review package submitted", "review_package_submitted",
            %{
              "type" => "review_package",
              "source_tool" => "submit_review_package",
              "summary" => "Synthetic demo review package.",
              "tests" => ["mix test test/mix/tasks/sympp_demo_ledger_test.exs"],
              "artifacts" => ["docs/operations.md"],
              "head_sha" => "2222222222222222222222222222222222222222",
              "acceptance_criteria_met" => true
            }}
         ],
         findings: [{"Copy needs operator confirmation", "medium"}],
         artifacts: [{"Review notes", "docs/operations.md"}]
       }},
      {"SYMPP-DEMO-WP-CI",
       %{
         plan: [{"Open PR", "done"}, {"Wait for CI", "pending"}],
         progress: [
           {"CI waiting on required checks", "ci_waiting", %{"checks" => ["unit", "ui-build"]}},
           {"Dependency waiting on smoke coverage", "blocked",
            %{
              "type" => "blocker",
              "source_tool" => "report_blocker",
              "blocker_id" => "demo-ci-smoke-dependency",
              "active" => true,
              "blocked_by" => %{"kind" => "work_package", "id" => "SYMPP-DEMO-WP-REVIEW"},
              "summary" => "Wait for API bridge smoke coverage before this package can clear CI."
            }}
         ],
         findings: [{"No live secrets needed for CI demo", "info"}],
         artifacts: [{"CI preview", "https://example.invalid/symphony-plus-plus/actions/runs/303"}]
       }},
      {"SYMPP-DEMO-WP-READY",
       %{
         plan: [{"Acceptance complete", "done"}, {"Attach final PR evidence", "done"}],
         progress: [{"Ready for human merge", "ready", %{"head_sha" => "0000000000000000000000000000000000000000"}}],
         findings: [{"Validation is synthetic", "info"}],
         artifacts: [{"PR preview", "https://example.invalid/symphony-plus-plus/pull/101"}]
       }},
      {"SYMPP-DEMO-WP-ARCH-READY",
       %{
         plan: [{"Required review complete", "done"}, {"Architect merge gate", "pending"}],
         progress: [{"Ready for architect merge", "ready_for_architect_merge", %{"review_complete" => true}}],
         findings: [{"Architect signoff is the remaining gate", "info"}],
         artifacts: [{"Merge checklist", "docs/runbooks/delivery-recovery.md"}]
       }},
      {"SYMPP-DEMO-WP-BLOCKED",
       %{
         plan: [{"Wait for product answer", "pending"}],
         progress: [
           {"Product decision required", "blocked",
            %{
              "type" => "blocker",
              "source_tool" => "report_blocker",
              "blocker_id" => "demo-product-guidance",
              "active" => true,
              "summary" => "Choose the cockpit default grouping before implementation continues."
            }}
         ],
         findings: [{"Default grouping remains undecided", "high"}],
         artifacts: [{"Guidance placeholder", "sympp://demo/product-guidance"}]
       }},
      {"SYMPP-DEMO-WP-MERGED",
       %{
         plan: [{"Cleanup merged", "done"}],
         progress: [{"Merged into main", "completed", %{"merged" => true}}],
         findings: [{"No follow-up required", "info"}],
         artifacts: [{"Merge evidence", "https://example.invalid/symphony-plus-plus/pull/102"}]
       }},
      {"SYMPP-DEMO-WP-MERGED-DOCS",
       %{
         plan: [{"Docs merged", "done"}],
         progress: [{"Merged docs update", "completed", %{"merged" => true}}],
         findings: [{"Operator docs match demo flow", "info"}],
         artifacts: [{"Docs PR", "https://example.invalid/symphony-plus-plus/pull/103"}]
       }},
      {"SYMPP-DEMO-WP-CLOSED-SPIKE",
       %{
         plan: [{"Duplicate spike closed", "done"}],
         progress: [{"Closed after duplicate detection", "completed", %{"closed" => true}}],
         findings: [{"Covered by lifecycle package", "info"}],
         artifacts: [{"Closure note", "sympp://demo/closed-spike"}]
       }}
    ]
  end

  defp append_evidence(work_package_id, evidence) do
    with {:ok, plan_nodes} <- append_plan_nodes(work_package_id, Map.fetch!(evidence, :plan)),
         {:ok, progress_events} <- append_progress_events(work_package_id, Map.fetch!(evidence, :progress)),
         {:ok, findings} <- append_findings(work_package_id, Map.fetch!(evidence, :findings)),
         {:ok, artifacts} <- append_artifacts(work_package_id, Map.fetch!(evidence, :artifacts)) do
      {:ok, plan_nodes ++ progress_events ++ findings ++ artifacts}
    end
  end

  defp append_plan_nodes(work_package_id, entries) do
    entries
    |> Enum.with_index(1)
    |> insert_all(fn {{title, status}, sequence} ->
      PlanningRepository.append_plan_node(Repo, %{
        id: evidence_id(work_package_id, "plan", sequence),
        work_package_id: work_package_id,
        title: title,
        body: "Synthetic demo plan node.",
        status: status
      })
    end)
  end

  defp append_progress_events(work_package_id, entries) do
    entries
    |> Enum.with_index(1)
    |> insert_all(fn {{summary, status, payload}, sequence} ->
      PlanningRepository.append_progress_event(Repo, %{
        id: evidence_id(work_package_id, "progress", sequence),
        work_package_id: work_package_id,
        summary: summary,
        body: "Synthetic demo progress event.",
        status: status,
        idempotency_key: "#{work_package_id}:#{summary}",
        payload: payload
      })
    end)
  end

  defp append_findings(work_package_id, entries) do
    entries
    |> Enum.with_index(1)
    |> insert_all(fn {{title, severity}, sequence} ->
      PlanningRepository.append_finding(Repo, %{
        id: evidence_id(work_package_id, "finding", sequence),
        work_package_id: work_package_id,
        title: title,
        body: "Synthetic demo finding.",
        severity: severity,
        idempotency_key: "#{work_package_id}:#{title}"
      })
    end)
  end

  defp append_artifacts(work_package_id, entries) do
    entries
    |> Enum.with_index(1)
    |> insert_all(fn {{title, path}, sequence} ->
      PlanningRepository.append_artifact(Repo, %{
        id: evidence_id(work_package_id, "artifact", sequence),
        work_package_id: work_package_id,
        title: title,
        path: path,
        kind: "reference",
        metadata: %{"synthetic_demo" => true}
      })
    end)
  end

  defp evidence_id(work_package_id, kind, sequence) do
    work_package_id
    |> String.replace("SYMPP-DEMO-WP-", "SYMPP-DEMO-#{String.upcase(kind)}-")
    |> Kernel.<>("-#{sequence}")
  end

  defp seed_solo_sessions do
    now = @demo_now

    sessions = [
      solo_session("SYMPP-DEMO-SOLO-ACTIVE", "active", "Active cockpit smoke test", now),
      solo_session("SYMPP-DEMO-SOLO-PAUSED", "paused", "Paused documentation review", now),
      solo_session("SYMPP-DEMO-SOLO-COMPLETED", "completed", "Completed validation pass", now),
      solo_session("SYMPP-DEMO-SOLO-ARCHIVED", "archived", "Archived exploratory spike", now)
    ]

    entries =
      Enum.flat_map(sessions, fn session ->
        [
          solo_entry(session.id, 1, "task_plan", "Plan #{session.title}", "pending", now),
          solo_entry(session.id, 2, "finding", "Finding #{session.title}", nil, now),
          solo_entry(session.id, 3, "progress", "Progress #{session.title}", "recorded", now),
          solo_entry(session.id, 4, "decision", "Decision #{session.title}", nil, now),
          solo_entry(session.id, 5, "validation_note", "Validation #{session.title}", "completed", now)
        ]
      end)

    Repo.insert_all(SoloSession, sessions, on_conflict: :raise)
    Repo.insert_all(SoloSessionEntry, entries, on_conflict: :raise)

    {:ok, sessions}
  rescue
    error in Ecto.ConstraintError -> {:error, {:constraint_failed, error.constraint}}
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  defp normalize_demo_timestamps do
    Enum.each(
      [AccessGrant, GuidanceRequest, WorkRequest, WorkPackage, ClarificationQuestion, Comment, SoloSession],
      fn schema -> Repo.update_all(schema, set: [inserted_at: @demo_now, updated_at: @demo_now]) end
    )

    Enum.each([PlanNode, ProgressEvent, Finding, Artifact, DependencyEdge], &normalize_ordered_timestamps/1)

    Repo.update_all(
      WorkPackageDelivery,
      set: [recorded_at: @demo_now, inserted_at: @demo_now, updated_at: @demo_now]
    )

    Repo.update_all(SoloSessionEntry, set: [created_at: @demo_now, updated_at: @demo_now])

    Repo.update_all(
      from(work_package in WorkPackage, where: not is_nil(work_package.dispatched_at)),
      set: [dispatched_at: @demo_now]
    )
  end

  defp normalize_ordered_timestamps(schema) do
    from(row in schema, order_by: [asc: row.id])
    |> Repo.all()
    |> Enum.with_index()
    |> Enum.each(fn {%{id: id}, index} ->
      timestamp = DateTime.add(@demo_now, index, :microsecond)

      Repo.update_all(
        from(row in schema, where: row.id == ^id),
        set: [created_at: timestamp, inserted_at: timestamp, updated_at: timestamp]
      )
    end)
  end

  defp solo_session(id, status, title, now) do
    %{
      id: id,
      repo: @demo_repo,
      base_branch: @demo_base_branch,
      workspace_path: demo_workspace_path(id),
      caller_id: "local-demo-operator",
      session_key: "solo_key_#{String.downcase(id)}",
      title: title,
      status: status,
      last_activity_at: now,
      archived_at: if(status == "archived", do: now),
      inserted_at: now,
      updated_at: now
    }
  end

  defp demo_workspace_path(id) do
    case :os.type() do
      {:win32, _name} -> "c:/demo/#{String.downcase(id)}"
      _type -> "/demo/#{String.downcase(id)}"
    end
  end

  defp solo_entry(solo_session_id, sequence, kind, title, status, now) do
    %{
      id: "#{solo_session_id}-ENTRY-#{sequence}",
      solo_session_id: solo_session_id,
      entry_kind: kind,
      title: title,
      body: solo_demo_body(kind, title, status),
      status: status || "recorded",
      sequence: sequence,
      idempotency_key: "#{solo_session_id}:#{kind}",
      payload: %{"synthetic_demo" => true},
      created_at: now,
      updated_at: now
    }
  end

  defp solo_demo_body("task_plan", title, _status) do
    subject = solo_demo_subject(title)

    """
    ## Current plan
    - Verify the local cockpit flow represented by `#{subject}`.
    - Keep the card view short and move the deeper ledger context into the click-in modal.
    - Record validation evidence before marking the session complete.
    """
  end

  defp solo_demo_body("finding", _title, _status) do
    """
    ## Finding
    The Solo Session is useful as a lightweight planning ledger, but the board should only surface active attention and recent progress.
    """
  end

  defp solo_demo_body("progress", _title, "completed") do
    """
    ## Progress
    - Finished the implementation pass.
    - Captured the final validation state.
    """
  end

  defp solo_demo_body("progress", _title, _status) do
    """
    ## Progress
    - Inspected the active UI surface.
    - Confirmed the next step is visible without adding noisy sub-cards.
    """
  end

  defp solo_demo_body("decision", _title, _status) do
    """
    ## Decision
    Keep Solo Session cards compact. Use dropdowns inside the modal for task plans, findings, progress, decisions, and validation notes.
    """
  end

  defp solo_demo_body("validation_note", _title, _status) do
    """
    ## Validation
    - Dashboard smoke path loads.
    - Modal content preserves readable markdown formatting.
    """
  end

  defp solo_demo_body(_kind, title, _status), do: "Synthetic demo Solo Session entry for #{title}."

  defp solo_demo_subject(title), do: String.replace_prefix(title, "Plan ", "")

  defp insert_all(items, insert_fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case insert_fun.(item) do
        {:ok, row} -> {:cont, {:ok, acc ++ [row]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_repo(database) do
    with :ok <- ensure_repo_dependencies_started() do
      case Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false) do
        {:ok, pid} ->
          Repo.put_dynamic_repo(pid)
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          Repo.put_dynamic_repo(pid)
          {:ok, nil}

        {:error, reason} ->
          {:error, {:repo_start_failed, reason}}
      end
    end
  end

  defp stop_repo(pid) when is_pid(pid), do: GenServer.stop(pid)
  defp stop_repo(_pid), do: :ok

  defp ensure_repo_dependencies_started do
    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, {:ecto_start_failed, reason}}
    end
  end

  defp resolved_database(database) when is_binary(database) do
    if Repo.filesystem_database_path?(database) do
      database = Path.expand(database)
      File.mkdir_p!(Path.dirname(database))
      database
    else
      database
    end
  end

  defp resolved_database(_database) do
    original_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      use_mix_project_workflow()
      Application.delete_env(:symphony_elixir, :sympp_repo_database)
      Repo.database_path()
    after
      restore_sympp_repo_database(original_database)
      restore_workflow(original_workflow)
    end
  end

  defp use_mix_project_workflow do
    mix_project_workflow()
    |> case do
      path when is_binary(path) -> Workflow.set_workflow_file_path(path)
      nil -> :ok
    end
  end

  defp restore_workflow(nil), do: Workflow.clear_workflow_file_path()
  defp restore_workflow(path) when is_binary(path), do: Workflow.set_workflow_file_path(path)

  defp restore_sympp_repo_database(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_sympp_repo_database(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)

  defp mix_project_workflow do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.expand()
    |> Path.join("WORKFLOW.md")
    |> existing_file()
  end

  defp existing_file(path) do
    if File.exists?(path), do: path
  end

  defp quote_cli_arg(path), do: "'#{String.replace(path, "'", "''")}'"

  defp error_message(:unsupported_database), do: "mix sympp.demo_ledger requires --database to be a durable local SQLite filesystem path."
  defp error_message({:database_exists, path}), do: "Demo ledger already exists at #{path}. Pass --force to overwrite it."
  defp error_message({:repo_start_failed, reason}), do: "Failed to start Symphony++ demo ledger repository: #{inspect(reason)}"
  defp error_message({:ecto_start_failed, reason}), do: "Failed to start Ecto for Symphony++ demo ledger: #{inspect(reason)}"
  defp error_message({:constraint_failed, constraint}), do: "Failed to seed Symphony++ demo ledger due to constraint #{constraint}."
  defp error_message({:storage_failed, message}), do: "Failed to seed Symphony++ demo ledger: #{message}"
  defp error_message(reason), do: "Failed to seed Symphony++ demo ledger: #{inspect(reason)}"

  defp has_blank_option?(opts, keys) do
    Enum.any?(keys, &(Keyword.has_key?(opts, &1) and blank?(Keyword.get(opts, &1))))
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
