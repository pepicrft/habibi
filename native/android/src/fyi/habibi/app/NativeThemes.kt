package fyi.habibi.app

import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.util.AtomicFile
import android.widget.CompoundButton
import androidx.core.content.ContextCompat
import androidx.core.graphics.toColorInt
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.Executors

internal data class NativeTheme(val id: String, val name: String, val light: Map<String, Int>, val dark: Map<String, Int>)
internal data class ThemeCatalog(val defaultTheme: String, val themes: List<NativeTheme>) {
    fun resolve(id: String?) = themes.firstOrNull { it.id == id } ?: themes.first { it.id == defaultTheme }

    companion object {
        const val MAX_BYTES = 256 * 1024
        private val required = listOf("primary", "background", "text", "textMuted", "accent", "muted", "border", "secondary", "focus", "memoryBorder", "bubble", "surface", "onPrimary")
        val validId = Regex("[a-z][a-z0-9-]{0,39}")
        fun parse(bytes: ByteArray): ThemeCatalog {
            require(bytes.size <= MAX_BYTES) { "Theme catalog is too large." }
            val json = JSONObject(String(bytes, Charsets.UTF_8))
            require(json.getInt("version") == 1)
            val entries = json.getJSONArray("themes")
            require(entries.length() in 1..32)
            fun colors(json: JSONObject): Map<String, Int> = required.associateWith { key ->
                val value = json.getString(key)
                require(value.matches(Regex("#[0-9a-fA-F]{6}"))) { "Invalid theme color." }
                value.toColorInt()
            }
            val themes = List(entries.length()) { index ->
                val item = entries.getJSONObject(index)
                val id = item.getString("id"); val name = item.getString("name")
                require(validId.matches(id) && name.isNotBlank() && name.length <= 80 && name.none { it.isISOControl() })
                val palette = item.getJSONObject("colors")
                NativeTheme(id, name, colors(palette), colors(palette.getJSONObject("modes").getJSONObject("dark")))
            }
            val default = json.getString("defaultTheme")
            require(themes.map { it.id }.distinct().size == themes.size && themes.any { it.id == default })
            return ThemeCatalog(default, themes)
        }
    }
}

/** The server catalog is public. Only its bounded origin-scoped copy is cached here;
 * the selected theme and appearance live exclusively in the encrypted profile. */
internal class NativeThemes(
    context: Context,
    private val transport: SyncTransport = HttpSyncTransport(),
    private val worker: Executor = Executors.newSingleThreadExecutor(),
    private val publish: ((() -> Unit) -> Unit) = { Handler(Looper.getMainLooper()).post(it) },
) {
    private val bundled = context.assets.open("themes.json").use { ThemeCatalog.parse(it.readBytes()) }
    private val cache = AtomicFile(File(context.cacheDir, "public-themes-v1.json"))
    private val listeners = linkedSetOf<() -> Unit>()
    private var origin: SyncOrigin? = null
    var catalog = bundled; private set
    var refreshing = false; private set
    var message = "Bundled themes · Refresh to check the server's public catalog."; private set

    fun observe(listener: () -> Unit) { listeners.add(listener) }
    fun unobserve(listener: () -> Unit) { listeners.remove(listener) }
    private fun changed() = listeners.toList().forEach { it() }

    fun useOrigin(value: SyncOrigin) {
        if (origin == value) return
        origin = value; catalog = bundled
        message = "Bundled themes · Refresh to check the server's public catalog."
        runCatching {
            val bytes = synchronized(cache) {
                cache.openRead().use {
                    require(it.channel.size() <= ThemeCatalog.MAX_BYTES + 1024)
                    it.readBytes()
                }
            }
            val saved = JSONObject(String(bytes, Charsets.UTF_8))
            if (saved.getString("issuer") == value.issuer) {
                catalog = ThemeCatalog.parse(saved.getJSONObject("catalog").toString().toByteArray())
                message = "Cached public themes · Available offline."
            }
        }
    }

    /** Explicit, unauthenticated refresh. Merely opening the app never contacts production. */
    fun refresh(value: SyncOrigin) {
        if (refreshing) return
        useOrigin(value)
        refreshing = true; message = "Refreshing public themes…"; changed()
        worker.execute {
            val result = runCatching {
                val response = transport.request(value, "GET", "/assets/themes.json", mapOf("Accept" to "application/json"), null)
                check(response.code == 200)
                val parsed = ThemeCatalog.parse(response.body)
                val envelope = JSONObject().put("issuer", value.issuer).put("catalog", JSONObject(String(response.body, Charsets.UTF_8)))
                synchronized(cache) {
                    val output = cache.startWrite()
                    try { output.write(envelope.toString().toByteArray()); cache.finishWrite(output) }
                    catch (cause: Exception) { cache.failWrite(output); throw cause }
                }
                parsed
            }
            publish {
                refreshing = false
                if (origin == value) {
                    result.onSuccess { catalog = it; message = "Public themes refreshed." }
                        .onFailure { message = "Could not refresh public themes. Available offline themes are unchanged." }
                }
                changed()
            }
        }
    }

    fun palette(context: Context, profile: JSONObject?): Map<String, Int> {
        val dark = when (profile?.optString("appearance", "system")) {
            "dark" -> true
            "light" -> false
            else -> context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        }
        val selected = catalog.resolve(profile?.optString("theme"))
        return if (dark) selected.dark else selected.light
    }
}

internal fun Context.themeColor(id: Int): Int {
    val application = applicationContext as? HabibiApplication ?: return ContextCompat.getColor(this, id)
    val palette = application.themes.palette(this, application.session.state?.optJSONObject("profile"))
    val token = when (id) {
        R.color.primary -> "primary"
        R.color.on_primary -> "onPrimary"
        R.color.paper -> "background"
        R.color.ink -> "text"
        R.color.secondary -> "textMuted"
        R.color.accent -> "accent"
        R.color.surface, R.color.panel -> "surface"
        R.color.outline -> "border"
        R.color.glow -> "secondary"
        else -> return ContextCompat.getColor(this, id)
    }
    return palette.getValue(token)
}

internal fun Context.selectionColors() = ColorStateList(
    arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf(android.R.attr.state_checked), intArrayOf()),
    intArrayOf(color(R.color.secondary), color(R.color.primary), color(R.color.secondary))
)

internal fun CompoundButton.applyThemeColors() {
    setTextColor(context.color(R.color.ink))
    buttonTintList = context.selectionColors()
}
