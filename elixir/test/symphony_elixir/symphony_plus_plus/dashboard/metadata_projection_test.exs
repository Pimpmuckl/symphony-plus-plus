defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjection
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent

  test "metadata prefers the current-head PR sync after PR attachment" do
    events = [
      progress_event("branch", 1, %{
        "type" => "branch",
        "source_tool" => "attach_branch",
        "branch" => "agent/wp-1",
        "head_sha" => "head-a"
      }),
      progress_event("attach-pr", 2, %{
        "type" => "pr",
        "source_tool" => "attach_pr",
        "repository" => "NextIDE/symphony-plus-plus",
        "number" => 17,
        "head_sha" => "head-a"
      }),
      progress_event("sync-pr", 3, %{
        "type" => "pr",
        "source_tool" => "sync_pr",
        "repository" => "nextide/symphony-plus-plus",
        "number" => 17,
        "head_sha" => "head-a",
        "check_summary" => %{"status" => "success"}
      })
    ]

    metadata = MetadataProjection.metadata(events)

    assert metadata.branch["head_sha"] == "head-a"
    assert metadata.pr["head_sha"] == "head-a"
    assert metadata.pr["current_head_sha"] == "head-a"
    refute metadata.pr["stale"]
  end

  test "metadata keeps the current attached PR when older PR evidence is backfilled later" do
    events = [
      progress_event(
        "branch",
        1,
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/wp-1", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:00Z]
      ),
      progress_event(
        "current-attach-pr",
        2,
        %{
          "type" => "pr",
          "source_tool" => "attach_pr",
          "repository" => "nextide/symphony-plus-plus",
          "number" => 17,
          "head_sha" => "head-a"
        },
        ~U[2026-05-01 00:00:02Z]
      ),
      progress_event(
        "current-sync-pr",
        3,
        %{
          "type" => "pr",
          "source_tool" => "sync_pr",
          "repository" => "nextide/symphony-plus-plus",
          "number" => 17,
          "head_sha" => "head-a",
          "check_summary" => %{"status" => "success"}
        },
        ~U[2026-05-01 00:00:03Z]
      ),
      progress_event(
        "backfilled-duplicate-attach-pr",
        4,
        %{
          "type" => "pr",
          "source_tool" => "attach_pr",
          "repository" => "nextide/symphony-plus-plus",
          "number" => 17,
          "head_sha" => "head-a"
        },
        ~U[2026-05-01 00:00:01Z]
      )
    ]

    assert MetadataProjection.current_pr_state_present?(events, "head-a")
    metadata = MetadataProjection.metadata(events)
    assert metadata.pr["number"] == 17
    assert metadata.pr["source_tool"] == "sync_pr"
  end

  test "metadata treats repaired PR syncs as attached PR evidence" do
    events = [
      progress_event(
        "branch",
        1,
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/wp-1", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:00Z]
      ),
      progress_event(
        "stale-attach-pr",
        2,
        %{
          "type" => "pr",
          "source_tool" => "attach_pr",
          "repository" => "nextide/symphony-plus-plus",
          "number" => 16,
          "head_sha" => "head-a"
        },
        ~U[2026-05-01 00:00:01Z]
      ),
      progress_event(
        "repaired-sync-pr",
        3,
        %{
          "type" => "pr",
          "source_tool" => "sync_pr",
          "attachment_repair" => true,
          "repository" => "nextide/symphony-plus-plus",
          "number" => 17,
          "head_sha" => "head-a",
          "check_summary" => %{"status" => "success"}
        },
        ~U[2026-05-01 00:00:02Z]
      )
    ]

    assert MetadataProjection.current_pr_state_present?(events, "head-a")
    metadata = MetadataProjection.metadata(events)
    assert metadata.pr["number"] == 17
    assert metadata.pr["source_tool"] == "sync_pr"
  end

  test "metadata displays identity-only repaired PR syncs" do
    events = [
      progress_event(
        "branch",
        1,
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/wp-1", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:00Z]
      ),
      progress_event(
        "repaired-sync-pr",
        2,
        %{
          "type" => "pr",
          "source_tool" => "sync_pr",
          "attachment_repair" => true,
          "repository" => "nextide/symphony-plus-plus",
          "number" => 17,
          "head_sha" => "head-a"
        },
        ~U[2026-05-01 00:00:01Z]
      )
    ]

    metadata = MetadataProjection.metadata(events)
    assert metadata.pr["number"] == 17
    assert metadata.pr["source_tool"] == "sync_pr"
  end

  test "metadata ignores sequenced PR sync state before a sequence-less reattach" do
    events = [
      progress_event(
        "branch",
        1,
        %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/wp-1", "head_sha" => "head-a"},
        ~U[2026-05-01 00:00:00Z]
      ),
      progress_event(
        "attach-pr",
        2,
        %{
          "type" => "pr",
          "source_tool" => "attach_pr",
          "repository" => "nextide/symphony-plus-plus",
          "number" => 17,
          "head_sha" => "head-a"
        },
        ~U[2026-05-01 00:00:01Z]
      ),
      progress_event(
        "sync-pr",
        3,
        %{
          "type" => "pr",
          "source_tool" => "sync_pr",
          "repository" => "nextide/symphony-plus-plus",
          "number" => 17,
          "head_sha" => "head-a",
          "check_summary" => %{"status" => "success"}
        },
        ~U[2026-05-01 00:00:02Z]
      ),
      progress_event(
        "sequence-less-reattach",
        nil,
        %{
          "type" => "pr",
          "source_tool" => "attach_pr",
          "repository" => "nextide/symphony-plus-plus",
          "number" => 17,
          "head_sha" => "head-a"
        },
        ~U[2026-05-01 00:00:03Z]
      )
    ]

    refute MetadataProjection.current_pr_state_present?(events, "head-a")
    metadata = MetadataProjection.metadata(events)
    assert metadata.pr["source_tool"] == "attach_pr"
    refute Map.has_key?(metadata.pr, "check_summary")
  end

  defp progress_event(id, sequence, payload, created_at \\ nil) do
    %ProgressEvent{
      id: id,
      sequence: sequence,
      payload: payload,
      created_at: created_at || DateTime.add(~U[2026-05-01 00:00:00Z], sequence, :second)
    }
  end
end
