package fyi.habibi.app

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** These are host capabilities, not model-selected URLs, paths or tools. */
internal enum class GitHubEndpoint(val url: String, val method: String, val responseLimit: Int = 64 * 1024) {
    DEVICE_CODE("https://github.com/login/device/code", "POST"),
    ACCESS_TOKEN("https://github.com/login/oauth/access_token", "POST"),
    USER("https://api.github.com/user", "GET"),
    REPOSITORIES("https://api.github.com/user/repos?visibility=public&affiliation=owner&sort=updated&per_page=10", "GET", 256 * 1024);
}

internal fun interface GitHubTransport {
    fun request(endpoint: GitHubEndpoint, headers: Map<String, String>, body: ByteArray?): SyncResponse
}

internal class HttpGitHubTransport(private val open: (String) -> HttpURLConnection = {
    URI(it).toURL().openConnection() as HttpURLConnection
}) : GitHubTransport {
    override fun request(endpoint: GitHubEndpoint, headers: Map<String, String>, body: ByteArray?): SyncResponse {
        require(body == null || body.size <= 16 * 1024)
        require((endpoint.method == "GET") == (body == null))
        val connection = open(endpoint.url)
        try {
            connection.requestMethod = endpoint.method
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000; connection.readTimeout = 20_000
            connection.useCaches = false
            headers.forEach { (name, value) ->
                require(value.none { it == '\r' || it == '\n' })
                connection.setRequestProperty(name, value)
            }
            connection.setRequestProperty("User-Agent", "Habibi-Android")
            if (body != null) {
                connection.doOutput = true; connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val code = connection.responseCode
            check(code !in 300..399)
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
            val bytes = (if (code in 200..299) connection.inputStream else connection.errorStream)?.use { input ->
                val output = ByteArrayOutputStream(); val buffer = ByteArray(4096)
                while (true) {
                    check(System.nanoTime() < deadline)
                    val count = input.read(buffer); if (count < 0) break
                    check(output.size() + count <= endpoint.responseLimit)
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            } ?: ByteArray(0)
            return SyncResponse(code, bytes)
        } catch (_: Exception) {
            // Never expose server bodies, credentials, account data or URL errors.
            error("GitHub could not be reached safely. Check your connection and try again.")
        } finally { connection.disconnect() }
    }
}

internal fun interface GitHubScheduledTask { fun cancel() }
internal fun interface GitHubScheduler {
    fun schedule(delayMillis: Long, action: () -> Unit): GitHubScheduledTask
}

internal class GitHubAuthScheduler : GitHubScheduler {
    // Separate from the vault's serial worker. No worker sleeps between polls.
    private val worker = Executors.newSingleThreadScheduledExecutor { task -> Thread(task, "habibi-github-auth").apply { isDaemon = true } }
    override fun schedule(delayMillis: Long, action: () -> Unit): GitHubScheduledTask {
        val future = worker.schedule({ action() }, delayMillis, TimeUnit.MILLISECONDS)
        return GitHubScheduledTask { future.cancel(false) }
    }
}

internal data class GitHubAuthorization(val code: String? = null, val expiresAt: Long? = null)
internal data class GitHubAccount(val login: String, val expired: Boolean)

/** Memory-only device transaction. Tokens only cross into the encrypted vault
 * install gate, never UI state, browser intents, transcripts or saved bundles. */
internal class GitHubDeviceFlow(
    private val http: GitHubTransport = HttpGitHubTransport(),
    private val scheduler: GitHubScheduler = GitHubAuthScheduler(),
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    companion object {
        const val VERIFICATION_URL = "https://github.com/login/device"
        private val loginPattern = Regex("[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?")
        fun account(response: JSONObject): String {
            check(integer(response, "id", 1L..Long.MAX_VALUE) > 0)
            return string(response, "login").also { check(loginPattern.matches(it) && !it.contains("--")) }
        }
        private fun string(value: JSONObject, key: String): String {
            return value.get(key) as? String ?: error("Invalid GitHub response.")
        }
        private fun integer(value: JSONObject, key: String, range: LongRange): Long {
            val number = value.get(key)
            check(number is Int || number is Long)
            return (number as Number).toLong().also { check(it in range) }
        }
        private fun credential(value: String, maximum: Int = 4096): String = value.also {
            check(it.length in 1..maximum && it.all { character -> character.code in 0x21..0x7e })
        }
        fun userHeaders(token: String): Map<String, String> = mapOf(
            "Authorization" to "Bearer ${credential(token)}", "Accept" to "application/vnd.github+json",
            "X-GitHub-Api-Version" to "2022-11-28")
    }

    @Volatile var authorization: GitHubAuthorization? = null; private set
    @Volatile var message = "Not connected"; private set
    private var generation = 0L
    private var scheduled: GitHubScheduledTask? = null
    private var notify: () -> Unit = {}
    private var active = false

    @Synchronized fun authorizing() = active
    @Synchronized fun cancel() {
        generation++; active = false; authorization = null
        scheduled?.cancel(); scheduled = null
        message = "Authorization cancelled. No connection was saved."
        notify()
    }

    @Synchronized fun begin(clientId: String, changed: () -> Unit, ready: (Long, JSONObject) -> Unit) {
        check(!active)
        val client = credential(clientId, 128)
        check(Regex("[A-Za-z0-9._-]+").matches(client))
        active = true; val ticket = ++generation; notify = changed
        authorization = GitHubAuthorization(); message = "Requesting a GitHub device code…"; notify()
        scheduled = scheduler.schedule(0) {
            attempt(ticket) {
                val started = now()
                val response = post(GitHubEndpoint.DEVICE_CODE, mapOf("client_id" to client, "scope" to "read:user"))
                check(string(response, "verification_uri") == VERIFICATION_URL)
                val device = string(response, "device_code").also { check(Regex("[A-Fa-f0-9]{40}").matches(it)) }
                val code = string(response, "user_code").also { check(Regex("[A-Z0-9]{4}-[A-Z0-9]{4}").matches(it)) }
                val expires = integer(response, "expires_in", 1L..900)
                val interval = integer(response, "interval", 1L..900)
                val expiry = started + expires * 1000
                check(now() < expiry)
                synchronized(this) {
                    if (!current(ticket)) return@attempt
                    authorization = GitHubAuthorization(code, expiry / 1000)
                    message = "Enter this code at github.com/login/device. Waiting for approval…"; notify()
                    pollLater(ticket, client, device, expiry, interval, ready)
                }
            }
        }
    }

    private fun post(endpoint: GitHubEndpoint, values: Map<String, String>): JSONObject {
        val response = http.request(endpoint, mapOf("Accept" to "application/json", "Content-Type" to "application/x-www-form-urlencoded"), form(values))
        check((response.code == 200 || (endpoint == GitHubEndpoint.ACCESS_TOKEN && response.code == 400)) && response.body.size <= 64 * 1024)
        val json = response.json()
        if (response.code == 400) check(string(json, "error").isNotBlank())
        check(!(json.has("error") && json.has("access_token")))
        return json
    }
    @Synchronized private fun current(ticket: Long) = active && generation == ticket
    private fun attempt(ticket: Long, action: () -> Unit) {
        if (!current(ticket)) return
        try { action() } catch (_: Exception) {
            finish(ticket, "GitHub authorization did not finish. Reconnect to try again; no connection was saved.")
        }
    }
    @Synchronized private fun finish(ticket: Long, value: String) {
        if (!current(ticket)) return
        active = false; authorization = null; scheduled = null; message = value; notify()
    }
    private fun pollLater(ticket: Long, client: String, device: String, expiry: Long, interval: Long, ready: (Long, JSONObject) -> Unit) {
        if (!current(ticket)) return
        val remaining = expiry - now()
        if (remaining <= 0) { finish(ticket, "The GitHub device code expired. Reconnect for a new code."); return }
        scheduled = scheduler.schedule(minOf(interval * 1000, remaining)) {
            attempt(ticket) {
                val started = now()
                if (started >= expiry) { finish(ticket, "The GitHub device code expired. Reconnect for a new code."); return@attempt }
                val response = post(GitHubEndpoint.ACCESS_TOKEN, mapOf("client_id" to client, "device_code" to device,
                    "grant_type" to "urn:ietf:params:oauth:grant-type:device_code"))
                if (!current(ticket)) return@attempt
                check(now() < expiry)
                val error = if (response.has("error")) string(response, "error") else ""
                when (error) {
                    "authorization_pending", "slow_down" -> synchronized(this) {
                        if (!current(ticket)) return@attempt
                        val serverInterval = if (response.has("interval")) integer(response, "interval", 1L..86_400) else 0L
                        val next = maxOf(interval + (if (error == "slow_down") 5 else 0), serverInterval)
                        pollLater(ticket, client, device, expiry, next, ready)
                    }
                    "access_denied" -> finish(ticket, "GitHub authorization was denied. No connection was saved.")
                    "expired_token" -> finish(ticket, "The GitHub device code expired. Reconnect for a new code.")
                    "" -> {
                        check(!response.has("error"))
                        check(string(response, "token_type").equals("bearer", ignoreCase = true))
                        val scope = string(response, "scope"); check(scope == "" || scope == "read:user")
                        val token = credential(string(response, "access_token"))
                        val connection = JSONObject().put("kitId", "github").put("clientId", client)
                            .put("accessToken", token).put("scope", scope)
                        if (response.has("expires_in")) {
                            val tokenExpiry = started / 1000 + integer(response, "expires_in", 1L..31_536_000)
                            check(tokenExpiry > now() / 1000)
                            connection.put("expiresAt", tokenExpiry)
                        }
                        // Deliberately ignore refresh_token: shared devices must not
                        // race rotating credentials. Expiring connections reconnect.
                        if (!current(ticket)) return@attempt
                        val identity = http.request(GitHubEndpoint.USER, userHeaders(token), null)
                        check(identity.code == 200 && identity.body.size <= 64 * 1024)
                        connection.put("account", account(identity.json()))
                        synchronized(this) {
                            if (!current(ticket)) return@attempt
                            check(now() < expiry)
                            if (connection.has("expiresAt")) check(connection.getLong("expiresAt") > now() / 1000)
                            authorization = GitHubAuthorization(); message = "Saving the encrypted connection…"; notify()
                            ready(ticket, connection)
                        }
                    }
                    else -> finish(ticket, "GitHub authorization was not accepted. Reconnect to try again.")
                }
            }
        }
    }

    /** Cancellation and the durable install have one linearization gate. A
     * queued success cannot save after Cancel, even with an HTTP response in flight. */
    @Synchronized fun commit(ticket: Long, install: () -> Unit) {
        if (!current(ticket)) return
        try {
            install()
            finish(ticket, "Connected. Credentials are encrypted in your vault; sync manually to share them.")
        } catch (_: Exception) {
            finish(ticket, "Could not save the GitHub connection. Your previous vault is unchanged. Reconnect to try again.")
        }
    }
}
