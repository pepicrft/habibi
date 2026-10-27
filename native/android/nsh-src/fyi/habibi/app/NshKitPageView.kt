package fyi.habibi.app

import android.content.Context
import android.view.View
import android.widget.FrameLayout
import com.longbridge.nsh.NshComponent
import com.longbridge.nsh.NshView
import org.json.JSONObject
import java.io.File
import java.util.UUID
import kotlin.math.ceil

/** No credentials, storage, network, tool or authentication bridge is registered. */
class NshKitPageView(context: Context, private val page: JSONObject) : FrameLayout(context) {
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
        addView(context.label(page.getString("fallback"), 16f).apply {
            tag = "kit_page_fallback"; setTextIsSelectable(true)
        }, LayoutParams(-1, -2))
        layoutParams?.let { it.height = -2; layoutParams = it }
    }
    private fun start() {
        ready = false
        try {
            check(page.getInt("version") == 1)
            val runtime = NshView(context); engine = runtime
            runtime.tag = "kit_page_runtime"
            runtime.setLimits(16, 0, 1000, 250, 512)
            runtime.setFontScale(resources.configuration.fontScale)
            check(runtime.setGrantedCapabilities("{}"))
            val storage = File(context.cacheDir, "habibi-kit-page-${UUID.randomUUID()}").also { check(it.mkdirs()) }
            directory = storage
            runtime.setStorageDirectory(File(storage, "storage"))
            runtime.setErrorListener { post { if (engine === runtime) fallback() } }
            val kit = page.getJSONObject("kit")
            val payload = mapOf("kit" to mapOf("id" to kit.getString("id"), "name" to kit.getString("name"), "description" to kit.getString("description")),
                "typography" to mapOf("title" to 28, "heading" to 20, "body" to 16, "caption" to 14),
                "colors" to mapOf("text" to hex(R.color.ink), "secondary" to hex(R.color.secondary), "accent" to hex(R.color.primary)))
            runtime.registerComponent("habibi.kit-page") { bridge ->
                object : NshComponent {
                    private val empty = View(context)
                    override fun view(): View = empty
                    override fun setProp(name: String, value: Any?) {
                        if (name == "ready" && engine === runtime && isAttachedToWindow) bridge.emit("data", payload)
                    }
                    override fun command(name: String, args: Any?) {
                        if (engine !== runtime || !isAttachedToWindow || name != "height") return
                        val height = (args as? Number)?.toDouble()
                        if (height == 0.0) return
                        if (height == null || !height.isFinite() || height !in 1.0..6000.0) { post { fallback() }; return }
                        ready = true; removeCallbacks(timeout)
                        val pixels = ceil(height * resources.displayMetrics.density).toInt()
                        layoutParams?.let { if (it.height != pixels) { it.height = pixels; layoutParams = it } }
                    }
                }
            }
            addView(runtime, LayoutParams(-1, -1))
            layoutParams?.let { it.height = context.dp(240); layoutParams = it }
            File(storage, "bundle.js").writeText(page.getString("source"))
            File(storage, "app.json").writeText("""{"id":"fyi.habibi.kit-page"}""")
            File(storage, "capabilities.json").writeText("""{"network":{"hosts":[],"http":[]},"process":{"execute":[],"exit":false,"env":[]},"fs":{"read":[],"write":[]},"statusBar":false,"clipboard":false}""")
            check(runtime.loadBundleFile(File(storage, "bundle.js")))
            postDelayed(timeout, 3000)
        } catch (_: Exception) { post { fallback() } }
        catch (_: LinkageError) { post { fallback() } }
    }
    private fun hex(id: Int) = "#%06X".format(context.color(id) and 0xffffff)
}
