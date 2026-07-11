defmodule SymphonyElixir.SymphonyPlusPlus.ReviewProfiles do
  @moduledoc false

  @passing_statuses ["passed", "pass", "green", "success"]
  @passing_verdicts ["green", "clean", "passed", "pass", "success", "approved"]
  @profile_order ["fast", "normal", "deep"]
  @review_suite_profiles @profile_order
  @profile_aliases %{
    "github" => "github",
    "github review" => "github",
    "github_review" => "github",
    "github pr review" => "github",
    "github_pr_review" => "github",
    "review_github" => "github",
    "review_deep" => "deep",
    "review_emergency" => "fast",
    "review_fast" => "fast",
    "review_normal" => "normal",
    "review_suite_deep" => "deep",
    "review_suite_emergency" => "fast",
    "review_suite_fast" => "fast",
    "review_suite_normal" => "normal",
    "emergency" => "fast"
  }

  @spec passing_statuses() :: [String.t()]
  def passing_statuses, do: @passing_statuses

  @spec passing_verdicts() :: [String.t()]
  def passing_verdicts, do: @passing_verdicts

  @spec review_suite_profiles() :: [String.t()]
  def review_suite_profiles, do: @review_suite_profiles

  @spec passing_status?(term()) :: boolean()
  def passing_status?(status), do: normalize_status(status) in @passing_statuses

  @spec passing_verdict?(term()) :: boolean()
  def passing_verdict?(verdict), do: normalize_status(verdict) in @passing_verdicts

  @spec normalize_profiles(term()) :: [String.t()]
  def normalize_profiles(nil), do: []

  def normalize_profiles(profiles) when is_list(profiles) do
    profiles
    |> Enum.map(&normalize_profile/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def normalize_profiles(_profiles), do: []

  @spec normalize_review_suite_profiles(term()) :: [String.t()]
  def normalize_review_suite_profiles(nil), do: []

  def normalize_review_suite_profiles(profiles) when is_list(profiles) do
    profiles
    |> Enum.map(&normalize_review_suite_profile/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def normalize_review_suite_profiles(_profiles), do: []

  @spec normalize_review_suite_profile(term()) :: String.t() | nil
  def normalize_review_suite_profile(profile) when is_binary(profile) do
    case normalize_profile_label(profile) do
      profile when profile in @review_suite_profiles -> profile
      _profile -> nil
    end
  end

  def normalize_review_suite_profile(_profile), do: nil

  @spec apply_required_profiles(map(), [String.t()]) :: map()
  def apply_required_profiles(policy, required_profiles) when is_map(policy) and is_list(required_profiles) do
    required_profiles = normalize_review_suite_profiles(required_profiles)

    policy
    |> Map.update!(:required_gates, &replace_profile_requirements(&1, required_profiles, :gate))
    |> Map.update!(:readiness_requirements, &replace_profile_requirements(&1, required_profiles, :readiness))
    |> Map.update!(:review_suite, &Map.put(&1, :required, required_profiles))
  end

  @spec normalize_profile(term()) :: String.t() | nil
  def normalize_profile(profile) when is_binary(profile) do
    profile = normalize_profile_label(profile)

    Map.get(@profile_aliases, profile) || review_suite_profile_alias(profile) || profile
  end

  def normalize_profile(_profile), do: nil

  @spec normalize_suite(term()) :: String.t() | nil
  def normalize_suite(suite) when is_binary(suite) do
    case normalize_suite_label(suite) do
      suite when suite in ["review_suite", "reviewsuite"] -> "review-suite"
      _suite -> nil
    end
  end

  def normalize_suite(_suite), do: nil

  @spec review_suite?(term()) :: boolean()
  def review_suite?(suite), do: normalize_suite(suite) == "review-suite"

  @spec normalize_status(term()) :: String.t()
  def normalize_status(status) when is_binary(status), do: status |> String.trim() |> String.downcase()
  def normalize_status(_status), do: ""

  @spec profile_satisfies?(term(), term()) :: boolean()
  def profile_satisfies?(provided, required) do
    provided = normalize_profile(provided)
    required = normalize_profile(required)

    cond do
      is_nil(provided) or is_nil(required) ->
        false

      provided == required ->
        true

      provided in @profile_order and required in @profile_order ->
        profile_rank(provided) >= profile_rank(required)

      true ->
        false
    end
  end

  @spec profile_verdicts_pass?(term(), map()) :: boolean()
  def profile_verdicts_pass?(required_profile, verdicts) when is_map(verdicts) do
    case normalize_profile(required_profile) do
      nil -> false
      profile -> profile_verdicts_pass_profile?(verdicts, profile)
    end
  end

  def profile_verdicts_pass?(_required_profile, _verdicts), do: false

  defp profile_verdicts_pass_profile?(verdicts, profile) do
    satisfying_verdicts =
      Enum.filter(verdicts, fn {provided_profile, _verdict} -> profile_satisfies?(provided_profile, profile) end)

    satisfying_verdicts != [] and
      Enum.all?(satisfying_verdicts, fn {_provided_profile, verdict} -> passing_verdict?(verdict) end)
  end

  @spec review_suite_payload_profile_satisfies?(term(), term()) :: boolean()
  def review_suite_payload_profile_satisfies?(%{} = payload, required_profile) do
    payload
    |> review_suite_payload_profiles()
    |> Enum.any?(&profile_satisfies?(&1, required_profile))
  end

  def review_suite_payload_profile_satisfies?(_payload, _required_profile), do: false

  @spec review_suite_payload_exact_profile?(term(), term()) :: boolean()
  def review_suite_payload_exact_profile?(%{} = payload, required_profile) do
    required_profile = normalize_profile(required_profile)

    not is_nil(required_profile) and required_profile in review_suite_payload_profiles(payload)
  end

  def review_suite_payload_exact_profile?(_payload, _required_profile), do: false

  @spec review_suite_payload_passes?(term()) :: boolean()
  def review_suite_payload_passes?(%{} = payload) do
    review_suite?(Map.get(payload, "suite")) and
      passing_status?(Map.get(payload, "status")) and
      passing_verdict?(Map.get(payload, "verdict"))
  end

  def review_suite_payload_passes?(_payload), do: false

  @spec review_suite_payloads_satisfy_required_profile?([map()], term()) :: boolean()
  def review_suite_payloads_satisfy_required_profile?(payloads, required_profile) when is_list(payloads) do
    case normalize_profile(required_profile) do
      nil -> false
      profile -> review_suite_payloads_satisfy_profile?(payloads, profile)
    end
  end

  def review_suite_payloads_satisfy_required_profile?(_payloads, _required_profile), do: false

  defp review_suite_payloads_satisfy_profile?(payloads, profile) do
    satisfying_payloads =
      payloads
      |> latest_review_suite_payloads_by_profile()
      |> Enum.filter(fn {provided_profile, _payload} -> profile_satisfies?(provided_profile, profile) end)

    satisfying_payloads != [] and
      Enum.all?(satisfying_payloads, fn {_provided_profile, payload} -> review_suite_payload_passes?(payload) end)
  end

  @spec satisfying_profiles(term()) :: [String.t()]
  def satisfying_profiles(required) do
    case normalize_profile(required) do
      nil -> []
      "fast" -> ["fast", "normal", "deep"]
      "normal" -> ["normal", "deep"]
      "deep" -> ["deep"]
      profile -> [profile]
    end
  end

  @spec accepted_lane_aliases([String.t()]) :: map()
  def accepted_lane_aliases(required_profiles) when is_list(required_profiles) do
    Map.new(required_profiles, fn profile ->
      normalized = normalize_profile(profile)
      {normalized || to_string(profile), satisfying_profiles(profile)}
    end)
  end

  def accepted_lane_aliases(_required_profiles), do: %{}

  @spec green_statuses(String.t()) :: [String.t()]
  def green_statuses(profile), do: ["review_#{profile}_green" | legacy_green_statuses(profile)]

  @spec statuses(String.t()) :: [String.t()]
  def statuses(profile) do
    green_statuses(profile) ++
      ["review_#{profile}_red", "review_#{profile}_failed"] ++
      Enum.flat_map(legacy_status_prefixes(profile), &[&1 <> "_red", &1 <> "_failed"])
  end

  defp profile_rank(profile), do: Enum.find_index(@profile_order, &(&1 == profile)) || -1

  defp replace_profile_requirements(requirements, profiles, kind) do
    replacements = Enum.map(profiles, &profile_requirement(&1, kind))

    case Enum.split_while(requirements, &is_nil(requirement_profile(&1, kind))) do
      {before, []} -> before ++ replacements
      {before, [_first | rest]} -> before ++ replacements ++ Enum.reject(rest, &requirement_profile(&1, kind))
    end
  end

  defp profile_requirement(profile, :gate), do: "review_#{profile}"
  defp profile_requirement(profile, :readiness), do: "review_#{profile}_green"

  defp requirement_profile("review_" <> profile, :gate), do: normalize_review_suite_profile(profile)

  defp requirement_profile("review_" <> requirement, :readiness) do
    if String.ends_with?(requirement, "_green") do
      requirement
      |> String.replace_suffix("_green", "")
      |> normalize_review_suite_profile()
    end
  end

  defp requirement_profile(_requirement, _kind), do: nil

  defp review_suite_payload_profiles(payload) do
    [Map.get(payload, "profile"), Map.get(payload, "lane")]
    |> Enum.map(&normalize_profile/1)
    |> Enum.reject(&is_nil/1)
  end

  defp latest_review_suite_payloads_by_profile(payloads) do
    Enum.reduce(payloads, %{}, fn payload, latest ->
      payload
      |> review_suite_payload_profiles()
      |> Enum.reduce(latest, fn profile, latest -> Map.put(latest, profile, payload) end)
    end)
  end

  defp legacy_green_statuses(profile), do: Enum.map(legacy_status_prefixes(profile), &"#{&1}_green")

  defp legacy_status_prefixes("fast"), do: ["review_emergency"]
  defp legacy_status_prefixes(_profile), do: []

  defp review_suite_profile_alias(profile) do
    case Regex.run(~r/\Areview[\s_]+suite[\s_]+(.+)\z/, profile, capture: :all_but_first) do
      [profile] -> review_suite_profile(String.trim(profile))
      _no_match -> nil
    end
  end

  defp review_suite_profile("fast"), do: "fast"
  defp review_suite_profile("normal"), do: "normal"
  defp review_suite_profile("deep"), do: "deep"
  defp review_suite_profile("emergency"), do: "fast"
  defp review_suite_profile("brief"), do: "brief"
  defp review_suite_profile(_profile), do: nil

  defp normalize_profile_label(profile) do
    profile |> String.trim() |> String.downcase() |> String.replace("-", "_")
  end

  defp normalize_suite_label(label) do
    label
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.replace(~r/\s+/, "_")
  end
end
