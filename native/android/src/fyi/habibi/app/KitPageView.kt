package fyi.habibi.app

import android.content.Context
import android.os.Build
import android.view.View
import android.widget.FrameLayout
import org.json.JSONObject

/** A verified, Kit-owned page. Authentication controls are native siblings. */
internal class KitPageView(context: Context, page: JSONObject) : FrameLayout(context) {
    init {
        tag = "kit_page"
        val renderer = if (Build.VERSION.SDK_INT >= 28) runCatching {
            Class.forName("fyi.habibi.app.NshKitPageView")
                .getConstructor(Context::class.java, JSONObject::class.java)
                .newInstance(context, page) as View
        }.getOrNull() else null
        addView(renderer ?: context.label(page.getString("fallback"), 16f).apply {
            tag = "kit_page_fallback"; setTextIsSelectable(true)
        }, LayoutParams(-1, -2))
    }
}
