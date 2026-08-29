defmodule FYI.Sink.Boop do
  @moduledoc """
  [Boop](https://github.com/chrisgreg/boop) sink: a push notification on your phone
  for every routed event.

  Boop is a tiny self-hosted notification inbox. This sink POSTs each event to its
  `/api/v1/events` endpoint with the project API key; nothing else is needed.

  ## Configuration

      {FYI.Sink.Boop, %{
        url: System.get_env("BOOP_URL"),          # https://boop.example.com
        api_key: System.get_env("BOOP_API_KEY"),  # boop_proj_...
        source: "my_app",                         # optional, shown next to the event
        level: "info",                            # optional default level
        levels: %{"user.*" => "success", "purchase.*" => "success", "*.failed" => "error"},
        dashboard_url: "https://my-app.com/admin/fyi"  # optional: adds an "Open in FYI" button
      }}

  ## Options

  - `:url` (required) - base URL of your Boop server
  - `:api_key` (required) - a Boop project API key (`boop_proj_...`)
  - `:source` - Boop `source` for every event (default: the FYI app name, downcased, or `"fyi"`)
  - `:level` - default Boop level: `"info"`, `"success"`, `"warning"`, `"error"`, `"critical"` (default `"info"`)
  - `:levels` - map of event-name glob to level, first match wins (same globs as routes)
  - `:dashboard_url` - where the FYI inbox is mounted; each push gets an "Open in FYI"
    button that opens the event
  - `:actions` - extra buttons: a list of `%{label, url}` or `fn event -> [...] end`.
    Boop shows at most three in total
  - `:req_options` - keyword merged into the request (e.g. `plug: {Req.Test, FYI.Sink.Boop}` in tests)

  ## What the push looks like

  The title is the event name made readable ("User created"), prefixed with the emoji
  FYI picks for it; the body is the payload on one line (`email: x · method: google`).
  The event name is the Boop `fingerprint`, so repeats of the same event group into one
  inbox row with a count. The full payload, tags, actor and source travel in `data`.
  """

  @behaviour FYI.Sink

  alias FYI.Event

  @levels ~w(info success warning error critical)

  @impl true
  def id, do: :boop

  @impl true
  def init(%{url: url, api_key: api_key} = config)
      when is_binary(url) and url != "" and is_binary(api_key) and api_key != "" do
    with {:ok, level} <- level(config[:level] || "info"),
         {:ok, levels} <- levels(config[:levels] || %{}) do
      {:ok,
       %{
         url: String.trim_trailing(url, "/"),
         api_key: api_key,
         source: config[:source],
         level: level,
         levels: levels,
         dashboard_url:
           config[:dashboard_url] && String.trim_trailing(config[:dashboard_url], "/"),
         actions: config[:actions] || [],
         req_options: config[:req_options] || []
       }}
    end
  end

  def init(_config) do
    {:error, "Boop sink requires :url and :api_key in configuration"}
  end

  @impl true
  def deliver(%Event{} = event, state) do
    payload = build_payload(event, state)

    opts =
      [json: payload, headers: [{"authorization", "Bearer #{state.api_key}"}]]
      |> Keyword.merge(state.req_options)

    case FYI.Client.post(state.url <> "/api/v1/events", opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, "Boop returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def build_payload(%Event{} = event, state) do
    %{
      "title" => title(event),
      "body" => body(event),
      "level" => level_for(event.name, state),
      "source" => state.source || default_source(),
      "type" => "activity",
      "fingerprint" => event.name,
      "external_id" => event.id && to_string(event.id),
      "occurred_at" => event.occurred_at && DateTime.to_iso8601(event.occurred_at),
      "data" =>
        %{
          "event" => event.name,
          "payload" => event.payload,
          "tags" => event.tags,
          "actor" => event.actor,
          "source" => event.source
        }
        |> Enum.reject(fn {_, v} -> v in [nil, %{}] end)
        |> Map.new(),
      "actions" => actions(event, state)
    }
    |> Enum.reject(fn {_, v} -> v in [nil, "", []] end)
    |> Map.new()
  end

  # ---- pieces ----

  defp title(event) do
    words =
      event.name
      |> String.split([".", "_"])
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
      |> String.capitalize()

    case FYI.Config.emoji_for(event.name, event.emoji) do
      nil -> words
      "" -> words
      emoji -> "#{emoji} #{words}"
    end
    |> String.slice(0, 200)
  end

  defp body(event) do
    parts =
      event.payload
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{inline(v)}" end)

    parts = if event.actor, do: parts ++ ["by #{event.actor}"], else: parts
    parts |> Enum.join(" · ") |> String.slice(0, 4000)
  end

  defp inline(v) when is_binary(v), do: v
  defp inline(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)

  defp inline(v) do
    case Jason.encode(v) do
      {:ok, json} -> json
      _ -> inspect(v)
    end
  end

  defp level_for(name, state) do
    Enum.find_value(state.levels, state.level, fn {pattern, level} ->
      if FYI.Router.matches?(name, pattern), do: level
    end)
  end

  defp actions(event, state) do
    (dashboard_action(event, state) ++ custom_actions(event, state))
    |> Enum.flat_map(&normalise_action/1)
    |> Enum.take(3)
  end

  defp dashboard_action(%Event{id: id}, %{dashboard_url: base})
       when is_binary(base) and not is_nil(id) do
    [%{"label" => "Open in FYI", "url" => "#{base}/events/#{id}"}]
  end

  defp dashboard_action(_, _), do: []

  defp custom_actions(event, %{actions: fun}) when is_function(fun, 1) do
    fun.(event) |> List.wrap()
  rescue
    _ -> []
  end

  defp custom_actions(_, %{actions: list}) when is_list(list), do: list
  defp custom_actions(_, _), do: []

  defp normalise_action({label, url}), do: normalise_action(%{label: label, url: url})

  defp normalise_action(%{} = m) do
    label = Map.get(m, :label) || Map.get(m, "label")
    url = Map.get(m, :url) || Map.get(m, "url")
    if label && url, do: [%{"label" => to_string(label), "url" => to_string(url)}], else: []
  end

  defp normalise_action(_), do: []

  defp default_source do
    case FYI.Config.app_name() do
      nil -> "fyi"
      name -> name |> String.downcase() |> String.replace(~r/\s+/, "_")
    end
  end

  # ---- validation ----

  defp level(l) when is_atom(l), do: level(Atom.to_string(l))

  defp level(l) when is_binary(l) do
    l = String.downcase(l)

    if l in @levels,
      do: {:ok, l},
      else: {:error, "Boop sink level must be one of #{Enum.join(@levels, ", ")}"}
  end

  defp level(_), do: {:error, "Boop sink level must be one of #{Enum.join(@levels, ", ")}"}

  defp levels(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, []}, fn {pattern, l}, {:ok, acc} ->
      case level(l) do
        {:ok, l} -> {:cont, {:ok, acc ++ [{to_string(pattern), l}]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp levels(_), do: {:error, "Boop sink :levels must be a map of event pattern to level"}
end
