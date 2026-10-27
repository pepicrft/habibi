defmodule Habibi.Waitlist do
  @moduledoc "Email-confirmed early access. Public referral codes never grant membership access."
  import Ecto.Query
  alias Habibi.Repo

  defmodule Entry do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "waitlist_entries" do
      field(:email, :string)
      field(:code, :string)
      field(:referrer_id, :binary_id)
      field(:confirmed_at, :utc_datetime_usec)
      field(:last_email_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  defmodule Token do
    use Ecto.Schema
    @primary_key {:id, :binary, autogenerate: false}
    schema "waitlist_tokens" do
      field(:entry_id, :binary_id)
      field(:expires_at, :utc_datetime_usec)
    end
  end

  def request_access(email, referral \\ nil) do
    with {:ok, email} <- normalize_email(email) do
      Repo.transaction(fn ->
        now = DateTime.utc_now()
        # The unique email constraint and row lock also serialize concurrent resends.
        Repo.insert!(
          %Entry{email: email, code: random(12), referrer_id: referrer_id(referral)},
          on_conflict: :nothing,
          conflict_target: :email
        )

        entry = Repo.one!(from(e in Entry, where: e.email == ^email, lock: "FOR UPDATE"))

        unless entry.last_email_at && DateTime.diff(now, entry.last_email_at) < 60 do
          token = random(32)
          Repo.delete_all(from(t in Token, where: t.expires_at < ^now))
          # Keep only the latest link for this address; resends don't accumulate tokens.
          Repo.delete_all(from(t in Token, where: t.entry_id == ^entry.id))

          Repo.insert!(%Token{
            id: digest(token),
            entry_id: entry.id,
            expires_at: DateTime.add(now, 86_400, :second)
          })

          mailer = Application.get_env(:habibi, :waitlist_mailer, Habibi.WaitlistEmail)

          case mailer.deliver(email, token) do
            :ok -> Repo.update!(Ecto.Changeset.change(entry, last_email_at: now))
            {:error, _} -> Repo.rollback(:delivery_unavailable)
          end
        end

        :ok
      end)
    end
  end

  def confirm(token) when is_binary(token) and byte_size(token) == 43 do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      # Lock the entry before its token, matching resends and deletion lock order.
      entry =
        Repo.one(
          from(e in Entry,
            join: t in Token,
            on: t.entry_id == e.id,
            where: t.id == ^digest(token) and t.expires_at > ^now,
            select: e,
            lock: fragment("FOR UPDATE OF ?", e)
          )
        )

      if is_nil(entry), do: Repo.rollback(:invalid_token)

      case Repo.delete_all(
             from(t in Token, where: t.id == ^digest(token) and t.expires_at > ^now)
           ) do
        {1, _} ->
          if is_nil(entry.confirmed_at),
            do: Repo.update!(Ecto.Changeset.change(entry, confirmed_at: now))

          entry.id

        _ ->
          Repo.rollback(:invalid_token)
      end
    end)
  end

  def confirm(_), do: {:error, :invalid_token}

  # The same query powers private status and the operator's invitation order.
  # Referrals are rows, not incremented counters, so retries cannot award twice.
  def ranked do
    referrals =
      from(e in Entry,
        where: not is_nil(e.confirmed_at),
        group_by: e.referrer_id,
        select: %{referrer_id: e.referrer_id, total: count(e.id)}
      )

    from(e in Entry,
      left_join: r in subquery(referrals),
      on: r.referrer_id == e.id,
      where: not is_nil(e.confirmed_at),
      order_by: [desc: coalesce(r.total, 0), asc: e.confirmed_at, asc: e.id],
      select: %{
        id: e.id,
        email: e.email,
        code: e.code,
        referrals: coalesce(r.total, 0),
        rank:
          over(row_number(),
            order_by: [desc: coalesce(r.total, 0), asc: e.confirmed_at, asc: e.id]
          )
      }
    )
  end

  def status(nil), do: nil

  def status(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Repo.one(
          from(e in subquery(ranked()),
            where: e.id == ^id,
            select: %{code: e.code, referrals: e.referrals, rank: e.rank}
          )
        )

      :error ->
        nil
    end
  end

  def leave(id) do
    Repo.delete_all(from(e in Entry, where: e.id == ^id))
    :ok
  end

  defp referrer_id(code) when is_binary(code) and byte_size(code) == 16 do
    Repo.one(
      from(e in Entry, where: e.code == ^code and not is_nil(e.confirmed_at), select: e.id)
    )
  end

  defp referrer_id(_), do: nil

  defp normalize_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    if byte_size(email) <= 254 and
         Regex.match?(
           ~r/^[a-z0-9.!#$%&'*+\/=\?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/,
           email
         ) and
         not String.contains?(email, "..") and not String.starts_with?(email, ".") and
         not String.contains?(email, ".@") do
      {:ok, email}
    else
      {:error, :invalid_email}
    end
  end

  defp normalize_email(_), do: {:error, :invalid_email}
  defp random(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)
  defp digest(token), do: :crypto.hash(:sha256, token)
end
