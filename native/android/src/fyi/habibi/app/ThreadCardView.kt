package fyi.habibi.app

import android.content.Context
import android.os.Build
import android.view.View
import android.widget.FrameLayout
import org.json.JSONObject

/** Optional NSH integration is compiled only with the release 0.2.0 AAR.
 * A missing SDK, old Android version, or renderer failure keeps native text. */
internal class ThreadCardView(context: Context, card: JSONObject, action: (String) -> Unit) : FrameLayout(context) {
    private val renderer: View
    init {
        val nsh = if (Build.VERSION.SDK_INT >= 28) runCatching {
            val type = Class.forName("fyi.habibi.app.NshThreadCardView")
            type.getConstructor(Context::class.java, JSONObject::class.java, kotlin.jvm.functions.Function1::class.java)
                .newInstance(context, card, action) as View
        }.getOrNull() else null
        renderer = nsh ?: context.column(0).apply {
            addView(context.label(card.getString("fallback"), 15f).apply { setTextIsSelectable(true) })
            val actions = card.getJSONArray("actions")
            for (index in 0 until actions.length()) {
                val item = actions.getJSONObject(index)
                addView(context.button(item.getString("label"), "component_${item.getString("id")}") { action(item.getString("id")) })
            }
        }
        addView(renderer, LayoutParams(-1, -2))
    }
    fun pause() { removeView(renderer) } // NSH detach destroys its engine and disposable storage.
    fun resume() { if (renderer.parent == null) addView(renderer, LayoutParams(-1, -2)) }
}
