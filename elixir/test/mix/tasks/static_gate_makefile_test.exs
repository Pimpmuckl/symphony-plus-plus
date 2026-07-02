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
    assert makefile =~ "TEST_COMPILE_CMD := MIX_ENV=test $(MIX) compile"
    assert makefile =~ "TEST_COMPILE_CMD := set MIX_ENV=test&& $(MIX) compile"

    assert target(makefile, "ci-test-prepare") =~
             "ci-prepare\n\t$(call run_ci_step,test-compile,$(TEST_COMPILE_CMD))"

    assert target(makefile, "ci-test") == "ci-test-prepare ci-test-partition\n"

    assert target(makefile, "ci-test-partition") =~
             "$(call run_ci_step,test,$(MIX) test --exclude ci_slow $(CI_TEST_PARTITION_FLAGS))"

    assert target(makefile, "ci-slow") == "ci-test-prepare ci-slow-partition\n"

    assert target(makefile, "ci-slow-partition") =~
             "$(call run_ci_step,test-slow,$(MIX) test --exclude test --include ci_slow $(CI_SLOW_TEST_PARTITION_FLAGS) $(CI_SLOW_TEST_MAX_CASES_FLAGS))"

    assert target(makefile, "ci-dialyzer") =~
             "ci-prepare\n\t$(call run_ci_step,dialyzer-plt,$(MIX) dialyzer --plt)\n\t$(call run_ci_step,dialyzer,$(MIX) dialyzer $(CI_DIALYZER_FLAGS))"

    assert target(makefile, "ci-coverage") =~ "ci-prepare\n\t$(call run_ci_step,coverage,$(MIX) test --cover)"
    assert target(makefile, "ci-hygiene") =~ "\n\t$(call run_ci_step,hygiene,$(MIX) hygiene)"
    assert target(makefile, "all") == "ci-fast\n"
  end

  test "GitHub make-all shards ExUnit gates across native partitions" do
    workflow = File.read!(Path.join([@repo_root, ".github", "workflows", "make-all.yml"]))

    assert workflow =~ "needs:\n      - static\n      - test-groups\n      - dialyzer"
    assert workflow =~ "strategy:"
    assert workflow =~ "matrix:"
    refute workflow =~ "target: ci-test\n"
    refute workflow =~ "target: ci-slow\n"
    assert workflow =~ "name: test 1-3/9"
    assert workflow =~ "name: test 4-6/9"
    assert workflow =~ "name: test 7-9/9"
    assert workflow =~ "name: slow test 1-4/8"
    assert workflow =~ "name: slow test 5-8/8"
    assert workflow =~ "parallel:"
    assert workflow =~ "run: make ci-static"
    assert workflow =~ "run: make ci-dialyzer"
    assert workflow =~ "run: make ci-test-prepare"
    assert workflow =~ "target: ci-test-partition"
    assert workflow =~ "target: ci-slow-partition"
    assert workflow =~ "run: make ${{ matrix.target }}"
    assert workflow =~ "hashFiles('elixir/mix.exs')"
    assert workflow =~ "name: Cache dialyzer PLTs"
    assert workflow =~ "key: ${{ runner.os }}-dialyzer-"
    assert workflow =~ "elixir/_build/dialyzer"
    assert workflow =~ "elixir/_build/*/dialyxir_*.plt.hash"
    assert workflow =~ ~s(needs['test-groups'].result)

    assert workflow =~
             ~s(label: test\n            partitions: "9"\n            gate_prefix: fast\n            partition_1: "1")

    assert workflow =~
             ~s(label: test\n            partitions: "9"\n            gate_prefix: fast\n            partition_1: "4")

    assert workflow =~
             ~s(label: test\n            partitions: "9"\n            gate_prefix: fast\n            partition_1: "7")

    assert workflow =~
             ~s(label: slow test\n            partitions: "8"\n            gate_prefix: slow\n            partition_1: "1")

    assert workflow =~
             ~s(label: slow test\n            partitions: "8"\n            gate_prefix: slow\n            partition_1: "5")

    for partition <- 1..4 do
      assert workflow =~
               "MIX_TEST_PARTITION: ${{ matrix.partition_#{partition} }}"

      assert workflow =~
               "GATE_RUN_ID: ${{ matrix.gate_prefix }}-${{ matrix.partition_#{partition} }}"
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
