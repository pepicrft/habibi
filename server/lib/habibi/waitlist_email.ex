defmodule Habibi.WaitlistEmail do
  @moduledoc "Transactional confirmation via Resend; an explicit file mailbox for local development."

  def deliver(email, token) do
    config = Application.get_env(:habibi, __MODULE__, [])
    origin = HabibiWeb.Endpoint.url()
    link = origin <> "/#access=" <> token

    message = %{
      from: config[:from],
      to: [email],
      subject: "Your invitation to the beginning of Habibi",
      text: """
      Some things deserve to be remembered.

      Confirm your email to join Habibi's early-access circle:
      #{link}

      This one-use link expires in 24 hours. It also returns you to your place if you already joined.
      Requesting another link after a minute replaces this one.

      Once confirmed, you'll get your own invitation link. Every friend who joins through it and
      confirms their email raises your priority. Ties go to the earliest confirmation.
      Positions can change; priority is not guaranteed access. There's no public launch date yet.

      We store your email separately from app data, for confirmation and access invitations only.
      To return later, request a fresh email link at #{origin} to view your place or delete your email.
      Your priority stays the same. No newsletter.
      If you didn't request this, ignore this message. Your email won't be confirmed.

      — Habibi
      """
    }

    cond do
      directory = config[:mailbox] ->
        with :ok <- File.mkdir_p(directory),
             :ok <-
               File.write(
                 Path.join(directory, Ecto.UUID.generate() <> ".json"),
                 Jason.encode!(message)
               ) do
          :ok
        end

      is_binary(config[:api_key]) and is_binary(config[:from]) ->
        case Req.post("https://api.resend.com/emails",
               auth: {:bearer, config[:api_key]},
               json: message,
               retry: false,
               receive_timeout: 5_000,
               connect_options: [timeout: 3_000]
             ) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          _ -> {:error, :delivery_unavailable}
        end

      true ->
        {:error, :delivery_unavailable}
    end
  end
end
