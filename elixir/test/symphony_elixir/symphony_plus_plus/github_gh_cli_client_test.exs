defmodule SymphonyElixir.SymphonyPlusPlus.GitHubGhCliClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{FakeAuthenticatedGitHubClient, FakeGhCli, FakeGitHubClient}
  alias SymphonyElixir.GitHubPullRequestFixtures
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{DefaultClient, GhCliClient, PullRequest}

  setup do
    FakeGhCli.clear()
    FakeGitHubClient.clear()
    :ok
  end

  test "fetches gh pr view metadata with safe argv and normalizes it for PR metadata" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/repo/pull/22"}, nil)

    response =
      GitHubPullRequestFixtures.gh_view(22, "head-a", merged?: true, changed_files: 3)
      |> Map.merge(%{
        "id" => "PR_provider_22",
        "files" => [
          %{"path" => "lib/one.ex", "changeType" => "MODIFIED"},
          %{"path" => "lib/two.ex", "changeType" => "ADDED"},
          %{"path" => "test/one_test.exs", "changeType" => "MODIFIED"}
        ],
        "statusCheckRollup" => [
          %{"status" => "COMPLETED", "conclusion" => "SUCCESS"},
          %{"__typename" => "StatusContext", "state" => "SUCCESS"}
        ],
        "reviewDecision" => "APPROVED"
      })

    FakeGhCli.put_response("nextide/repo", 22, response)

    assert {:ok, metadata} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)
    assert {:ok, payload} = PullRequest.provider_snapshot(metadata, ref, "head-a")

    assert payload["number"] == 22
    assert payload["url"] == "https://github.com/nextide/repo/pull/22"
    assert payload["head_sha"] == "head-a"
    assert payload["branch"] == "agent/SYMPP-LOCAL-OPERATOR-GH-SYNC"
    assert payload["base_branch"] == "main"
    assert payload["base_sha"] == "base-sha"
    assert Enum.map(payload["changed_files"], & &1["path"]) == ["lib/one.ex", "lib/two.ex", "test/one_test.exs"]
    assert payload["changed_files_count"] == 3
    assert payload["changed_files_available"] == true
    assert payload["changed_files_count_available"] == true
    assert payload["check_summary"] == %{"status" => "passing"}
    assert payload["review_state"] == %{"status" => "approved"}
    assert payload["merge_state"] == %{"merged" => true, "status" => "merged"}
    assert payload["provider_reference"] == "PR_provider_22"

    assert [
             %{
               executable: "gh",
               args: ["pr", "view", "22", "--repo", "nextide/repo", "--json", fields],
               opts: [timeout: 5_000]
             }
           ] = FakeGhCli.commands()

    assert fields ==
             "id,number,url,headRefName,headRefOid,baseRefName,baseRefOid,changedFiles,files,statusCheckRollup,reviewDecision,state,isDraft,mergeable,mergeStateStatus,mergedAt,mergeCommit"
  end

  test "rejects a truncated gh file list as an incomplete provider snapshot" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/repo/pull/23"}, nil)

    response =
      GitHubPullRequestFixtures.gh_view(23, "head-a", changed_files: 2)
      |> Map.merge(%{"id" => "PR_provider_23", "files" => [%{"path" => "lib/one.ex"}], "statusCheckRollup" => [], "reviewDecision" => ""})

    FakeGhCli.put_response("nextide/repo", 23, response)

    assert {:ok, metadata} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)
    assert {:error, :provider_malformed} = PullRequest.provider_snapshot(metadata, ref, "head-a")
  end

  test "rejects incomplete or malformed gh file identity" do
    files = [
      {24, %{"path" => "lib/unknown.ex"}},
      {26, %{"path" => "lib/new.ex", "changeType" => "RENAMED"}},
      {27, %{"path" => "lib/invalid.ex", "changeType" => %{}}}
    ]

    for {number, file} <- files do
      assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/repo/pull/#{number}"}, nil)

      response =
        GitHubPullRequestFixtures.gh_view(number, "head-a", changed_files: 1)
        |> Map.merge(%{
          "id" => "PR_provider_#{number}",
          "files" => [file],
          "statusCheckRollup" => [],
          "reviewDecision" => ""
        })

      FakeGhCli.put_response("nextide/repo", number, response)

      assert {:ok, metadata} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)
      assert {:error, :provider_malformed} = PullRequest.provider_snapshot(metadata, ref, "head-a")
    end
  end

  test "classifies startup failures and closed pull requests as blocked failures" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/repo/pull/28"}, nil)

    response =
      GitHubPullRequestFixtures.gh_view(28, "head-a", changed_files: 0)
      |> Map.merge(%{
        "id" => "PR_provider_28",
        "files" => [],
        "state" => "CLOSED",
        "mergeable" => "UNKNOWN",
        "mergeStateStatus" => "UNKNOWN",
        "statusCheckRollup" => [%{"status" => "COMPLETED", "conclusion" => "STARTUP_FAILURE"}]
      })

    FakeGhCli.put_response("nextide/repo", 28, response)

    assert {:ok, metadata} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)
    assert {:ok, payload} = PullRequest.provider_snapshot(metadata, ref, "head-a")
    assert payload["check_summary"] == %{"status" => "failing"}
    assert payload["merge_state"] == %{"merged" => false, "status" => "blocked"}
  end

  test "provider snapshot mode does not use the incomplete HTTP fallback" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/repo/pull/25"}, nil)
    FakeGhCli.put_error("nextide/repo", 25, :gh_unavailable)
    FakeGitHubClient.put_response("nextide/repo", 25, GitHubPullRequestFixtures.metadata(25, "head-a"))

    assert {:error, :gh_unavailable} =
             DefaultClient.fetch_pull_request(ref,
               command_runner: &FakeGhCli.run/3,
               fallback_client: FakeAuthenticatedGitHubClient,
               provider_snapshot: true
             )
  end

  test "maps gh errors to stable client reasons without surfacing command output" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/repo/pull/404"}, nil)

    FakeGhCli.put_error("nextide/repo", 404, :gh_not_found)
    assert {:error, :gh_not_found} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)

    FakeGhCli.put_error("nextide/repo", 404, :gh_unauthorized)
    assert {:error, :gh_unauthorized} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)

    FakeGhCli.put_error("nextide/repo", 404, :gh_unavailable)
    assert {:error, :gh_unavailable} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)
  end

  test "reports gh auth availability with fake command execution" do
    FakeGhCli.authenticate(:ok)
    assert GhCliClient.auth_status(command_runner: &FakeGhCli.run/3) == :ok

    FakeGhCli.authenticate(:unauthorized)
    assert GhCliClient.auth_status(command_runner: &FakeGhCli.run/3) == {:error, :gh_unauthorized}

    FakeGhCli.authenticate(:unavailable)
    assert GhCliClient.auth_status(command_runner: &FakeGhCli.run/3) == {:error, :gh_unavailable}
  end
end
