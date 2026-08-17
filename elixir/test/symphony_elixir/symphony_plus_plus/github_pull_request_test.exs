defmodule SymphonyElixir.SymphonyPlusPlus.GitHubPullRequestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Client, DryClient, PullRequest, PullRequestProgress}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent

  test "orders provider head evidence by the DateTime instant across second boundaries" do
    earlier = %ProgressEvent{
      id: "earlier",
      sequence: 1,
      created_at: ~U[2026-08-17 11:44:17.975000Z],
      payload: %{"type" => "branch", "source_tool" => "attach_branch", "head_sha" => "head-a"}
    }

    later = %ProgressEvent{
      id: "later",
      sequence: 2,
      created_at: ~U[2026-08-17 11:44:18.427000Z],
      payload: %{"type" => "branch", "source_tool" => "attach_branch", "head_sha" => "head-b"}
    }

    assert PullRequestProgress.chronological_events([later, earlier]) == [earlier, later]
    assert PullRequestProgress.expected_head_sha([later, earlier], %{}) == "head-b"

    subsecond_earlier = %{earlier | id: "subsecond-earlier", sequence: 4, created_at: ~U[2026-08-17 11:44:17.427000Z]}
    subsecond_later = %{later | id: "subsecond-later", sequence: 3, created_at: ~U[2026-08-17 11:44:17.975000Z]}

    assert PullRequestProgress.chronological_events([subsecond_later, subsecond_earlier]) ==
             [subsecond_earlier, subsecond_later]
  end

  test "parses GitHub PR URLs" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    assert ref.owner == "nextide"
    assert ref.repo == "symphony-plus-plus"
    assert ref.repository == "nextide/symphony-plus-plus"
    assert ref.number == 42
    assert ref.url == "https://github.com/nextide/symphony-plus-plus/pull/42"

    assert {:ok, mixed_host_ref} = PullRequest.parse(%{"url" => "https://GitHub.com/nextide/symphony-plus-plus/pull/43"}, nil)
    assert mixed_host_ref.url == "https://github.com/nextide/symphony-plus-plus/pull/43"

    assert {:ok, subpage_ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/44/files"}, nil)
    assert subpage_ref.url == "https://github.com/nextide/symphony-plus-plus/pull/44"

    assert {:ok, cased_ref} =
             PullRequest.parse(
               %{"url" => "https://github.com/NextIDE/Symphony-Plus-Plus/pull/45", "repository" => "nextide/symphony-plus-plus"},
               nil
             )

    assert cased_ref.repository == "NextIDE/Symphony-Plus-Plus"
    assert cased_ref.number == 45
  end

  test "parses PR numbers against package repository" do
    assert {:ok, ref} = PullRequest.parse(%{"number" => 77}, "nextide/symphony-plus-plus")

    assert ref.repository == "nextide/symphony-plus-plus"
    assert ref.number == 77
    assert ref.url == "https://github.com/nextide/symphony-plus-plus/pull/77"

    assert {:ok, metadata_ref} =
             PullRequest.parse(
               %{"number" => 78, "metadata" => %{"base" => %{"repo" => %{"full_name" => "nextide/symphony-plus-plus"}}}},
               "symphony-plus-plus"
             )

    assert metadata_ref.repository == "nextide/symphony-plus-plus"
    assert metadata_ref.url == "https://github.com/nextide/symphony-plus-plus/pull/78"

    assert {:ok, repository_object_ref} =
             PullRequest.parse(
               %{
                 "number" => 79,
                 "metadata" => %{
                   "repository" => %{"full_name" => "nextide/symphony-plus-plus"},
                   "base" => %{"repo" => %{"full_name" => "ignored/base"}}
                 }
               },
               "symphony-plus-plus"
             )

    assert repository_object_ref.repository == "nextide/symphony-plus-plus"
    assert repository_object_ref.url == "https://github.com/nextide/symphony-plus-plus/pull/79"

    assert {:ok, package_ref} =
             PullRequest.parse(
               %{"number" => 80, "metadata" => %{"repository" => %{"full_name" => "wrong/repo"}}},
               "nextide/symphony-plus-plus"
             )

    assert package_ref.repository == "nextide/symphony-plus-plus"
    assert package_ref.url == "https://github.com/nextide/symphony-plus-plus/pull/80"
  end

  test "rejects malformed PR references" do
    assert {:error, :invalid_pr_url} = PullRequest.parse(%{"url" => "https://example.com/nextide/repo/pull/1"}, nil)
    assert {:error, :missing_repository} = PullRequest.parse(%{"number" => 1}, nil)
    assert {:error, :invalid_pr_number} = PullRequest.parse(%{"number" => 0}, "nextide/repo")

    assert {:error, :pr_reference_mismatch} =
             PullRequest.parse(%{"url" => "https://github.com/nextide/repo/pull/1", "number" => 2}, nil)

    assert {:error, :pr_reference_mismatch} =
             PullRequest.parse(%{"url" => "https://github.com/nextide/repo/pull/1", "number" => 1, "repository" => "other/repo"}, nil)
  end

  test "maps dry metadata into a redaction-friendly PR payload" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    metadata = %{
      "head_sha" => "abc123",
      "branch" => "agent/SYMPP-P6-001/github-pr-attachment-sync",
      "base_branch" => "symphony-plus-plus/beta",
      "changed_files" => [%{"filename" => "elixir/lib/example.ex", "status" => "modified"}],
      "check_summary" => %{"state" => "success", "token" => "ghp_should_not_surface"},
      "review_state" => %{"state" => "approved", "authorization" => "Bearer secret"},
      "merge_state" => %{"state" => "clean", "client_secret" => "secret"}
    }

    assert {:ok, fetched} = Client.fetch_pull_request(DryClient, ref, metadata: metadata)
    assert {:ok, payload} = PullRequest.metadata(fetched, ref, nil)

    assert payload["repository"] == "nextide/symphony-plus-plus"
    assert payload["number"] == 42
    assert payload["head_sha"] == "abc123"
    assert payload["base_branch"] == "symphony-plus-plus/beta"
    assert payload["changed_files"] == [%{"path" => "elixir/lib/example.ex", "status" => "modified"}]
    assert payload["changed_files_count"] == 1
    assert payload["changed_files_available"] == true
    assert payload["changed_files_count_available"] == true
    assert payload["check_summary"] == %{"state" => "success", "token" => "[REDACTED]"}
    assert payload["review_state"] == %{"state" => "approved", "authorization" => "[REDACTED]"}
    assert payload["merge_state"] == %{"state" => "clean", "client_secret" => "[REDACTED]"}
    refute Map.has_key?(payload, "authorization")
  end

  test "maps standard GitHub head object into PR head metadata" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    metadata = %{
      "head" => %{"sha" => "abc123", "ref" => "agent/SYMPP-P6-001/github-pr-attachment-sync"},
      "base" => %{"ref" => "main", "sha" => "base123"},
      "changed_files" => [],
      "state" => "open",
      "mergeable" => true,
      "mergeable_state" => "clean",
      "draft" => false
    }

    assert {:ok, payload} = PullRequest.metadata(metadata, ref, nil)

    assert payload["head_sha"] == "abc123"
    assert payload["branch"] == "agent/SYMPP-P6-001/github-pr-attachment-sync"
    assert payload["base_branch"] == "main"
    assert payload["base_sha"] == "base123"
    assert payload["merge_state"] == %{"mergeable" => true, "mergeable_state" => "clean", "state" => "open"}
    assert payload["review_state"] == %{"draft" => false}

    explicit_metadata = Map.put(metadata, "head", %{"sha" => "abc1234567890", "ref" => "agent/SYMPP-P6-001/github-pr-attachment-sync"})

    assert {:ok, explicit_payload} = PullRequest.metadata(explicit_metadata, ref, "abc1234")
    assert explicit_payload["head_sha"] == "abc1234"

    assert {:error, :head_sha_mismatch} = PullRequest.metadata(explicit_metadata, ref, "def1234")

    assert {:ok, cased_payload} =
             PullRequest.metadata(Map.put(metadata, "html_url", "https://github.com/NextIDE/Symphony-Plus-Plus/pull/42"), ref, nil)

    assert cased_payload["repository"] == "nextide/symphony-plus-plus"

    assert {:error, :pr_reference_mismatch} =
             PullRequest.metadata(Map.put(metadata, "html_url", "https://github.com/other/repo/pull/42"), ref, nil)

    assert {:error, :pr_reference_mismatch} = PullRequest.metadata(Map.put(metadata, "number", 43), ref, nil)
  end

  test "tolerates canonical GitHub changed file counts" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    metadata = %{
      "head" => %{"sha" => "abcdef1234567890abcdef1234567890abcdef12", "ref" => "agent/SYMPP-P6-001/github-pr-attachment-sync"},
      "changed_files" => 3
    }

    assert {:ok, payload} = PullRequest.metadata(metadata, ref, nil)

    assert payload["changed_files"] == []
    assert payload["changed_files_count"] == 3
    assert payload["changed_files_available"] == false
    assert payload["changed_files_count_available"] == true
  end

  test "fails closed for empty changed-file paths with a nonzero reported count" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    metadata = %{
      "head" => %{"sha" => "abcdef1234567890abcdef1234567890abcdef12", "ref" => "agent/SYMPP-P6-001/github-pr-attachment-sync"},
      "changed_files" => [],
      "changed_files_count" => 2
    }

    assert {:ok, payload} = PullRequest.metadata(metadata, ref, nil)

    assert payload["changed_files"] == []
    assert payload["changed_files_count"] == 2
    assert payload["changed_files_available"] == false
    assert payload["changed_files_count_available"] == true
  end

  test "fails closed for empty changed-file paths without a reported count" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    metadata = %{
      "head" => %{"sha" => "abcdef1234567890abcdef1234567890abcdef12", "ref" => "agent/SYMPP-P6-001/github-pr-attachment-sync"},
      "changed_files" => []
    }

    assert {:ok, payload} = PullRequest.metadata(metadata, ref, nil)

    assert payload["changed_files"] == []
    assert payload["changed_files_count"] == 0
    assert payload["changed_files_available"] == false
    assert payload["changed_files_count_available"] == false
  end

  test "preserves previous filenames for renamed changed files" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    metadata = %{
      "head" => %{"sha" => "abcdef1234567890abcdef1234567890abcdef12", "ref" => "agent/SYMPP-P6-001/github-pr-attachment-sync"},
      "changed_files" => [
        %{"filename" => "elixir/lib/new.ex", "previous_filename" => "docs/old.md", "status" => "renamed"}
      ]
    }

    assert {:ok, payload} = PullRequest.metadata(metadata, ref, nil)

    assert payload["changed_files"] == [
             %{"path" => "elixir/lib/new.ex", "previous_path" => "docs/old.md", "status" => "renamed"}
           ]
  end

  test "marks omitted changed files as unavailable evidence" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    metadata = %{
      "head" => %{"sha" => "abcdef1234567890abcdef1234567890abcdef12", "ref" => "agent/SYMPP-P6-001/github-pr-attachment-sync"}
    }

    assert {:ok, payload} = PullRequest.metadata(metadata, ref, nil)

    assert payload["changed_files"] == []
    assert payload["changed_files_count"] == 0
    assert payload["changed_files_available"] == false
    assert payload["changed_files_count_available"] == false
  end

  test "detects stale PR metadata by head sha" do
    refute PullRequest.stale?(%{"head_sha" => "abc123"}, "abc123")
    refute PullRequest.stale?(%{"head_sha" => "abcdef1234567890abcdef1234567890abcdef12"}, "abcdef1")
    assert PullRequest.stale?(%{"head_sha" => "abcdef1234567890abcdef1234567890abcdef12"}, "abc")
    assert PullRequest.stale?(%{"head_sha" => "abcdef1234567890abcdef1234567890abcdef12"}, "abcdef2")
    assert PullRequest.stale?(%{"head_sha" => "abc123"}, "def456")
    assert PullRequest.stale?(%{"head_sha" => "current-head"}, "current-head-2")
  end

  test "dry client requires explicit metadata" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    assert {:error, :metadata_required} = Client.fetch_pull_request(DryClient, ref)
  end
end
