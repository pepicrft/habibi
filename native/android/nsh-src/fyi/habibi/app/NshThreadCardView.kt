package fyi.habibi.app

import android.content.Context
import android.view.View
import android.widget.FrameLayout
import com.longbridge.nsh.NshComponent
import com.longbridge.nsh.NshView
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import kotlin.math.ceil

/** Adapted from AtlasThreadCardView at 9af36c01be. See native/ATLAS_LICENSE.
 * Only reviewed, bundled atlas.thread-card code runs; the card is inert data. */
class NshThreadCardView(context: Context, private val card: JSONObject, private val action: (String) -> Unit) : FrameLayout(context) {
    private var engine: NshView? = null
    private var directory: File? = null
    private var failed = false
    private var ready = false
    private val timeout = Runnable { if (!ready) fallback() }
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (engine == null) { if (failed) fallback() else start() }
    }
    override fun onDetachedFromWindow() { stop(); super.onDetachedFromWindow() }
    private fun stop() {
        removeCallbacks(timeout)
        engine?.destroy(); engine = null; removeAllViews()
        directory?.deleteRecursively(); directory = null
    }
    private fun fallback() {
        if (!isAttachedToWindow) return
        stop(); failed = true
        addView(context.column(0).apply {
            addView(context.label(card.getString("fallback"), 15f).apply { setTextIsSelectable(true) })
            val actions = card.getJSONArray("actions")
            for (index in 0 until actions.length()) {
                val item = actions.getJSONObject(index)
                addView(context.button(item.getString("label"), "component_${item.getString("id")}") { action(item.getString("id")) })
            }
        }, LayoutParams(-1, -2))
        layoutParams?.let { it.height = -2; layoutParams = it }
    }
    private fun start() {
        ready = false
        try {
            val runtime = NshView(context); engine = runtime
            runtime.setLimits(16, 0, 1000, 250, 512)
            check(runtime.setGrantedCapabilities("{}"))
            val storage = File(context.cacheDir, "habibi-card-${UUID.randomUUID()}").also { check(it.mkdirs()) }
            directory = storage
            runtime.setStorageDirectory(File(storage, "storage"))
            runtime.setErrorListener { post { if (engine === runtime) fallback() } }
            val payload = mapOf("card" to jsonValue(card), "colors" to colors())
            runtime.registerComponent("atlas.thread-card") { bridge ->
                object : NshComponent {
                    private val empty = View(context)
                    override fun view(): View = empty
                    override fun setProp(name: String, value: Any?) {
                        if (name == "ready" && engine === runtime && isAttachedToWindow) bridge.emit("data", payload)
                    }
                    override fun command(name: String, args: Any?) {
                        if (engine !== runtime || !isAttachedToWindow) return
                        when (name) {
                            "action" -> if (args is String) action(args)
                            "height" -> resize(args)
                        }
                    }
                }
            }
            addView(runtime, LayoutParams(-1, -1))
            layoutParams?.let { it.height = context.dp(180); layoutParams = it }
            for (name in listOf("bundle.js", "capabilities.json", "app.json")) {
                context.assets.open("nsh/$name").use { input -> File(storage, name).outputStream().use { input.copyTo(it) } }
            }
            check(runtime.loadBundleFile(File(storage, "bundle.js")))
            postDelayed(timeout, 3000)
        } catch (_: Exception) { post { fallback() } }
        catch (_: LinkageError) { post { fallback() } }
    }
    private fun resize(value: Any?) {
        val height = (value as? Number)?.toDouble()
        if (height == 0.0) return
        if (height == null || !height.isFinite() || height !in 1.0..6000.0) { post { fallback() }; return }
        ready = true; removeCallbacks(timeout)
        val pixels = ceil(height * resources.displayMetrics.density).toInt()
        layoutParams?.let { if (it.height != pixels) { it.height = pixels; layoutParams = it } }
    }
    private fun colors(): Map<String, String> = mapOf(
        "text" to hex(R.color.ink), "secondary" to hex(R.color.secondary), "surface" to hex(R.color.surface),
        "accent" to hex(R.color.primary), "border" to hex(R.color.outline),
    )
    private fun hex(id: Int) = "#%06X".format(context.color(id) and 0xffffff)
    private fun jsonValue(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { jsonValue(value.get(it)) }
        is JSONArray -> List(value.length()) { jsonValue(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
}
