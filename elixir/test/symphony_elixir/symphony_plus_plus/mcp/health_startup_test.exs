defmodule SymphonyElixir.SymphonyPlusPlus.MCP.HealthStartupTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.Health

  @cache_key {Health, :mcp_contract_identity}

  setup do
    previous = :persistent_term.get(@cache_key, :unset)
    :persistent_term.erase(@cache_key)

    on_exit(fn ->
      if previous == :unset,
        do: :persistent_term.erase(@cache_key),
        else: :persistent_term.put(@cache_key, previous)
    end)
  end

  test "caches the immutable MCP contract identity for backend readiness" do
    identity = Health.mcp_contract_identity()

    assert identity == :persistent_term.get(@cache_key)
    assert identity == Health.mcp_contract_identity()
    assert identity["fingerprint"] =~ ~r/^[0-9a-f]{64}$/
  end
end
