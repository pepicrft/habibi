package fyi.habibi.app

import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean

internal enum class ChatGPTEndpoint(val url: String, val limit: Int = 64 * 1024) {
    DEVICE("https://auth.openai.com/api/accounts/deviceauth/usercode"),
    POLL("https://auth.openai.com/api/accounts/deviceauth/token"),
    TOKEN("https://auth.openai.com/oauth/token"),
    INFERENCE("https://chatgpt.com/backend-api/codex/responses", 2 * 1024 * 1024);
}

internal interface ChatGPTTransport {
    fun request(endpoint: ChatGPTEndpoint, headers: Map<String, String>, body: ByteArray, cancelled: AtomicBoolean): SyncResponse
    fun cancel() {}
}

internal class HttpChatGPTTransport : ChatGPTTransport {
    @Volatile private var active: HttpURLConnection? = null
    override fun request(endpoint: ChatGPTEndpoint, headers: Map<String, String>, body: ByteArray, cancelled: AtomicBoolean): SyncResponse {
        val connection = URI(endpoint.url).toURL().openConnection() as HttpURLConnection
        active = connection
        try {
            check(!cancelled.get()) { "Stopped" }
            connection.requestMethod = "POST"; connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000; connection.readTimeout = 90_000; connection.useCaches = false
            headers.forEach { (key, value) ->
                require(value.none { it == '\r' || it == '\n' }); connection.setRequestProperty(key, value)
            }
            connection.doOutput = true; connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { it.write(body) }
            val code = connection.responseCode
            check(code !in 300..399)
            val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(100)
            val data = (if (code in 200..299) connection.inputStream else connection.errorStream)?.use { input ->
                val output = ByteArrayOutputStream(); val buffer = ByteArray(8192)
                while (true) {
                    check(!cancelled.get() && System.nanoTime() < deadline)
                    val size = input.read(buffer); if (size < 0) break
                    check(output.size() + size <= endpoint.limit)
                    output.write(buffer, 0, size)
                }
                output.toByteArray()
            } ?: ByteArray(0)
            return SyncResponse(code, data)
        } catch (_: Exception) { error("ChatGPT could not be reached safely. Check your connection and try again.") }
        finally { connection.disconnect(); active = null }
    }
    override fun cancel() { active?.disconnect() }
}

/** Device-local credentials, deliberately separate from vault recovery and sync.
 * The session serializes inference; authorization owns a separate cancellation gate. */
internal class ChatGPT(
    private val secrets: VaultStorage,
    private val http: ChatGPTTransport = HttpChatGPTTransport(),
    private val now: () -> Long = System::currentTimeMillis,
    private val sleep: (Long) -> Unit = Thread::sleep,
) {
    companion object {
        // Public Codex client used by Pi, not a client secret.
        const val CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
        const val VERIFICATION_URL = "https://auth.openai.com/codex/device"
        const val USAGE_URL = "https://chatgpt.com/settings/usage"
    }
    @Volatile var connected = false; private set
    fun inspect() { connected = secrets.load()?.let { !it.optBoolean("refreshing") && it.has("access_token") } == true }
    fun disconnect() { secrets.save(JSONObject()); connected = false }
    fun cancel() { http.cancel() }

    fun authorize(cancelled: AtomicBoolean, showCode: (String) -> Unit) {
        val device = post(ChatGPTEndpoint.DEVICE, mapOf("client_id" to CLIENT_ID), cancelled).success().json()
        val id = device.getString("device_auth_id"); val code = device.getString("user_code")
        check(id.isNotBlank() && code.matches(Regex("[A-Za-z0-9-]{4,32}"))) { "ChatGPT returned an invalid sign-in code." }
        var interval = device.optString("interval", "5").toLongOrNull() ?: 5L
        check(interval in 0..900) { "Invalid ChatGPT polling interval." }
        interval = interval.coerceAtLeast(5)
        check(!cancelled.get()) { "Stopped" }; showCode(code)
        val deadline = now() + 15 * 60_000
        while (now() < deadline && !cancelled.get()) {
            repeat((interval * 2).toInt()) { check(!cancelled.get()) { "Stopped" }; sleep(500) }
            if (now() >= deadline) break
            val result = post(ChatGPTEndpoint.POLL, mapOf("device_auth_id" to id, "user_code" to code), cancelled)
            if (result.code in setOf(403, 404)) continue
            val failure = runCatching { result.json().opt("error") }.getOrNull()
            val errorCode = if (failure is JSONObject) failure.optString("code") else failure as? String
            if (errorCode == "deviceauth_authorization_pending") continue
            if (errorCode == "slow_down") { interval += 5; continue }
            check(result.code == 200) { "ChatGPT sign-in failed. Enable device-code login in ChatGPT security settings and try again." }
            val authorization = result.json()
            val tokens = post(ChatGPTEndpoint.TOKEN, mapOf("grant_type" to "authorization_code", "client_id" to CLIENT_ID,
                "code" to authorization.getString("authorization_code"), "code_verifier" to authorization.getString("code_verifier"),
                "redirect_uri" to "https://auth.openai.com/deviceauth/callback"), cancelled, encoded = true).success().json()
            val record = credentials(tokens)
            // Cancellation and the durable install are one gate, so a departed
            // screen cannot install a late credential response.
            synchronized(cancelled) {
                check(!cancelled.get()) { "Stopped" }; secrets.save(record); connected = true
            }
            return
        }
        error(if (cancelled.get()) "Stopped" else "ChatGPT code expired. Connect again for a new code.")
    }

    fun send(body: JSONObject, cancelled: AtomicBoolean): String {
        var record = secrets.load() ?: error("Reconnect ChatGPT in Profile → AI provider.")
        check(!record.optBoolean("refreshing")) { "Reconnect ChatGPT in Profile → AI provider." }
        if (record.optLong("expiresAt") <= now() + 60_000) {
            val refresh = record.getString("refresh_token")
            check(!cancelled.get()) { "Stopped" }
            // A lost rotation response must not retry the spent refresh token.
            secrets.save(JSONObject().put("refreshing", true))
            try {
                record = credentials(post(ChatGPTEndpoint.TOKEN, mapOf("grant_type" to "refresh_token", "client_id" to CLIENT_ID,
                    "refresh_token" to refresh), cancelled, encoded = true).success().json())
                secrets.save(record); connected = true
            } catch (_: Exception) { error("Reconnect ChatGPT in Profile → AI provider. Your vault is unchanged.") }
        }
        val response = http.request(ChatGPTEndpoint.INFERENCE, mapOf("Authorization" to "Bearer ${record.getString("access_token")}",
            "ChatGPT-Account-Id" to record.getString("accountId"), "originator" to "habibi",
            "OpenAI-Beta" to "responses=experimental", "Content-Type" to "application/json", "Accept" to "text/event-stream"), body.toString().toByteArray(Charsets.UTF_8), cancelled)
        check(!cancelled.get()) { "Stopped" }
        check(response.code != 401) { "Reconnect ChatGPT in Profile → AI provider." }
        check(response.code != 429) { "ChatGPT usage limit reached. Manage usage at chatgpt.com/settings/usage and try again later." }
        check(response.code == 200) { "ChatGPT could not complete the request. Try another model or check your plan and connection." }
        return String(response.body, Charsets.UTF_8)
    }

    private fun post(endpoint: ChatGPTEndpoint, values: Map<String, String>, cancelled: AtomicBoolean, encoded: Boolean = false): SyncResponse {
        check(!cancelled.get()) { "Stopped" }
        return http.request(endpoint, mapOf("Content-Type" to if (encoded) "application/x-www-form-urlencoded" else "application/json"),
            if (encoded) form(values) else JSONObject(values).toString().toByteArray(Charsets.UTF_8), cancelled)
    }
    private fun credentials(tokens: JSONObject): JSONObject {
        fun safe(value: String) = value.isNotEmpty() && value.length <= 32 * 1024 && value.all { it.code in 33..126 }
        val access = tokens.getString("access_token"); val refresh = tokens.getString("refresh_token"); val lifetime = tokens.getDouble("expires_in")
        check(safe(access) && safe(refresh) && lifetime.isFinite() && lifetime > 0 && lifetime <= 86400)
        // Routing metadata only, not a verified identity or Habibi account.
        val claims = JSONObject(String(Base64.decode(access.split('.')[1], Base64.URL_SAFE or Base64.NO_WRAP), Charsets.UTF_8))
        val account = claims.getJSONObject("https://api.openai.com/auth").getString("chatgpt_account_id")
        check(safe(account) && account.length <= 256)
        return JSONObject().put("access_token", access).put("refresh_token", refresh).put("accountId", account).put("expiresAt", now() + (lifetime * 1000).toLong())
    }
}
