defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestScopeConstraintsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ScopeConstraints

  test "accepts owned globs proven equal to or beneath an allowed path" do
    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => []},
               ["elixir/lib", "elixir/lib/**/*.ex"]
             )
  end

  test "treats missing or empty allowed paths as unrestricted while enforcing forbidden paths" do
    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"forbidden_paths" => ["elixir/lib/test_support"]},
               ["elixir/lib/*_test.exs"]
             )

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => [], "forbidden_paths" => ["elixir/lib/test_support"]},
               ["apps/web/**/*.js"]
             )

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(%{}, ["**/foo"])

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(%{"allowed_paths" => []}, ["**"])

    assert {:error, [{:forbidden_path_overlap, "elixir/lib/test_support/*.ex", "elixir/lib/test_support"}]} =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => [], "forbidden_paths" => ["elixir/lib/test_support"]},
               ["elixir/lib/test_support/*.ex"]
             )
  end

  test "unwraps map-backed WorkRequest constraints before validating owned globs" do
    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"constraints" => %{"allowed_paths" => ["elixir/lib"]}},
               ["elixir/lib/foo.ex"]
             )

    assert {:error, [{:outside_allowed_paths, "apps/web/file.ex", ["elixir/lib"]}]} =
             ScopeConstraints.validate_allowed_file_globs(
               %{constraints: %{"allowed_paths" => ["elixir/lib"]}},
               ["apps/web/file.ex"]
             )

    assert {:error, [{:invalid_constraints, :constraints}]} =
             ScopeConstraints.validate_allowed_file_globs(%{"constraints" => "not a map"}, ["elixir/lib/foo.ex"])
  end

  test "rejects malformed constraint lists" do
    assert {:error, [{:invalid_constraints, :allowed_paths}]} =
             ScopeConstraints.validate_allowed_file_globs(%{"allowed_paths" => "elixir/lib"}, ["elixir/lib/**/*.ex"])

    assert {:error, [{:invalid_constraints, :forbidden_paths}]} =
             ScopeConstraints.validate_allowed_file_globs(%{"forbidden_paths" => ["elixir/lib", " "]}, ["elixir/lib/**/*.ex"])

    assert {:error, [{:invalid_allowed_file_globs, :allowed_file_globs}]} =
             ScopeConstraints.validate_allowed_file_globs(%{}, ["elixir/lib/**/*.ex", :not_a_string])
  end

  test "rejects non repo-relative slash-separated path and glob inputs" do
    constraints = %{"allowed_paths" => ["elixir/lib"]}

    assert {:error, [{:invalid_path, :allowed_file_globs, "/elixir/lib/*.ex", :absolute_path}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["/elixir/lib/*.ex"])

    assert {:error, [{:invalid_path, :allowed_file_globs, "C:/repo/file.ex", :drive_qualified_path}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["C:/repo/file.ex"])

    assert {:error, [{:invalid_path, :allowed_file_globs, "elixir\\lib\\*.ex", :backslash_separator}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["elixir\\lib\\*.ex"])

    assert {:error, [{:invalid_path, :allowed_file_globs, "elixir//lib/*.ex", :empty_segment}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["elixir//lib/*.ex"])

    assert {:error, [{:invalid_path, :allowed_file_globs, "elixir/lib/../config/*.exs", :dot_segment}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["elixir/lib/../config/*.exs"])

    assert {:error, [{:invalid_path, :allowed_file_globs, "elixir/lib/**.ex", :unsupported_globstar}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["elixir/lib/**.ex"])

    assert {:error, [{:invalid_path, :allowed_file_globs, "scripts/**deploy**", :unsupported_globstar}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["scripts/**deploy**"])
  end

  test "rejects owned globs that are not provably contained by allowed paths" do
    constraints = %{"allowed_paths" => ["elixir/lib"]}

    assert {:error, [{:outside_allowed_paths, "elixir/lib*/*.ex", ["elixir/lib"]}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["elixir/lib*/*.ex"])

    assert {:error, [{:outside_allowed_paths, "elixir/*/*.ex", ["elixir/lib"]}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["elixir/*/*.ex"])
  end

  test "accepts provable globbed allowed-path containment" do
    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["elixir/**/foo"]},
               ["elixir/bar/baz/foo/*.ex"]
             )

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["elixir/**/foo"]},
               ["elixir/foo/*.ex"]
             )

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["elixir/lib/a*"]},
               ["elixir/lib/ab*"]
             )

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["elixir/lib/*.*"]},
               ["elixir/lib/*.ex"]
             )
  end

  test "does not treat terminal wildcard allow entries as recursive prefixes" do
    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["*"]},
               ["foo"]
             )

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["apps/?"]},
               ["apps/a"]
             )

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["elixir/lib/*.ex"]},
               ["elixir/lib/foo.ex"]
             )

    assert {:error, [{:outside_allowed_paths, "foo/bar.ex", ["*"]}]} =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["*"]},
               ["foo/bar.ex"]
             )

    assert {:error, [{:outside_allowed_paths, "apps/a/file.ex", ["apps/?"]}]} =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["apps/?"]},
               ["apps/a/file.ex"]
             )

    assert {:error, [{:outside_allowed_paths, "elixir/lib/foo.ex/child", ["elixir/lib/*.ex"]}]} =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["elixir/lib/*.ex"]},
               ["elixir/lib/foo.ex/child"]
             )

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["apps/?/**"]},
               ["apps/a/file.ex"]
             )

    assert {:error, [{:outside_allowed_paths, "**/foo", ["*"]}]} =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["*"]},
               ["**/foo"]
             )

    assert {:error, [{:outside_allowed_paths, "**", ["*"]}]} =
             ScopeConstraints.validate_allowed_file_globs(%{"allowed_paths" => ["*"]}, ["**"])

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["elixir/**"]},
               ["elixir/**/foo"]
             )

    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"allowed_paths" => ["*/**"]},
               ["**/foo", "**"]
             )
  end

  test "rejects owned globs that can overlap forbidden paths or their descendants" do
    constraints = %{"forbidden_paths" => ["elixir/lib/test_support"]}

    assert {:error, [{:forbidden_path_overlap, "elixir", "elixir/**"}]} =
             ScopeConstraints.validate_allowed_file_globs(%{"forbidden_paths" => ["elixir/**"]}, ["elixir"])

    assert {:error, [{:forbidden_path_overlap, "elixir/lib/**/*", "elixir/lib/test_support"}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["elixir/lib/**/*"])

    assert {:error, [{:forbidden_path_overlap, "elixir/lib/test_support/*.ex", "elixir/lib/test_support"}]} =
             ScopeConstraints.validate_allowed_file_globs(constraints, ["elixir/lib/test_support/*.ex"])

    assert :ok = ScopeConstraints.validate_allowed_file_globs(constraints, ["elixir/lib/*_test.exs"])
  end

  test "conservatively rejects wildcard segment widening that can overlap forbidden paths" do
    assert {:error, [{:forbidden_path_overlap, "elixir/lib*/*.ex", "elixir/lib_private"}]} =
             ScopeConstraints.validate_allowed_file_globs(
               %{"forbidden_paths" => ["elixir/lib_private"]},
               ["elixir/lib*/*.ex"]
             )
  end

  test "does not reject disjoint wildcarded forbidden paths" do
    assert :ok =
             ScopeConstraints.validate_allowed_file_globs(
               %{"forbidden_paths" => ["elixir/lib/f*"]},
               ["elixir/lib/b*"]
             )
  end
end
