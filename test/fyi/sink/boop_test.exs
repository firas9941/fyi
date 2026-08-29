defmodule FYI.Sink.BoopTest do
  use ExUnit.Case, async: true

  alias FYI.Event
  alias FYI.Sink.Boop

  @config %{
    url: "https://boop.test/",
    api_key: "boop_proj_test",
    req_options: [plug: {Req.Test, Boop}]
  }

  defp event(attrs \\ []) do
    struct!(
      %Event{
        id: "evt_fyi_1",
        name: "user.created",
        payload: %{email: "jo@example.com", method: "google"},
        actor: "user_42",
        tags: %{plan: "free"},
        source: "accounts",
        occurred_at: ~U[2026-08-29 09:31:00Z]
      },
      attrs
    )
  end

  test "id/0" do
    assert Boop.id() == :boop
  end

  describe "init/1" do
    test "requires url and api_key" do
      assert {:error, _} = Boop.init(%{})
      assert {:error, _} = Boop.init(%{url: "https://b", api_key: ""})
      assert {:ok, state} = Boop.init(%{url: "https://b/", api_key: "k"})
      assert state.url == "https://b"
      assert state.level == "info"
    end

    test "validates levels" do
      assert {:ok, %{level: "success", levels: [{"user.*", "warning"}]}} =
               Boop.init(%{
                 url: "https://b",
                 api_key: "k",
                 level: :success,
                 levels: %{"user.*" => :warning}
               })

      assert {:error, _} = Boop.init(%{url: "https://b", api_key: "k", level: "fatal"})
      assert {:error, _} = Boop.init(%{url: "https://b", api_key: "k", levels: %{"x" => "loud"}})
    end
  end

  describe "build_payload/2" do
    test "maps an event to a Boop event" do
      {:ok, state} =
        Boop.init(
          Map.merge(@config, %{
            source: "uini",
            levels: %{"user.*" => "success"},
            dashboard_url: "https://uini.io/admin/fyi/"
          })
        )

      p = Boop.build_payload(event(), state)

      assert p["title"] =~ ~r/User created$/
      assert p["body"] == "email: jo@example.com · method: google · by user_42"
      assert p["level"] == "success"
      assert p["source"] == "uini"
      assert p["type"] == "activity"
      assert p["fingerprint"] == "user.created"
      assert p["external_id"] == "evt_fyi_1"
      assert p["occurred_at"] == "2026-08-29T09:31:00Z"

      assert p["data"] == %{
               "event" => "user.created",
               "payload" => %{email: "jo@example.com", method: "google"},
               "tags" => %{plan: "free"},
               "actor" => "user_42",
               "source" => "accounts"
             }

      assert p["actions"] == [
               %{"label" => "Open in FYI", "url" => "https://uini.io/admin/fyi/events/evt_fyi_1"}
             ]
    end

    test "falls back to the default level, omits empties, no actions without a dashboard" do
      {:ok, state} = Boop.init(@config)

      p =
        Boop.build_payload(
          event(payload: %{}, actor: nil, tags: %{}, source: nil, id: nil, occurred_at: nil),
          state
        )

      assert p["level"] == "info"
      refute Map.has_key?(p, "body")
      refute Map.has_key?(p, "actions")
      refute Map.has_key?(p, "external_id")
      refute Map.has_key?(p, "occurred_at")
      assert p["data"] == %{"event" => "user.created"}
    end

    test "custom actions from a list or function, capped at three, failures swallowed" do
      {:ok, state} =
        Boop.init(
          Map.put(@config, :actions, fn e ->
            [
              {"Actor", "https://app/users/#{e.actor}"},
              %{label: "A", url: "https://a"},
              %{label: "B", url: "https://b"},
              %{label: "C", url: "https://c"}
            ]
          end)
        )

      assert [
               %{"label" => "Actor", "url" => "https://app/users/user_42"},
               %{"label" => "A"},
               %{"label" => "B"}
             ] = Boop.build_payload(event(), state)["actions"]

      {:ok, state} =
        Boop.init(
          Map.merge(@config, %{dashboard_url: "https://d", actions: fn _ -> raise "boom" end})
        )

      assert [%{"label" => "Open in FYI"}] = Boop.build_payload(event(), state)["actions"]
    end

    test "nested payload values are inlined as JSON" do
      {:ok, state} = Boop.init(@config)

      p =
        Boop.build_payload(
          event(payload: %{"plan" => %{"name" => "scale"}, "seats" => 3}, actor: nil),
          state
        )

      assert p["body"] == ~s(plan: {"name":"scale"} · seats: 3)
    end
  end

  describe "deliver/2" do
    test "POSTs to /api/v1/events with the API key" do
      {:ok, state} = Boop.init(@config)
      test_pid = self()

      Req.Test.stub(Boop, fn conn ->
        send(
          test_pid,
          {:request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
           conn.body_params}
        )

        Req.Test.json(%{conn | status: 201}, %{
          "id" => "evt_1",
          "created_at" => "2026-08-29T09:31:00Z"
        })
      end)

      assert :ok = Boop.deliver(event(), state)
      assert_receive {:request, "/api/v1/events", ["Bearer boop_proj_test"], body}
      assert body["title"] =~ "User created"
      assert body["fingerprint"] == "user.created"
    end

    test "surfaces non-2xx responses" do
      {:ok, state} = Boop.init(@config)

      Req.Test.stub(Boop, fn conn ->
        Req.Test.json(%{conn | status: 401}, %{"error" => "unauthorized"})
      end)

      assert {:error, "Boop returned 401" <> _} = Boop.deliver(event(), state)
    end
  end
end
