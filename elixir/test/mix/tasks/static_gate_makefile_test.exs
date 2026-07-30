defmodule Mix.Tasks.StaticGateMakefileTest do
  use ExUnit.Case, async: true

  @elixir_root Path.expand("../../..", __DIR__)
  @repo_root Path.expand("..", @elixir_root)

  test "static alias keeps fast PR checks separate from expensive gates" do
    aliases = Mix.Project.config()[:aliases]

    assert aliases[:static] == ["format --check-formatted", "lint"]
    assert aliases[:lint] == ["specs.check", "credo --strict"]
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

    assert target(makefile, "ci-test") == "ci-prepare ci-test-run\n"

    assert target(makefile, "ci-test-run") =~
             "$(call run_ci_step,test,$(MIX) test --exclude ci_slow $(CI_TEST_PARTITION_FLAGS))"

    assert target(makefile, "ci-slow") =~
             "ci-prepare\n\t$(call run_ci_step,test-slow,$(MIX) test --exclude test --include ci_slow $(CI_SLOW_TEST_PARTITION_FLAGS) $(CI_SLOW_TEST_MAX_CASES_FLAGS))"

    refute makefile =~ "ci-slow-run"

    assert target(makefile, "ci-dialyzer") =~
             "ci-prepare\n\t$(call run_ci_step,dialyzer-plt,$(MIX) dialyzer --plt)\n\t$(call run_ci_step,dialyzer,$(MIX) dialyzer $(CI_DIALYZER_FLAGS))"

    assert target(makefile, "ci-coverage") =~ "ci-prepare\n\t$(call run_ci_step,coverage,$(MIX) test --cover)"
    assert target(makefile, "all") == "ci-fast\n"
  end

  test "GitHub make-all keeps single gates plain and pairs fast ExUnit gates" do
    workflow = File.read!(Path.join([@repo_root, ".github", "workflows", "make-all.yml"]))
    [single_gates, rest] = String.split(workflow, "  parallel-gates:\n", parts: 2)
    [parallel_gates, make_all] = String.split(rest, "  make-all:\n", parts: 2)

    assert workflow =~ "needs:\n      - single-gates\n      - parallel-gates"
    assert make_all =~ "needs.single-gates.result"
    assert make_all =~ "needs.parallel-gates.result"
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

    refute single_gates =~ "parallel:"
    assert parallel_gates =~ "parallel:"
    refute workflow =~ "matrix.mode"
    assert parallel_gates =~ "make ci-prepare"
    assert parallel_gates =~ "MIX_ENV=test mix deps.compile --include-children floki lazy_html"
    assert parallel_gates =~ "cp -a _build \"_p/${{ matrix.gate_id }}/b${{ matrix.partition_1 }}\""
    assert parallel_gates =~ "run: make ci-test-run"
    assert parallel_gates =~ "MIX_BUILD_PATH: _p/${{ matrix.gate_id }}/b${{ matrix.partition_1 }}"
    assert parallel_gates =~ "TMPDIR: /tmp/spp-tmp-${{ matrix.gate_id }}-${{ matrix.partition_1 }}"

    for {left, right} <- [{1, 2}, {3, 4}, {5, 6}, {7, 8}] do
      assert parallel_gates =~
               "partitions: 9\n            partition_1: #{left}\n            partition_2: #{right}"
    end

    assert single_gates =~ "target: ci-test\n            partition: 9\n            partitions: 9"

    for partition <- 1..8 do
      assert single_gates =~
               "target: ci-slow\n            partition: #{partition}\n            partitions: 8"
    end

    refute workflow =~ "ci-slow-run"
  end

  defp target(makefile, target) do
    pattern = ~r/^#{Regex.escape(target)}:(?: (?<dependency>.*))?\n(?<commands>(?:\t.*\n)*)/m

    case Regex.named_captures(pattern, makefile) do
      %{"commands" => commands, "dependency" => dependency} -> "#{dependency}\n#{commands}"
      nil -> flunk("missing Makefile target #{target}")
    end
  end
end
