package fyi.habibi.app

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom

/** Host-only OAuth. All storage/HTTP calls belong on the session's serial worker.
 * Pending transactions are memory-only and cancellation invalidates them immediately. */
internal class NativeOAuth(private val storage: VaultStorage, private val http: SyncTransport,
    private val now: () -> Long = { System.currentTimeMillis() }) {
    companion object { const val REDIRECT = "fyi.habibi.android:/oauth/callback" }
    private data class Pending(val origin: SyncOrigin, val client: String, val verifier: String, val state: String, val started: Long, val generation: Long)
    private var pending: Pending? = null
    private var active = false
    private var generation = 0L
    private var credentials: JSONObject? = null
    private var loaded = false
    private val blocked = mutableSetOf<String>()
    @Synchronized fun cancel() { generation++; active = false; pending = null }
    @Synchronized fun authorizing() = active
    private fun records(): JSONObject {
        if (!loaded) { credentials = storage.load() ?: JSONObject(); loaded = true }
        return credentials!!
    }
    fun connected(origin: SyncOrigin): Boolean = origin.issuer !in blocked && records().optJSONObject(origin.issuer)?.optBoolean("usable") == true
    private fun save(origin: SyncOrigin, value: JSONObject?) {
        val next = JSONObject(records().toString())
        if (value == null) next.remove(origin.issuer) else next.put(origin.issuer, value)
        storage.save(next)
        credentials = next
    }
    private fun random() = base64url(ByteArray(32).also { SecureRandom().nextBytes(it) })
    private fun sendForm(origin: SyncOrigin, path: String, values: Map<String, String>) =
        http.request(origin, "POST", path, mapOf("Content-Type" to "application/x-www-form-urlencoded"), form(values)).success()

    fun begin(origin: SyncOrigin): String {
        val ticket = synchronized(this) {
            check(!active) { "Authorization is already open. Cancel it before trying again." }
            active = true; ++generation
        }
        try {
            val discovery = http.request(origin, "GET", "/.well-known/oauth-authorization-server", emptyMap(), null).success().json()
            check(discovery.getString("issuer") == origin.issuer &&
                mapOf("authorization_endpoint" to "/oauth/authorize", "token_endpoint" to "/oauth/token",
                    "registration_endpoint" to "/oauth/register", "revocation_endpoint" to "/oauth/revoke").all { (key, path) -> discovery.getString(key) == origin.issuer + path } &&
                discovery.optBoolean("authorization_response_iss_parameter_supported") &&
                discovery.getJSONArray("code_challenge_methods_supported").let { array -> (0 until array.length()).any { array.getString(it) == "S256" } }) { "The authorization server does not match the selected origin." }
            val registration = JSONObject().put("client_name", "Habibi for Android").put("application_type", "native")
                .put("redirect_uris", JSONArray().put(REDIRECT)).put("token_endpoint_auth_method", "none")
                .put("grant_types", JSONArray().put("authorization_code").put("refresh_token"))
                .put("response_types", JSONArray().put("code")).put("scope", "vaults:sync")
            val client = http.request(origin, "POST", "/oauth/register", mapOf("Content-Type" to "application/json"), registration.toString().toByteArray()).success().json()
            check(client.optString("token_endpoint_auth_method") == "none" && !client.has("client_secret") &&
                client.getJSONArray("redirect_uris").length() == 1 && client.getJSONArray("redirect_uris").getString(0) == REDIRECT) { "Invalid native client registration." }
            val id = bounded(client.getString("client_id"))
            val transaction = Pending(origin, id, random(), random(), now(), ticket)
            synchronized(this) { check(active && generation == ticket) { "Authorization was cancelled." }; pending = transaction }
            val challenge = base64url(MessageDigest.getInstance("SHA-256").digest(transaction.verifier.toByteArray(Charsets.US_ASCII)))
            return origin.issuer + "/oauth/authorize?" + String(form(mapOf("response_type" to "code", "client_id" to id,
                "redirect_uri" to REDIRECT, "scope" to "vaults:sync", "state" to transaction.state,
                "code_challenge" to challenge, "code_challenge_method" to "S256")), Charsets.UTF_8)
        } catch (cause: Exception) { synchronized(this) { if (generation == ticket) { active = false; pending = null } }; throw cause }
    }

    fun callback(raw: String, origin: SyncOrigin) {
        // Consume before validation/exchange. Even malformed/duplicate callbacks
        // cannot turn a one-use code into an automatic replay.
        val transaction = synchronized(this) { val value = pending; pending = null; active = false; value }
            ?: error("No pending authorization. Sign in again.")
        try {
            check(transaction.origin == origin && now() - transaction.started in 0..600_000) { "Authorization expired. Sign in again." }
            check(raw.length <= 8192 && raw.substringBefore('?') == REDIRECT) { "Unexpected authorization callback." }
            val uri = URI(raw)
            check(uri.rawFragment == null && uri.rawQuery != null) { "Unexpected authorization callback." }
            val values = linkedMapOf<String, String>()
            uri.rawQuery.split('&').forEach { pair ->
                check(pair.contains('=')) { "Malformed authorization callback." }
                val key = URLDecoder.decode(pair.substringBefore('='), "UTF-8")
                val value = URLDecoder.decode(pair.substringAfter('='), "UTF-8")
                check(key in setOf("state", "iss", "code", "error", "error_description", "error_uri") && !values.containsKey(key)) { "Ambiguous authorization callback." }
                values[key] = value
            }
            check(values["state"] == transaction.state && values["iss"] == origin.issuer) { "Authorization state or issuer did not match. Sign in again." }
            if (values.containsKey("error")) {
                check(!values.containsKey("code") && !values["error"].isNullOrBlank()) { "Ambiguous authorization callback." }
                error("Authorization was declined or cancelled. Your vault is unchanged.")
            }
            check(!values.containsKey("error_description") && !values.containsKey("error_uri")) { "Ambiguous authorization callback." }
            val code = bounded(values["code"] ?: error("Missing authorization code."))
            val result = sendForm(origin, "/oauth/token", mapOf("grant_type" to "authorization_code", "client_id" to transaction.client,
                "code" to code, "redirect_uri" to REDIRECT, "code_verifier" to transaction.verifier)).json()
            synchronized(this) { check(generation == transaction.generation) { "Authorization was cancelled. Sign in again." } }
            val candidate = tokens(result, transaction.client)
            save(origin, candidate) // Never publish credentials before the protected durable write.
            blocked.remove(origin.issuer)
        } catch (_: Exception) { error("Authorization did not finish. Sign in again; your vault is unchanged.") }
    }
    private fun bounded(value: String): String {
        check(value.length in 1..4096 && value.all { it.code in 0x21..0x7e }) { "Invalid OAuth credential." }; return value
    }
    private fun tokens(response: JSONObject, client: String): JSONObject {
        check(response.getString("token_type").equals("bearer", ignoreCase = true) && response.getString("scope") == "vaults:sync") { "Invalid token response." }
        val expires = response.getLong("expires_in")
        check(expires in 1..3600) { "Invalid token lifetime." }
        return JSONObject().put("clientId", client).put("access", bounded(response.getString("access_token")))
            .put("refresh", bounded(response.getString("refresh_token"))).put("expires", now() + expires * 1000).put("usable", true)
    }
    fun access(origin: SyncOrigin): String {
        check(connected(origin)) { "Sign in to encrypted sync again. Your local vault and sync progress are retained." }
        val previous = records().getJSONObject(origin.issuer)
        if (previous.getLong("expires") > now() + 30_000) return previous.getString("access")
        blocked.add(origin.issuer)
        // Rotating refresh is NOT retryable. A crash/response loss must never
        // restore the spent token. Abort before network if this write fails.
        save(origin, JSONObject().put("clientId", previous.getString("clientId")).put("usable", false))
        try {
            val result = sendForm(origin, "/oauth/token", mapOf("grant_type" to "refresh_token", "client_id" to previous.getString("clientId"),
                "refresh_token" to previous.getString("refresh"))).json()
            val candidate = tokens(result, previous.getString("clientId"))
            save(origin, candidate)
            blocked.remove(origin.issuer)
            return candidate.getString("access")
        } catch (_: Exception) { error("Refresh could not be confirmed. Sign in again; it is unsafe to retry a rotating token.") }
    }
    /** Returns whether the server confirmed revocation. Local deletion is checked
     * separately; no vault/key/outbox record is touched. */
    fun disconnect(origin: SyncOrigin): Boolean {
        cancel()
        val previous = records().optJSONObject(origin.issuer)
        blocked.add(origin.issuer)
        // Remove durably before the best-effort network operation.
        save(origin, null)
        if (previous == null) return false
        val token = previous.optString("refresh").takeIf { it.isNotBlank() }
            ?: previous.optString("access").takeIf { it.isNotBlank() } ?: return false
        return try { sendForm(origin, "/oauth/revoke", mapOf("client_id" to previous.getString("clientId"), "token" to token)); true }
        catch (_: Exception) { false }
    }
}
