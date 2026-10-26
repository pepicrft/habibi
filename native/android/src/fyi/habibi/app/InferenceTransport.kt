package fyi.habibi.app

import android.content.Intent
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean

internal data class InferenceEndpoint(val url: String, val token: String) {
    companion object {
        fun fromDebugIntent(intent: Intent): InferenceEndpoint? {
            try {
                if (!BuildConfig.DEBUG) return null
                val address = intent.getStringExtra("inference_url") ?: return null
                val token = intent.getStringExtra("inference_token") ?: return null
                val uri = runCatching { URI(address) }.getOrNull() ?: return null
                if (uri.scheme != "http" || uri.host !in setOf("10.0.2.2", "127.0.0.1", "localhost", "[::1]", "::1") ||
                    uri.userInfo != null || uri.fragment != null || token.isBlank() || token.any { it == '\r' || it == '\n' }) return null
                return InferenceEndpoint(address, token)
            } finally {
                // Do not retain credentials in the Activity's task intent/state.
                intent.removeExtra("inference_url")
                intent.removeExtra("inference_token")
            }
        }
    }
}

internal interface InferenceTransport {
    fun send(endpoint: InferenceEndpoint, body: JSONObject, cancelled: AtomicBoolean): JSONObject
    fun cancel()
}

internal class HttpInferenceTransport : InferenceTransport {
    @Volatile private var connection: HttpURLConnection? = null
    override fun send(endpoint: InferenceEndpoint, body: JSONObject, cancelled: AtomicBoolean): JSONObject {
        check(!cancelled.get()) { "Stopped" }
        val request = URI(endpoint.url).toURL().openConnection() as HttpURLConnection
        connection = request
        try {
            check(!cancelled.get()) { "Stopped" }
            request.requestMethod = "POST"
            request.connectTimeout = 90_000
            request.readTimeout = 90_000
            request.instanceFollowRedirects = false // Never forward the bearer token to another origin.
            request.doOutput = true
            request.setRequestProperty("Content-Type", "application/json")
            request.setRequestProperty("Authorization", "Bearer ${endpoint.token}")
            request.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            check(request.responseCode in 200..299) { "Inference bridge request failed (${request.responseCode}). Your vault is unchanged." }
            val bytes = request.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    check(!cancelled.get()) { "Stopped" }
                    val count = input.read(buffer)
                    if (count < 0) break
                    check(output.size() + count <= 128 * 1024) { "Inference response is too large." }
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            return JSONObject(String(bytes, Charsets.UTF_8))
        } finally { request.disconnect(); connection = null }
    }
    override fun cancel() { connection?.disconnect() }
}
