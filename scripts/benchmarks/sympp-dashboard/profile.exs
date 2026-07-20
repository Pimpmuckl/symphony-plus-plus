defmodule DashboardPayloadProfile do
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard

  def run(database, samples) do
    {:ok, repo} = Repo.start_link(database: Path.expand(database), name: nil, pool_size: 1, log: false)
    previous_repo = Repo.put_dynamic_repo(repo)

    try do
      endpoints = [
        dashboard: &LocalOperatorDashboard.operator_dashboard_payload/1,
        deferred: &LocalOperatorDashboard.operator_dashboard_deferred_payload/1,
        hydrated: &LocalOperatorDashboard.operator_dashboard_hydrated_payload/1
      ]

      profile =
        Map.new(endpoints, fn {name, load} ->
          measurements =
            Enum.map(1..samples, fn _index ->
              {assembly_us, {:ok, payload}} = :timer.tc(load, [Repo])
              {encoding_us, json} = :timer.tc(Jason, :encode!, [payload])
              %{assembly_ms: assembly_us / 1_000, encoding_ms: encoding_us / 1_000, bytes: byte_size(json)}
            end)

          {:ok, payload} = load.(Repo)

          {name,
           %{
             assembly_ms_p50: median(measurements, :assembly_ms),
             encoding_ms_p50: median(measurements, :encoding_ms),
             bytes: measurements |> hd() |> Map.fetch!(:bytes),
             largest_fields: largest_fields(payload)
           }}
        end)

      IO.puts(Jason.encode!(%{samples: samples, endpoints: profile}, pretty: true))
    after
      Repo.put_dynamic_repo(previous_repo)
      GenServer.stop(repo)
    end
  end

  defp median(measurements, key) do
    values = measurements |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sort()
    Enum.at(values, div(length(values), 2))
  end

  defp largest_fields(payload) do
    payload
    |> field_sizes([], %{})
    |> Enum.sort_by(fn {_path, bytes} -> -bytes end)
    |> Enum.take(20)
    |> Enum.map(fn {path, bytes} -> %{path: Enum.join(path, "."), bytes: bytes} end)
  end

  defp field_sizes(values, path, sizes) when is_list(values),
    do: Enum.reduce(values, sizes, &field_sizes(&1, path, &2))

  defp field_sizes(%_struct{}, _path, sizes), do: sizes

  defp field_sizes(value, path, sizes) when is_map(value) do
    Enum.reduce(value, sizes, fn {key, nested}, acc ->
      nested_path = path ++ [to_string(key)]
      bytes = byte_size(Jason.encode!(nested))

      acc
      |> Map.update(nested_path, bytes, &(&1 + bytes))
      |> then(&field_sizes(nested, nested_path, &1))
    end)
  end

  defp field_sizes(_value, _path, sizes), do: sizes
end

[database, samples] = System.argv()
samples = String.to_integer(samples)
if samples < 1, do: raise("samples must be positive")
DashboardPayloadProfile.run(database, samples)
