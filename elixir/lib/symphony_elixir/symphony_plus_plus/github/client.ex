defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.Client do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest

  @callback fetch_pull_request(PullRequest.ref(), keyword()) :: {:ok, map()} | {:error, term()}

  @spec fetch_pull_request(module(), PullRequest.ref(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_pull_request(client, ref, opts \\ []) when is_atom(client) and is_map(ref) do
    client.fetch_pull_request(ref, opts)
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.DryClient do
  @moduledoc false

  @behaviour SymphonyElixir.SymphonyPlusPlus.GitHub.Client

  @impl true
  def fetch_pull_request(_ref, opts) do
    case Keyword.get(opts, :metadata) do
      metadata when is_map(metadata) -> {:ok, metadata}
      _metadata -> {:error, :metadata_required}
    end
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.HttpClient do
  @moduledoc false

  @behaviour SymphonyElixir.SymphonyPlusPlus.GitHub.Client

  @default_receive_timeout 5_000

  @spec authenticated?() :: boolean()
  def authenticated?, do: is_binary(github_token())

  @spec auth_status(keyword()) :: :ok | {:error, atom()}
  def auth_status(_opts \\ []) do
    if authenticated?(), do: :ok, else: {:error, :github_token_required}
  end

  @impl true
  def fetch_pull_request(%{owner: owner, repo: repo, number: number}, opts)
      when is_binary(owner) and is_binary(repo) and is_integer(number) do
    url = "https://api.github.com/repos/#{URI.encode_www_form(owner)}/#{URI.encode_www_form(repo)}/pulls/#{number}"

    url
    |> Req.get(headers: headers(), receive_timeout: receive_timeout(opts))
    |> handle_pull_request_response()
  end

  def fetch_pull_request(_ref, _opts), do: {:error, :invalid_pr_reference}

  defp handle_pull_request_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    if is_map(body), do: {:ok, Map.put(body, "provider_snapshot_complete", false)}, else: {:error, :invalid_github_response}
  end

  defp handle_pull_request_response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}
  defp handle_pull_request_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}
  defp handle_pull_request_response({:ok, %Req.Response{status: 403}}), do: {:error, :forbidden}

  defp handle_pull_request_response({:ok, %Req.Response{status: status}}) when is_integer(status) do
    {:error, {:github_status, status}}
  end

  defp handle_pull_request_response({:error, _reason}), do: {:error, :request_failed}

  defp headers do
    [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "symphony-plus-plus"},
      {"x-github-api-version", "2022-11-28"}
    ]
    |> maybe_put_authorization_header()
  end

  defp maybe_put_authorization_header(headers) do
    case github_token() do
      token when is_binary(token) -> [{"authorization", "Bearer #{token}"} | headers]
      nil -> headers
    end
  end

  defp github_token do
    (System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN"))
    |> case do
      token when is_binary(token) ->
        token = String.trim(token)
        if token == "", do: nil, else: token

      _token ->
        nil
    end
  end

  defp receive_timeout(opts) do
    case Keyword.get(opts, :receive_timeout, @default_receive_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _timeout -> @default_receive_timeout
    end
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.GhCliClient do
  @moduledoc false

  @behaviour SymphonyElixir.SymphonyPlusPlus.GitHub.Client

  @default_timeout 5_000
  @json_fields [
    "id",
    "number",
    "url",
    "headRefName",
    "headRefOid",
    "baseRefName",
    "baseRefOid",
    "changedFiles",
    "files",
    "statusCheckRollup",
    "reviewDecision",
    "state",
    "isDraft",
    "mergeable",
    "mergeStateStatus",
    "mergedAt",
    "mergeCommit"
  ]

  @spec auth_status(keyword()) :: :ok | {:error, atom()}
  def auth_status(opts \\ []) do
    case run_gh(["auth", "status", "--hostname", "github.com"], opts) do
      {:ok, _output} -> :ok
      {:error, reason} when reason in [:gh_unauthorized, :gh_unavailable] -> {:error, reason}
      {:error, _reason} -> {:error, :gh_unavailable}
    end
  end

  @impl true
  def fetch_pull_request(%{owner: owner, repo: repo, number: number} = ref, opts)
      when is_binary(owner) and is_binary(repo) and is_integer(number) do
    args = [
      "pr",
      "view",
      Integer.to_string(number),
      "--repo",
      "#{owner}/#{repo}",
      "--json",
      Enum.join(@json_fields, ",")
    ]

    with {:ok, output} <- run_gh(args, opts),
         {:ok, decoded} <- decode_json(output) do
      {:ok, normalize_pull_request(decoded, ref)}
    end
  end

  def fetch_pull_request(_ref, _opts), do: {:error, :invalid_pr_reference}

  @spec system_cmd(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def system_cmd(executable, args, opts) when is_binary(executable) and is_list(args) and is_list(opts) do
    task = Task.async(fn -> run_system_cmd(executable, args) end)
    await_command_task(task, timeout(opts))
  end

  defp run_system_cmd(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:exec_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exec_failed, inspect(reason)}}
  end

  defp await_command_task(task, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :request_failed}
      nil -> {:error, :timeout}
    end
  end

  defp run_gh(args, opts) do
    runner = command_runner(opts)
    runner_opts = [timeout: timeout(opts)]

    runner
    |> call_runner("gh", args, runner_opts)
    |> normalize_command_result()
  end

  defp command_runner(opts) do
    Keyword.get(opts, :command_runner) ||
      Application.get_env(:symphony_elixir, :sympp_gh_command_runner, &__MODULE__.system_cmd/3)
  end

  defp call_runner(runner, executable, args, opts) when is_function(runner, 3), do: runner.(executable, args, opts)
  defp call_runner({module, function}, executable, args, opts), do: apply(module, function, [executable, args, opts])

  defp normalize_command_result({:ok, output}) when is_binary(output), do: {:ok, output}

  defp normalize_command_result({:error, {status, output}}) when is_integer(status) do
    {:error, classify_gh_error(output)}
  end

  defp normalize_command_result({:error, :timeout}), do: {:error, :gh_unavailable}
  defp normalize_command_result({:error, {:exec_failed, _message}}), do: {:error, :gh_unavailable}
  defp normalize_command_result({:error, :enoent}), do: {:error, :gh_unavailable}
  defp normalize_command_result({:error, reason}) when reason in [:gh_not_found, :gh_unauthorized, :gh_unavailable], do: {:error, reason}
  defp normalize_command_result({:error, _reason}), do: {:error, :request_failed}
  defp normalize_command_result(_result), do: {:error, :request_failed}

  defp classify_gh_error(output) do
    message = output |> to_string() |> String.downcase()

    cond do
      String.contains?(message, ["not logged", "not authenticated", "requires authentication", "http 401", "http 403"]) ->
        :gh_unauthorized

      String.contains?(message, ["not found", "could not resolve", "http 404"]) ->
        :gh_not_found

      String.contains?(message, ["executable file not found", "no such file", "not recognized"]) ->
        :gh_unavailable

      true ->
        :request_failed
    end
  end

  defp decode_json(output) do
    case Jason.decode(output) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :invalid_github_response}
      {:error, _reason} -> {:error, :invalid_github_response}
    end
  end

  defp normalize_pull_request(metadata, ref) do
    merged? = merged?(metadata)

    %{
      "provider_snapshot_complete" => true,
      "provider_reference" => Map.get(metadata, "id"),
      "number" => Map.get(metadata, "number") || ref.number,
      "html_url" => Map.get(metadata, "url") || ref.url,
      "head" => %{
        "sha" => Map.get(metadata, "headRefOid"),
        "ref" => Map.get(metadata, "headRefName")
      },
      "base" => %{
        "ref" => Map.get(metadata, "baseRefName"),
        "sha" => Map.get(metadata, "baseRefOid")
      },
      "changed_files_count" => changed_files_count(metadata),
      "changed_files" => Map.get(metadata, "files"),
      "check_rollup" => Map.get(metadata, "statusCheckRollup"),
      "review_decision" => blank_to_nil(Map.get(metadata, "reviewDecision")),
      "draft" => Map.get(metadata, "isDraft"),
      "state" => normalized_gh_string(Map.get(metadata, "state")),
      "mergeable" => Map.get(metadata, "mergeable"),
      "mergeable_state" => normalized_gh_string(Map.get(metadata, "mergeStateStatus")),
      "merged" => merged?,
      "merged_at" => blank_to_nil(Map.get(metadata, "mergedAt")),
      "merge_commit_sha" => merge_commit_sha(metadata)
    }
    |> reject_nil_values()
  end

  defp changed_files_count(%{"changedFiles" => count}) when is_integer(count) and count >= 0, do: count
  defp changed_files_count(_metadata), do: nil

  defp merged?(metadata) do
    filled_string?(Map.get(metadata, "mergedAt")) or normalized_gh_string(Map.get(metadata, "state")) == "merged"
  end

  defp normalized_gh_string(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalized_gh_string(_value), do: nil

  defp merge_commit_sha(metadata) do
    blank_to_nil(get_in(metadata, ["mergeCommit", "oid"]) || get_in(metadata, ["mergeCommit", "sha"]))
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp timeout(opts) do
    case Keyword.get(opts, :gh_timeout, Keyword.get(opts, :timeout, @default_timeout)) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _timeout -> @default_timeout
    end
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.DefaultClient do
  @moduledoc false

  @behaviour SymphonyElixir.SymphonyPlusPlus.GitHub.Client

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{GhCliClient, HttpClient}

  @spec auth_status(keyword()) :: :ok | {:error, atom()}
  def auth_status(opts \\ []) do
    case GhCliClient.auth_status(opts) do
      :ok ->
        :ok

      {:error, _reason} ->
        if http_fallback_available?(Keyword.get(opts, :fallback_client, HttpClient)),
          do: :ok,
          else: {:error, :github_cli_or_token_required}
    end
  end

  @impl true
  def fetch_pull_request(ref, opts) do
    case GhCliClient.fetch_pull_request(ref, opts) do
      {:error, reason}
      when reason in [:gh_not_found, :gh_unauthorized, :gh_unavailable, :request_failed, :invalid_github_response] ->
        if Keyword.get(opts, :provider_snapshot, false),
          do: {:error, reason},
          else: fetch_with_http_fallback(ref, opts, reason)

      result ->
        result
    end
  end

  defp fetch_with_http_fallback(ref, opts, reason) do
    client = Keyword.get(opts, :fallback_client, HttpClient)

    if http_fallback_available?(client) do
      client.fetch_pull_request(ref, opts)
    else
      {:error, reason}
    end
  end

  defp http_fallback_available?(HttpClient), do: HttpClient.authenticated?()

  defp http_fallback_available?(client) do
    Code.ensure_loaded?(client)

    not function_exported?(client, :authenticated?, 0) or client.authenticated?()
  end
end
