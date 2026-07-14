Code.require_file("../../../support/symphony_plus_plus/agent_format_fixtures.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.AgentFormat.ToonTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.Toon
  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.AgentFormatFixtures
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  test "encodes the README tabular array shape" do
    assert Toon.encode(%{"users" => [%{"id" => 1, "name" => "Ada"}, %{"id" => 2, "name" => "Linus"}]}) == """
           users[2]{id,name}:
             1,Ada
             2,Linus\
           """
  end

  test "encodes nested maps, primitive lists, and uniform rows deterministically" do
    payload = %{
      "context" => %{
        "task" => "Our favorite hikes together",
        "location" => "Boulder",
        "season" => "spring_2025"
      },
      "friends" => ["ana", "luis", "sam"],
      "hikes" => [
        %{"id" => 1, "name" => "Blue Lake Trail", "distanceKm" => 7.5, "elevationGain" => 320, "companion" => "ana", "wasSunny" => true},
        %{"id" => 2, "name" => "Ridge Overlook", "distanceKm" => 9.2, "elevationGain" => 540, "companion" => "luis", "wasSunny" => false}
      ]
    }

    assert Toon.encode(payload) == """
           context:
             location: Boulder
             season: spring_2025
             task: Our favorite hikes together
           friends[3]: ana,luis,sam
           hikes[2]{companion,distanceKm,elevationGain,id,name,wasSunny}:
             ana,7.5,320,1,Blue Lake Trail,true
             luis,9.2,540,2,Ridge Overlook,false\
           """
  end

  test "quotes strings only when needed to preserve primitive types, structure, and delimiters" do
    line_separator = "line" <> <<0x2028::utf8>> <> "sep"

    flags = [true, false, nil, "true", "05", "- [ ] validate", "x,y", "x: y", <<1>>, line_separator]

    assert Toon.encode(%{"flags" => flags}) == """
           flags[10]: true,false,null,"true","05","- [ ] validate","x,y","x: y","\\u0001","line\\u2028sep"\
           """
  end

  test "emits canonical float values" do
    assert Toon.encode(%{"values" => [1.0, 1.2, 1.0e-5, -0.0, 1.0e-7, 1.0e21]}) == """
           values[6]: 1,1.2,0.00001,0,1e-7,1e21\
           """
  end

  test "encodes numeric primitive lists when they are not printable-charlist ambiguous" do
    assert Toon.encode(%{"scores" => [1, 2, 300]}) == """
           scores[3]: 1,2,300\
           """
  end

  test "encodes empty primitive lists without charlist ambiguity" do
    assert Toon.encode(%{"codes" => []}) == """
           codes[0]:\
           """
  end

  test "quotes hyphenated keys in fields and row headers" do
    assert Toon.encode(%{"work-package-id" => "wp_1", "rows" => [%{"head-sha" => "abc123"}]}) == """
           rows[1]{"head-sha"}:
             abc123
           "work-package-id": wp_1\
           """
  end

  test "emits empty maps as empty TOON object fields" do
    assert Toon.encode(%{"meta" => %{}}) == """
           meta:\
           """
  end

  test "emits empty root maps as empty documents" do
    assert Toon.encode(%{}) == ""
  end

  test "puts nested primitive array headers on the list item line" do
    assert Toon.encode(%{"matrix" => [[1, 2, 300], [3, 4]]}) == """
           matrix[2]:
             - [3]: 1,2,300
             - [2]: 3,4\
           """
  end

  test "expands nested arrays of objects in list item position" do
    assert Toon.encode(%{"groups" => [[%{"id" => 1, "name" => "Ada"}], [%{"id" => 2, "name" => "Linus"}]]}) == """
           groups[2]:
             - [1]:
               - id: 1
                 name: Ada
             - [1]:
               - id: 2
                 name: Linus\
           """
  end

  test "rejects non-JSON and ambiguous Elixir values before serializing prompt text" do
    assert_raise ArgumentError, ~r/charlists/, fn ->
      Toon.encode(%{"msg" => ~c"hi"})
    end

    assert_raise ArgumentError, ~r/printable integer arrays/, fn ->
      Toon.encode(%{"codes" => [65, 66]})
    end

    assert_raise ArgumentError, ~r/struct/, fn ->
      Toon.encode(%{"uri" => URI.parse("https://example.invalid/path")})
    end
  end

  test "preserves redaction markers without special handling" do
    assert Toon.encode(%{"token" => "<redacted>", "url" => "https://example.invalid/path"}) == """
           token: <redacted>
           url: "https://example.invalid/path"\
           """
  end

  test "fixtures a representative work package context payload" do
    payload = AgentFormatFixtures.work_package_context_payload()
    toon = Toon.encode(payload)

    assert toon == """
           acceptance[2]{done,source}:
             false,Serializer supports TOON rows
             false,Tests cover S++ fixtures
           allowed_file_globs[2]: elixir/lib/symphony_elixir/symphony_plus_plus/agent_format/**,elixir/test/symphony_elixir/symphony_plus_plus/agent_format/**
           base_branch: main
           branch: feat/sympp-toon-agent-format
           required_gates[3]: package_acceptance,focused_tests,review_normal
           status: ready_for_worker
           work_package_id: wp_ROiof_-E5ZQP9J0TKdwVIQ\
           """

    assert byte_size(toon) < byte_size(Jason.encode!(payload))
  end

  test "fixtures a representative MCP context payload" do
    payload = AgentFormatFixtures.mcp_context_payload()
    toon = Toon.encode(payload)

    assert toon == """
           resources[2]: "sympp://assignment/current","sympp://work-packages/wp_ROiof_-E5ZQP9J0TKdwVIQ/context.md"
           tools[3]{name,surface}:
             get_current_assignment,worker
             read_context,worker
             append_progress,worker
           transport:
             mode: http
             session_scope: claimed_worker\
           """

    assert byte_size(toon) < byte_size(Jason.encode!(payload))
  end

  test "review payload exposes the generic requirement from state" do
    review = %{"type" => "human", "args" => %{"team" => "maintainers"}}

    work_package =
      struct(
        WorkPackage,
        WorkPackageFactory.attrs(
          id: "SYMPP-TOON-REVIEW",
          kind: "mcp",
          status: "ci_waiting",
          policy_template: "mcp",
          review_requirement: review
        )
      )

    state = %State{work_package: work_package}

    assert {:ok, payload} = WorkerContext.virtual_file_payload(state, "review.md", [])
    assert get_in(payload, ["review", "requirement"]) == review
    assert get_in(payload, ["review", "completion"]) == nil
  end

  test "falls back for non-uniform rows and shows when compact JSON can be preferable" do
    payload = AgentFormatFixtures.non_uniform_progress_payload()
    toon = Toon.encode(payload)

    assert toon == """
           progress[2]:
             - status: prepared
               summary: Prepared WorkPackage worktree
             - details:
                 review: pending
                 suite: normal
               status: in_progress
               summary: Review Suite pending\
           """

    assert byte_size(Jason.encode!(payload)) <= byte_size(toon)
  end

  test "does not mutate canonical payloads" do
    payload = AgentFormatFixtures.work_package_context_payload()
    before_encode = :erlang.term_to_binary(payload)

    assert is_binary(Toon.encode(payload))
    assert :erlang.term_to_binary(payload) == before_encode
  end
end
