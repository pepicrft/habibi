defmodule HabibiWeb.WaitlistAPITest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  import Ecto.Query
  alias Habibi.{Repo, Waitlist}

  defmodule Mailer do
    def deliver(email, token) do
      Process.put({:confirmation, email}, token)
      if Process.get(:mail_failed), do: {:error, :unavailable}, else: :ok
    end
  end

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    previous = Application.get_env(:habibi, :waitlist_mailer)
    Application.put_env(:habibi, :waitlist_mailer, Mailer)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:habibi, :waitlist_mailer, previous),
        else: Application.delete_env(:habibi, :waitlist_mailer)

      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  test "only confirmed friends raise priority, ties favor earlier confirmation, and repeats cannot steal credit" do
    first = join_and_confirm("first@example.com")
    second = join_and_confirm("second@example.com")
    first_code = body(first)["entry"]["code"]
    second_code = body(second)["entry"]["code"]
    assert body(first)["entry"]["rank"] == 1
    assert body(second)["entry"]["rank"] == 2

    pending =
      request(nil, :post, "/waitlist/join", %{email: "friend@example.com", ref: second_code})

    assert pending.status == 202
    assert body(request(second, :get, "/waitlist/status"))["entry"]["rank"] == 2
    friend = confirm("friend@example.com")
    assert friend.status == 200

    assert body(request(second, :get, "/waitlist/status"))["entry"] == %{
             "code" => second_code,
             "referrals" => 1,
             "rank" => 1
           }

    assert body(request(first, :get, "/waitlist/status"))["entry"]["rank"] == 2

    # Replaying confirmation or registering the same case-insensitive address
    # against another inviter neither adds credit nor moves the referral.
    assert confirm("friend@example.com").status == 422

    assert request(nil, :post, "/waitlist/join", %{email: " FRIEND@EXAMPLE.COM ", ref: first_code}).status ==
             202

    assert body(request(first, :get, "/waitlist/status"))["entry"]["referrals"] == 0
    assert body(request(second, :get, "/waitlist/status"))["entry"]["referrals"] == 1

    join_and_confirm("another@example.com", first_code)
    assert body(request(first, :get, "/waitlist/status"))["entry"]["rank"] == 1
    assert body(request(second, :get, "/waitlist/status"))["entry"]["rank"] == 2

    # Existing members cannot refer themselves or be retroactively referred.
    assert request(nil, :post, "/waitlist/join", %{email: "first@example.com", ref: first_code}).status ==
             202

    assert request(nil, :post, "/waitlist/join", %{email: "second@example.com", ref: first_code}).status ==
             202

    assert body(request(first, :get, "/waitlist/status"))["entry"]["referrals"] == 1
  end

  test "email links are private, single-use, expiring, and a fresh link preserves membership" do
    member = join_and_confirm("member@example.com")
    original = body(member)["entry"]
    anonymous = request(nil, :get, "/waitlist/status?ref=" <> original["code"])
    assert body(anonymous)["entry"] == nil
    assert get_resp_header(member, "cache-control") == ["no-store"]
    refute member.resp_body =~ "member@example.com"

    assert request(nil, :post, "/waitlist/confirm", %{token: original["code"]}).status == 422

    assert request(nil, :post, "/waitlist/confirm", %{token: String.duplicate("a", 43)}).status ==
             422

    allow_resend("member@example.com")
    request(nil, :post, "/waitlist/join", %{email: "member@example.com"})
    fresh = confirm("member@example.com")
    assert body(fresh)["entry"] == original
    assert confirm("member@example.com").status == 422

    request(nil, :post, "/waitlist/join", %{email: "expired@example.com"})

    Repo.update_all(Waitlist.Token,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert confirm("expired@example.com").status == 422
    assert Repo.aggregate(Waitlist.ranked(), :count) == 1
  end

  test "resending is throttled and never creates a second place; delivery failure is not success" do
    assert request(nil, :post, "/waitlist/join", %{email: "cooldown@example.com"}).status == 202
    token = Process.get({:confirmation, "cooldown@example.com"})
    assert request(nil, :post, "/waitlist/join", %{email: "COOLDOWN@example.com"}).status == 202
    assert Process.get({:confirmation, "cooldown@example.com"}) == token
    assert Repo.aggregate(Waitlist.Entry, :count) == 1

    allow_resend("cooldown@example.com")
    request(nil, :post, "/waitlist/join", %{email: "cooldown@example.com"})
    assert request(nil, :post, "/waitlist/confirm", %{token: token}).status == 422
    assert confirm("cooldown@example.com").status == 200

    Process.put(:mail_failed, true)
    assert request(nil, :post, "/waitlist/join", %{email: "failed@example.com"}).status == 503
    refute Repo.get_by(Waitlist.Entry, email: "failed@example.com")
  end

  test "leaving deletes the email and tokens, revokes private access, and removes referral credit" do
    inviter = join_and_confirm("inviter@example.com")
    code = body(inviter)["entry"]["code"]
    friend = join_and_confirm("friend@example.com", code)
    assert request(nil, :delete, "/waitlist/membership", %{}).status == 401
    assert body(request(inviter, :get, "/waitlist/status"))["entry"]["referrals"] == 1
    removed = request(friend, :delete, "/waitlist/membership", %{})
    assert removed.status == 200
    refute Repo.get_by(Waitlist.Entry, email: "friend@example.com")
    assert body(request(friend, :get, "/waitlist/status"))["entry"] == nil
    assert body(request(inviter, :get, "/waitlist/status"))["entry"]["referrals"] == 0

    survivor = join_and_confirm("survivor@example.com", code)
    assert request(inviter, :delete, "/waitlist/membership", %{}).status == 200
    assert body(request(survivor, :get, "/waitlist/status"))["entry"]["rank"] == 1
    assert Repo.aggregate(Waitlist.Token, :count) == 0
  end

  test "invalid emails are rejected, bots get no place, and mutations require CSRF" do
    for email <- [
          nil,
          [],
          "bad",
          "a..b@example.com",
          "a@-example.com",
          "a@example.com\r\nBcc:x@y.com"
        ] do
      assert request(nil, :post, "/waitlist/join", %{email: email}).status == 422
    end

    assert request(nil, :post, "/waitlist/join", %{email: "bot@example.com", website: "spam"}).status ==
             202

    assert Repo.aggregate(Waitlist.Entry, :count) == 0

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn(:post, "/waitlist/join", Jason.encode!(%{email: "csrf@example.com"}))
      |> put_req_header("content-type", "application/json")
      |> HabibiWeb.Endpoint.call([])
    end
  end

  defp join_and_confirm(email, ref \\ nil) do
    assert request(nil, :post, "/waitlist/join", %{email: email, ref: ref}).status == 202
    confirmed = confirm(email)
    assert confirmed.status == 200
    confirmed
  end

  defp confirm(email),
    do: request(nil, :post, "/waitlist/confirm", %{token: Process.get({:confirmation, email})})

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp request(browser, method, path, params \\ nil) do
    browser = if browser, do: Phoenix.ConnTest.recycle(browser), else: conn(:get, "/")

    if method == :get do
      Phoenix.ConnTest.dispatch(browser, HabibiWeb.Endpoint, method, path)
    else
      status = Phoenix.ConnTest.dispatch(browser, HabibiWeb.Endpoint, :get, "/waitlist/status")

      status
      |> Phoenix.ConnTest.recycle()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-csrf-token", body(status)["csrf"])
      |> Phoenix.ConnTest.dispatch(HabibiWeb.Endpoint, method, path, Jason.encode!(params))
    end
  end

  defp allow_resend(email) do
    Repo.update_all(from(e in Waitlist.Entry, where: e.email == ^email),
      set: [last_email_at: DateTime.add(DateTime.utc_now(), -61, :second)]
    )
  end
end
