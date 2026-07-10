alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, ToolCatalog, ToolResult}

measure = fn value ->
  bytes = value |> Jason.encode!() |> byte_size()
  %{"bytes" => bytes, "tokens_estimate" => div(bytes + 3, 4)}
end

profiles =
  for profile <- [:full, :worker, :architect, :coordinator, :solo], into: %{} do
    tools = ToolCatalog.startup_tool_specs(profile, Config.default(surface_profile: profile, source_revision: nil))
    {Atom.to_string(profile), Map.merge(%{"tools" => length(tools)}, measure.(%{"tools" => tools}))}
  end

claim =
  ToolResult.claim_tool_result(%{
    "status" => "ok",
    "tool" => "claim_local_assignment",
    "role" => "worker",
    "work_package_id" => "wp_example",
    "work_request_id" => "wr_example",
    "lease" => "created"
  })

read =
  %{"text" => String.duplicate("Package context line.\n", 40), "uri" => "sympp://work-packages/wp_example/context.md"}
  |> ToolResult.read_tool_result()
  |> ToolResult.canonical_agent_result()

progress =
  %{
    "progress_event" => %{
      "id" => "progress_1",
      "status" => "in_progress",
      "summary" => "Measured MCP payloads",
      "idempotency_key" => "progress:measure"
    }
  }
  |> ToolResult.tool_result()
  |> ToolResult.canonical_agent_result()

IO.write(Jason.encode!(%{"profiles" => profiles, "results" => %{"claim" => measure.(claim), "read" => measure.(read), "progress" => measure.(progress)}}))
