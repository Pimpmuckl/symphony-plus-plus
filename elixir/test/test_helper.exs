System.put_env("SYMPP_OPEN_DASHBOARD", "0")
ExUnit.start()

if System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1" do
  existing_excludes = Keyword.get(ExUnit.configuration(), :exclude, [])
  ExUnit.configure(exclude: Enum.uniq(existing_excludes ++ [:live_e2e]))
end

Code.require_file("support/github_test_support.exs", __DIR__)
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/work_package_factory.exs", __DIR__)
Code.require_file("support/canonical_work_package_fixtures.ex", __DIR__)
