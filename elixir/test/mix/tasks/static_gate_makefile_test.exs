defmodule Mix.Tasks.StaticGateMakefileTest do
  use ExUnit.Case, async: true

  @elixir_root Path.expand("../../..", __DIR__)
  @repo_root Path.expand("..", @elixir_root)

  test "static alias keeps fast PR checks separate from expensive gates" do
    aliases = Mix.Project.config()[:aliases]

    assert aliases[:static] == ["format --check-formatted", "lint"]
    assert aliases[:lint] == ["specs.check", "credo --strict"]
    assert aliases[:hygiene] == ["code_quality.guard"]
  end

  test "Makefile splits fast CI from heavyweight gates" do
    makefile = File.read!(Path.join(@elixir_root, "Makefile"))

    assert target(makefile, "static") == "\n\t@$(MIX) static\n"
    assert target(makefile, "ci-static") =~ "ci-prepare\n\t$(call run_ci_step,static,$(MIX) static)"
    assert target(makefile, "ci-fast") =~ "ci-prepare\n\t$(call run_ci_step,static,$(MIX) static)"
    assert target(makefile, "ci-fast") =~ "$(call run_ci_step,test,$(MIX) test --exclude ci_slow)"
    assert makefile =~ "FAST_TEST_PARTITIONS ?= 9"
    assert makefile =~ "SLOW_TEST_PARTITIONS ?= 8"
    assert makefile =~ "SLOW_TEST_MAX_CASES ?= 4"

    assert target(makefile, "ci-test") =~
             "$(call run_ci_step,test,$(MIX) test --exclude ci_slow $(CI_TEST_PARTITION_FLAGS))"

    assert target(makefile, "ci-slow") =~
             "$(call run_ci_step,test-slow,$(MIX) test --exclude test --include ci_slow $(CI_SLOW_TEST_PARTITION_FLAGS) $(CI_SLOW_TEST_MAX_CASES_FLAGS))"

    assert target(makefile, "ci-dialyzer") =~
             "ci-prepare\n\t$(call run_ci_step,dialyzer-plt,$(MIX) dialyzer --plt)\n\t$(call run_ci_step,dialyzer,$(MIX) dialyzer $(CI_DIALYZER_FLAGS))"

    assert target(makefile, "ci-coverage") =~ "ci-prepare\n\t$(call run_ci_step,coverage,$(MIX) test --cover)"
    assert target(makefile, "ci-hygiene") =~ "\n\t$(call run_ci_step,hygiene,$(MIX) hygiene)"
    assert target(makefile, "all") == "ci-fast\n"
  end

  test "GitHub make-all shards ExUnit gates across native partitions" do
    workflow = File.read!(Path.join([@repo_root, ".github", "workflows", "make-all.yml"]))

    assert workflow =~ "needs:\n      - gates"
    refute workflow =~ "- slow-tests"
    assert workflow =~ "target: ci-static"
    assert workflow =~ "target: ci-dialyzer"
    assert workflow =~ "run: make ${{ matrix.target }}"
    assert workflow =~ "hashFiles('elixir/mix.exs')"
    assert workflow =~ "name: Cache dialyzer PLTs"
    assert workflow =~ "if: ${{ matrix.target == 'ci-dialyzer' }}"
    assert workflow =~ "key: ${{ runner.os }}-dialyzer-"
    assert workflow =~ "elixir/_build/dialyzer"
    assert workflow =~ "elixir/_build/*/dialyxir_*.plt.hash"
    assert workflow =~ "FAST_TEST_PARTITIONS: ${{ matrix.partitions }}"
    assert workflow =~ "SLOW_TEST_PARTITIONS: ${{ matrix.partitions }}"
    assert workflow =~ "MIX_TEST_PARTITION: ${{ matrix.partition }}"

    for partition <- 1..9 do
      assert workflow =~ "target: ci-test\n            partition: #{partition}\n            partitions: 9"
    end

    for partition <- 1..8 do
      assert workflow =~ "target: ci-slow\n            partition: #{partition}\n            partitions: 8"
    end
  end

  defp target(makefile, target) do
    pattern = ~r/^#{Regex.escape(target)}:(?: (?<dependency>.*))?\n(?<commands>(?:\t.*\n)*)/m

    case Regex.named_captures(pattern, makefile) do
      %{"commands" => commands, "dependency" => dependency} -> "#{dependency}\n#{commands}"
      nil -> flunk("missing Makefile target #{target}")
    end
  end
end
