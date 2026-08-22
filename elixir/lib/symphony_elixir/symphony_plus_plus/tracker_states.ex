defmodule SymphonyElixir.SymphonyPlusPlus.TrackerStates do
  @moduledoc false

  @worker_dispatchable_states [
    "ready_for_worker",
    "active",
    "claimed",
    "planning",
    "implementing",
    "reviewing",
    "ci_waiting"
  ]
  @active_states @worker_dispatchable_states ++
                   [
                     "ready_for_merge",
                     "ready_for_architect_merge",
                     "merging_into_phase"
                   ]
  @terminal_states ["merged", "merged_into_phase", "closed", "abandoned"]
  @tracker_kinds ["Symphony_pp", "symphony_pp", "symphony++"]
  @canonical_tracker_kind "Symphony_pp"
  @tracker_kind_aliases %{
    "symphony_pp" => @canonical_tracker_kind,
    "symphony++" => @canonical_tracker_kind
  }
  @state_aliases %{
    "todo" => "ready_for_worker",
    "in progress" => "implementing",
    "done" => "merged",
    "closed" => "closed",
    "cancelled" => "abandoned",
    "canceled" => "abandoned",
    "duplicate" => "closed"
  }

  @type state_set :: %MapSet{}

  @spec tracker_kind?(term()) :: boolean()
  def tracker_kind?(kind), do: not is_nil(canonical_tracker_kind(kind))

  @spec tracker_kinds() :: [String.t()]
  def tracker_kinds, do: @tracker_kinds

  @spec canonical_tracker_kind(term()) :: String.t() | nil
  def canonical_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> then(&Map.get(@tracker_kind_aliases, &1))
  end

  def canonical_tracker_kind(_kind), do: nil

  @spec active_state_names(term()) :: [String.t()]
  def active_state_names(state_names), do: state_names(state_names, @active_states)

  @spec terminal_state_names(term()) :: [String.t()]
  def terminal_state_names(state_names), do: state_names(state_names, @terminal_states)

  @spec worker_dispatchable_state_names() :: [String.t()]
  def worker_dispatchable_state_names, do: @worker_dispatchable_states

  @spec lookup_state_set(term()) :: state_set()
  def lookup_state_set(state_names), do: state_set(state_names, [])

  @spec lookup_state_query_names(term()) :: [String.t()]
  def lookup_state_query_names(state_names) when is_list(state_names) do
    canonical_names =
      state_names
      |> Enum.map(&canonical_state_name/1)
      |> MapSet.new()

    alias_names =
      @state_aliases
      |> Enum.filter(fn {_alias_name, canonical_name} -> MapSet.member?(canonical_names, canonical_name) end)
      |> Enum.map(fn {alias_name, _canonical_name} -> alias_name end)

    canonical_names
    |> MapSet.to_list()
    |> Kernel.++(alias_names)
    |> Enum.uniq()
  end

  def lookup_state_query_names(_state_names), do: []

  @spec active_state_set(term()) :: state_set()
  def active_state_set(state_names), do: state_set(active_state_names(state_names), [])

  @spec terminal_state_set(term()) :: state_set()
  def terminal_state_set(state_names), do: state_set(terminal_state_names(state_names), [])

  @spec normalize_state(term()) :: String.t()
  def normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  def normalize_state(_state), do: ""

  @spec canonical_state_name(term()) :: String.t()
  def canonical_state_name(state_name) do
    normalized = normalize_state(state_name)
    Map.get(@state_aliases, normalized, normalized)
  end

  @spec state_names(term(), [String.t()]) :: [String.t()]
  defp state_names(nil, default), do: default

  defp state_names(state_names, _default) when is_list(state_names), do: normalized_state_names(state_names)

  defp state_names(_state_names, default), do: default

  @spec state_set(term(), [String.t()]) :: state_set()
  defp state_set(nil, default), do: MapSet.new(default)

  defp state_set(state_names, _default) when is_list(state_names) do
    case normalized_state_names(state_names) do
      [] -> MapSet.new()
      normalized -> MapSet.new(normalized)
    end
  end

  defp state_set(_state_names, default), do: MapSet.new(default)

  @spec normalized_state_names([term()]) :: [String.t()]
  defp normalized_state_names(state_names) when is_list(state_names) do
    state_names
    |> Enum.map(&canonical_state_name/1)
  end
end
