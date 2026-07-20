defmodule SymphonyElixir.SymphonyPlusPlus.RepoIdentityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.TestSupport

  test "preserves owner-qualified identity when no bare alias is present" do
    catalog = RepoIdentity.catalog(["alpha/shared"])

    assert RepoIdentity.fields(catalog, "alpha/shared") == %{
             repo_key: "alpha/shared",
             repo_display: "alpha/shared",
             repo_remote: "alpha/shared",
             repo_aliases: ["alpha/shared"]
           }
  end

  test "keeps untrusted bare and owner-qualified repos separate" do
    catalog = RepoIdentity.catalog(["shared", "alpha/shared"])

    assert RepoIdentity.fields(catalog, "shared") == %{
             repo_key: "shared",
             repo_display: "shared",
             repo_remote: nil,
             repo_aliases: ["shared"]
           }

    assert RepoIdentity.fields(catalog, "alpha/shared") == %{
             repo_key: "alpha/shared",
             repo_display: "alpha/shared",
             repo_remote: "alpha/shared",
             repo_aliases: ["alpha/shared"]
           }
  end

  test "keeps bare aliases separate when owner-qualified repos conflict" do
    catalog =
      RepoIdentity.catalog(
        ["shared", "alpha/shared", "beta/shared"],
        trusted_remotes: ["https://github.com/alpha/shared.git"]
      )

    assert RepoIdentity.fields(catalog, "shared") == %{
             repo_key: "shared",
             repo_display: "shared",
             repo_remote: nil,
             repo_aliases: ["shared"]
           }

    assert RepoIdentity.fields(catalog, "alpha/shared") == %{
             repo_key: "alpha/shared",
             repo_display: "alpha/shared",
             repo_remote: "alpha/shared",
             repo_aliases: ["alpha/shared"]
           }

    assert RepoIdentity.fields(catalog, "beta/shared") == %{
             repo_key: "beta/shared",
             repo_display: "beta/shared",
             repo_remote: "beta/shared",
             repo_aliases: ["beta/shared"]
           }
  end

  test "merges bare aliases only for trusted owner-qualified remotes" do
    catalog =
      RepoIdentity.catalog(
        ["symphony-plus-plus", "Pimpmuckl/symphony-plus-plus"],
        trusted_remotes: ["https://github.com/Pimpmuckl/symphony-plus-plus.git"]
      )

    assert RepoIdentity.fields(catalog, "symphony-plus-plus") == %{
             repo_key: "symphony-plus-plus",
             repo_display: "symphony-plus-plus",
             repo_remote: "Pimpmuckl/symphony-plus-plus",
             repo_aliases: ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]
           }

    assert RepoIdentity.fields(catalog, "Pimpmuckl/symphony-plus-plus") == %{
             repo_key: "symphony-plus-plus",
             repo_display: "symphony-plus-plus",
             repo_remote: "Pimpmuckl/symphony-plus-plus",
             repo_aliases: ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]
           }
  end

  test "accepts ssh GitHub remotes as trusted aliases" do
    catalog =
      RepoIdentity.catalog(
        ["symphony-plus-plus", "Pimpmuckl/symphony-plus-plus"],
        trusted_remotes: ["ssh://git@github.com/Pimpmuckl/symphony-plus-plus.git"]
      )

    assert RepoIdentity.fields(catalog, "symphony-plus-plus") == %{
             repo_key: "symphony-plus-plus",
             repo_display: "symphony-plus-plus",
             repo_remote: "Pimpmuckl/symphony-plus-plus",
             repo_aliases: ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]
           }
  end

  test "scope match accepts owner-qualified remotes for bare repos" do
    assert RepoIdentity.scope_match?("symphony-plus-plus", "https://github.com/Pimpmuckl/symphony-plus-plus.git", trusted_remotes: ["https://github.com/Pimpmuckl/symphony-plus-plus.git"])

    assert RepoIdentity.scope_match?("symphony-plus-plus", "git@github.com:Pimpmuckl/symphony-plus-plus.git", trusted_remotes: ["ssh://git@github.com/Pimpmuckl/symphony-plus-plus.git"])
  end

  test "scope match rejects owner and repo-name conflicts" do
    refute RepoIdentity.scope_match?("Pimpmuckl/symphony-plus-plus", "https://github.com/elsewhere/symphony-plus-plus.git")
    refute RepoIdentity.scope_match?("symphony-plus-plus", "https://github.com/Pimpmuckl/symphony-plus-plus.git")
    refute RepoIdentity.scope_match?("frontend", "https://github.com/other/frontend.git")

    refute RepoIdentity.scope_match?("frontend", "https://github.com/other/frontend.git", trusted_remotes: ["https://github.com/Pimpmuckl/frontend.git"])

    refute RepoIdentity.scope_match?("symphony-plus-plus", "https://github.com/Pimpmuckl/other-repo.git")
  end

  test "scope match rejects bare repos when trusted remotes make the bare name ambiguous" do
    refute RepoIdentity.scope_match?("shared", "https://github.com/alpha/shared.git",
             trusted_remotes: [
               "https://github.com/alpha/shared.git",
               "https://github.com/beta/shared.git"
             ]
           )
  end

  test "scope match preserves exact owner-qualified matches when trusted remotes conflict" do
    assert RepoIdentity.scope_match?("alpha/shared", "https://github.com/alpha/shared.git",
             trusted_remotes: [
               "https://github.com/alpha/shared.git",
               "https://github.com/beta/shared.git"
             ]
           )
  end

  test "derives canonical identity from existing local git repo paths" do
    origin = "https://github.com/Pimpmuckl/nextide-saas-live-chat.git"
    repo_path = TestSupport.git_repo_with_origin_fixture!(origin, prefix: "sympp-repo-identity")
    catalog = RepoIdentity.catalog([repo_path], local_path_remotes?: true)

    expected = %{
      repo_key: "nextide-saas-live-chat",
      repo_display: "nextide-saas-live-chat",
      repo_remote: "Pimpmuckl/nextide-saas-live-chat",
      repo_aliases:
        Enum.sort_by(
          [repo_path, "nextide-saas-live-chat", "Pimpmuckl/nextide-saas-live-chat"],
          &String.downcase/1
        )
    }

    assert RepoIdentity.fields(catalog, repo_path) == expected
  end

  test "collapses matching raw remote bare alias and local path origin" do
    origin = "https://github.com/Pimpmuckl/nextide-saas-vod-intelligence.git"
    repo_path = TestSupport.git_repo_with_origin_fixture!(origin, prefix: "sympp-repo-identity-mixed")

    catalog =
      RepoIdentity.catalog(
        ["Pimpmuckl/nextide-saas-vod-intelligence", "nextide-saas-vod-intelligence", repo_path],
        local_path_remotes?: true
      )

    expected_remote = %{
      repo_key: "nextide-saas-vod-intelligence",
      repo_display: "nextide-saas-vod-intelligence",
      repo_remote: "Pimpmuckl/nextide-saas-vod-intelligence",
      repo_aliases:
        Enum.sort_by(
          ["Pimpmuckl/nextide-saas-vod-intelligence", "nextide-saas-vod-intelligence"],
          &String.downcase/1
        )
    }

    expected_path = %{
      expected_remote
      | repo_aliases:
          Enum.sort_by(
            [repo_path, "nextide-saas-vod-intelligence", "Pimpmuckl/nextide-saas-vod-intelligence"],
            &String.downcase/1
          )
    }

    assert RepoIdentity.fields(catalog, "Pimpmuckl/nextide-saas-vod-intelligence") == expected_remote
    assert RepoIdentity.fields(catalog, "nextide-saas-vod-intelligence") == expected_remote
    assert RepoIdentity.fields(catalog, repo_path) == expected_path
  end

  test "does not promote path origin trust without matching explicit remote" do
    origin = "https://github.com/Pimpmuckl/nextide-saas-vod-intelligence.git"
    repo_path = TestSupport.git_repo_with_origin_fixture!(origin, prefix: "sympp-repo-identity-path-only")

    catalog =
      RepoIdentity.catalog(
        ["nextide-saas-vod-intelligence", repo_path],
        local_path_remotes?: true
      )

    assert RepoIdentity.fields(catalog, "nextide-saas-vod-intelligence") == %{
             repo_key: "nextide-saas-vod-intelligence",
             repo_display: "nextide-saas-vod-intelligence",
             repo_remote: nil,
             repo_aliases: ["nextide-saas-vod-intelligence"]
           }

    assert RepoIdentity.fields(catalog, repo_path) == %{
             repo_key: "nextide-saas-vod-intelligence",
             repo_display: "nextide-saas-vod-intelligence",
             repo_remote: "Pimpmuckl/nextide-saas-vod-intelligence",
             repo_aliases:
               Enum.sort_by(
                 [repo_path, "nextide-saas-vod-intelligence", "Pimpmuckl/nextide-saas-vod-intelligence"],
                 &String.downcase/1
               )
           }
  end

  test "derives canonical identity from local bare git repo paths" do
    origin = "https://github.com/Pimpmuckl/nextide-saas-live-chat.git"
    repo_path = TestSupport.unique_tmp_path("sympp-repo-identity-bare") <> ".git"

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(repo_path) end)

    File.mkdir_p!(repo_path)
    TestSupport.git_output!(repo_path, ["init", "--bare"])
    TestSupport.git_output!(repo_path, ["remote", "add", "origin", origin])

    catalog = RepoIdentity.catalog([repo_path], local_path_remotes?: true)

    assert RepoIdentity.fields(catalog, repo_path) == %{
             repo_key: "nextide-saas-live-chat",
             repo_display: "nextide-saas-live-chat",
             repo_remote: "Pimpmuckl/nextide-saas-live-chat",
             repo_aliases:
               Enum.sort_by(
                 [repo_path, "nextide-saas-live-chat", "Pimpmuckl/nextide-saas-live-chat"],
                 &String.downcase/1
               )
           }
  end

  test "keeps path-derived origin trust scoped to the path entry" do
    origin = "https://github.com/Pimpmuckl/nextide-saas-live-chat.git"
    repo_path = TestSupport.git_repo_with_origin_fixture!(origin, prefix: "sympp-repo-identity-scoped")

    catalog =
      RepoIdentity.catalog(
        [repo_path, "nextide-saas-live-chat", "Elsewhere/nextide-saas-live-chat"],
        local_path_remotes?: true
      )

    assert RepoIdentity.fields(catalog, repo_path) == %{
             repo_key: "pimpmuckl/nextide-saas-live-chat",
             repo_display: "Pimpmuckl/nextide-saas-live-chat",
             repo_remote: "Pimpmuckl/nextide-saas-live-chat",
             repo_aliases:
               Enum.sort_by(
                 [repo_path, "Pimpmuckl/nextide-saas-live-chat"],
                 &String.downcase/1
               )
           }

    assert RepoIdentity.fields(catalog, "nextide-saas-live-chat") == %{
             repo_key: "nextide-saas-live-chat",
             repo_display: "nextide-saas-live-chat",
             repo_remote: nil,
             repo_aliases: ["nextide-saas-live-chat"]
           }

    assert RepoIdentity.fields(catalog, "Elsewhere/nextide-saas-live-chat") == %{
             repo_key: "elsewhere/nextide-saas-live-chat",
             repo_display: "Elsewhere/nextide-saas-live-chat",
             repo_remote: "Elsewhere/nextide-saas-live-chat",
             repo_aliases: ["Elsewhere/nextide-saas-live-chat"]
           }
  end

  test "keeps same-name local checkout paths owner-qualified" do
    alice_path =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/alice/project.git",
        prefix: "sympp-repo-identity-alice"
      )

    bob_path =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/bob/project.git",
        prefix: "sympp-repo-identity-bob"
      )

    catalog = RepoIdentity.catalog([alice_path, bob_path], local_path_remotes?: true)

    assert RepoIdentity.fields(catalog, alice_path) == %{
             repo_key: "alice/project",
             repo_display: "alice/project",
             repo_remote: "alice/project",
             repo_aliases: Enum.sort_by([alice_path, "alice/project"], &String.downcase/1)
           }

    assert RepoIdentity.fields(catalog, bob_path) == %{
             repo_key: "bob/project",
             repo_display: "bob/project",
             repo_remote: "bob/project",
             repo_aliases: Enum.sort_by([bob_path, "bob/project"], &String.downcase/1)
           }
  end

  test "does not inherit parent origin from non-worktree gitdir files" do
    root = Path.join(System.tmp_dir!(), "sympp-repo-identity-gitdir-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "checkout")
    gitdir = Path.join([root, "super", ".git", "modules", "child"])
    parent_git = Path.join([root, "super", ".git"])

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(repo_path)
    File.mkdir_p!(gitdir)
    File.mkdir_p!(parent_git)
    File.write!(Path.join(repo_path, ".git"), "gitdir: #{gitdir}\n")
    File.write!(Path.join(parent_git, "config"), ~s([remote "origin"]\n\turl = https://github.com/parent/project.git\n))

    assert RepoIdentity.local_git_origin_remote(repo_path) == nil
  end

  test "does not read oversized gitdir pointer files" do
    root = Path.join(System.tmp_dir!(), "sympp-repo-identity-gitfile-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "checkout")
    gitdir = Path.join([root, ".git", "worktrees", "checkout"])

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(repo_path)
    File.mkdir_p!(gitdir)
    File.write!(Path.join(repo_path, ".git"), String.duplicate("x", 4_097))
    File.write!(Path.join(gitdir, "config"), ~s([remote "origin"]\n\turl = https://github.com/owner/project.git\n))

    assert RepoIdentity.local_git_origin_remote(repo_path) == nil
  end

  test "resolves origin remotes from included git config files" do
    repo_path =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/placeholder/project.git",
        prefix: "sympp-repo-identity-include"
      )

    git_dir = Path.join(repo_path, ".git")
    include_path = git_dir |> Path.join("origin.inc") |> String.replace("\\", "/")

    TestSupport.git_output!(repo_path, ["remote", "remove", "origin"])
    File.write!(Path.join(git_dir, "config"), File.read!(Path.join(git_dir, "config")) <> "\n[include]\n\tpath = #{include_path}\n")
    File.write!(include_path, ~s([remote "origin"]\n\turl = https://github.com/included/project.git\n))

    assert RepoIdentity.local_git_origin_remote(repo_path) == "https://github.com/included/project.git"
  end

  test "resolves origin remotes from matching includeIf gitdir config files" do
    repo_path =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/placeholder/project.git",
        prefix: "sympp-repo-identity-includeif"
      )

    git_dir = Path.join(repo_path, ".git")
    include_path = git_dir |> Path.join("origin.inc") |> String.replace("\\", "/")
    gitdir_pattern = String.replace(git_dir, "\\", "/")

    TestSupport.git_output!(repo_path, ["remote", "remove", "origin"])

    File.write!(
      Path.join(git_dir, "config"),
      File.read!(Path.join(git_dir, "config")) <> ~s(\n[includeIf "gitdir:#{gitdir_pattern}"]\n\tpath = #{include_path}\n)
    )

    File.write!(include_path, ~s([remote "origin"]\n\turl = https://github.com/include-if/project.git\n))

    assert RepoIdentity.local_git_origin_remote(repo_path) == "https://github.com/include-if/project.git"
  end

  test "resolves includeIf gitdir glob patterns" do
    repo_path =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/placeholder/project.git",
        prefix: "sympp-repo-identity-includeglob"
      )

    git_dir = Path.join(repo_path, ".git")
    include_path = git_dir |> Path.join("origin.inc") |> String.replace("\\", "/")
    root = Path.dirname(repo_path)
    gitdir_pattern = String.replace(root, "\\", "/") <> "/*/"

    TestSupport.git_output!(repo_path, ["remote", "remove", "origin"])

    File.write!(
      Path.join(git_dir, "config"),
      File.read!(Path.join(git_dir, "config")) <> ~s(\n[includeIf "gitdir:#{gitdir_pattern}"]\n\tpath = #{include_path}\n)
    )

    File.write!(include_path, ~s([remote "origin"]\n\turl = https://github.com/include-glob/project.git\n))

    assert RepoIdentity.local_git_origin_remote(repo_path) == "https://github.com/include-glob/project.git"
  end

  test "rejects extended UNC repo paths" do
    assert RepoIdentity.local_git_origin_remote("\\\\?\\UNC\\server\\share\\repo") == nil
  end
end
