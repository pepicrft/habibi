package fyi.habibi.app

import android.content.Intent
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.security.MessageDigest

/** One exact origin for discovery, browser authorization and authenticated HTTP.
 * Debug localhost uses adb reverse, never endpoint rewriting. */
@ConsistentCopyVisibility
internal data class SyncOrigin private constructor(val issuer: String) {
    companion object {
        val production = SyncOrigin("https://habibi.fyi")
        fun fromDebugIntent(intent: Intent): SyncOrigin? {
            try {
                if (!BuildConfig.DEBUG || intent.action == Intent.ACTION_VIEW) return null
                return when (intent.getStringExtra("sync_url")) {
                    "http://localhost:4000" -> SyncOrigin("http://localhost:4000")
                    else -> null
                }
            } finally { intent.removeExtra("sync_url") }
        }
    }
    fun url(path: String): String {
        require(path.startsWith("/") && !path.startsWith("//") && !path.contains('#') && !path.contains('\\'))
        val uri = URI(issuer + path)
        require(uri.rawAuthority == URI(issuer).rawAuthority && uri.scheme == URI(issuer).scheme)
        return uri.toString()
    }
}

internal data class SyncResponse(val code: Int, val body: ByteArray, val etag: String? = null) {
    fun json(): JSONObject {
        check(body.size <= 256 * 1024) { "Sync metadata is too large." }
        return try { JSONObject(String(body, Charsets.UTF_8)) } catch (_: Exception) { error("Invalid sync response.") }
    }
    fun success(): SyncResponse {
        check(code != 402) { "Sync uploads need Habibi Plus. Open Habibi Plus in Profile to subscribe or restore. Your local data and pending uploads are kept." }
        check(code in 200..299) { "Sync request failed ($code). Retry Sync now; saved data is retained." }; return this
    }
}

internal fun base64url(value: ByteArray): String = Base64.encodeToString(value, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
internal fun decodeEnvelope(value: String): ByteArray {
    check(value.length <= 1_398_102 && value.matches(Regex("[A-Za-z0-9_-]+"))) { "Invalid encrypted snapshot." }
    val bytes = Base64.decode(value, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    check(base64url(bytes) == value && bytes.size in 64..1_048_576 && String(bytes, 0, 4, Charsets.US_ASCII) == "HAB1") { "Invalid encrypted snapshot." }
    return bytes
}
internal fun form(values: Map<String, String>) = values.entries.joinToString("&") {
    URLEncoder.encode(it.key, "UTF-8") + "=" + URLEncoder.encode(it.value, "UTF-8")
}.toByteArray(Charsets.UTF_8)
internal fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

internal fun interface SyncTransport {
    fun request(origin: SyncOrigin, method: String, path: String, headers: Map<String, String>, body: ByteArray?): SyncResponse
}

internal class HttpSyncTransport(private val open: (String) -> HttpURLConnection = { URI(it).toURL().openConnection() as HttpURLConnection }) : SyncTransport {
    override fun request(origin: SyncOrigin, method: String, path: String, headers: Map<String, String>, body: ByteArray?): SyncResponse {
        check(body == null || body.size <= 1_048_576) { "Sync request is too large." }
        val connection = open(origin.url(path))
        try {
            connection.requestMethod = method
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000; connection.readTimeout = 20_000
            connection.useCaches = false
            headers.forEach { (name, value) ->
                require(!value.contains('\r') && !value.contains('\n')) { "Invalid request header." }
                connection.setRequestProperty(name, value)
            }
            if (body != null) {
                connection.doOutput = true; connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val code = connection.responseCode
            check(code !in 300..399) { "Sync redirects are not allowed. Sign in only at the configured origin." }
            val bytes = (if (code in 200..299) connection.inputStream else connection.errorStream)?.use { input ->
                val output = ByteArrayOutputStream(); val buffer = ByteArray(8192)
                while (true) {
                    val size = input.read(buffer); if (size < 0) break
                    check(output.size() + size <= 1_048_576) { "Sync response is too large." }
                    output.write(buffer, 0, size)
                }
                output.toByteArray()
            } ?: ByteArray(0)
            return SyncResponse(code, bytes, connection.getHeaderField("ETag"))
        } catch (cause: IllegalStateException) { throw cause }
        catch (_: Exception) { error("Sync is offline or the request timed out. Saved data and pending uploads are retained.") }
        finally { connection.disconnect() }
    }
}
