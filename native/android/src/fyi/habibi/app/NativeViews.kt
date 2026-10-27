package fyi.habibi.app

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout

internal fun Context.dp(value: Int) = (value * resources.displayMetrics.density).toInt()
internal fun Context.color(id: Int) = themeColor(id)
internal fun Context.column(padding: Int = 24) = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    setPadding(dp(padding), dp(padding), dp(padding), dp(padding))
}
internal fun Context.label(value: String, size: Float = 16f, muted: Boolean = false) = TextView(this).apply {
    text = value; textSize = size
    setTextColor(color(if (muted) R.color.secondary else R.color.ink))
    setPadding(0, dp(6), 0, dp(6))
}
internal fun Context.heading(value: String, size: Float = 28f) = label(value, size).apply {
    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    androidx.core.view.ViewCompat.setAccessibilityHeading(this, true)
}
internal fun Context.button(value: String, identifier: String, primary: Boolean = false, action: () -> Unit) =
    MaterialButton(this, null, if (primary) com.google.android.material.R.attr.materialButtonStyle else com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
        text = value; tag = identifier; contentDescription = value
        minHeight = dp(56); minimumHeight = dp(56); isAllCaps = false; cornerRadius = dp(24)
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) }
        backgroundTintList = ColorStateList.valueOf(color(if (primary) R.color.primary else R.color.surface))
        setTextColor(ColorStateList(arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
            intArrayOf(color(R.color.secondary), color(if (primary) R.color.on_primary else R.color.primary))))
        strokeColor = ColorStateList.valueOf(color(if (primary) R.color.primary else R.color.outline))
        rippleColor = ColorStateList.valueOf(color(R.color.accent))
        setOnClickListener { action() }
    }
internal fun Context.input(label: String, identifier: String, value: String = "", multiline: Boolean = false): Pair<TextInputLayout, TextInputEditText> {
    val edit = TextInputEditText(this).apply {
        tag = identifier; contentDescription = label; setText(value)
        setTextColor(color(R.color.ink)); setHintTextColor(color(R.color.secondary))
        highlightColor = ColorUtils.setAlphaComponent(color(R.color.primary), 64)
        minimumHeight = dp(56); isSingleLine = !multiline
        if (multiline) { minLines = 3; maxLines = 8; gravity = Gravity.TOP }
        // Identity/recovery are never handed to autofill or Android saved state.
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        isSaveEnabled = false
    }
    val box = TextInputLayout(this).apply {
        hint = label; boxBackgroundMode = TextInputLayout.BOX_BACKGROUND_OUTLINE
        boxBackgroundColor = color(R.color.surface)
        defaultHintTextColor = ColorStateList.valueOf(color(R.color.secondary))
        hintTextColor = ColorStateList.valueOf(color(R.color.primary))
        setBoxStrokeColorStateList(ColorStateList(
            arrayOf(intArrayOf(android.R.attr.state_focused), intArrayOf()), intArrayOf(color(R.color.primary), color(R.color.outline))))
        setBoxCornerRadii(dp(16).toFloat(), dp(16).toFloat(), dp(16).toFloat(), dp(16).toFloat())
        addView(edit, LinearLayout.LayoutParams(-1, -2))
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12); bottomMargin = dp(8) }
    }
    return box to edit
}
internal fun Context.scroll(child: View) = ScrollView(this).apply {
    isFillViewport = true; isSaveEnabled = false; addView(child)
}
internal fun Context.card() = column(20).apply {
    background = GradientDrawable().apply { setColor(color(R.color.surface)); cornerRadius = dp(24).toFloat() }
    layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(16); bottomMargin = dp(8) }
}

internal fun Context.kitIcon(github: Boolean, size: Int = 44) = ImageView(this).apply {
    setImageResource(if (github) R.drawable.ic_github else R.drawable.ic_prompts)
    imageTintList = ColorStateList.valueOf(color(R.color.ink))
    background = GradientDrawable().apply { setColor(color(R.color.accent)); cornerRadius = dp(size / 4).toFloat() }
    val inset = dp(size / 5); setPadding(inset, inset, inset, inset)
    layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
}

internal fun Context.kitTextButton(value: String, identifier: String, action: () -> Unit) =
    MaterialButton(this, null, com.google.android.material.R.attr.borderlessButtonStyle).apply {
        text = value; tag = identifier; isAllCaps = false
        minHeight = dp(48); minimumHeight = dp(48); minWidth = 0; minimumWidth = 0
        insetTop = dp(4); insetBottom = dp(4)
        setPadding(dp(14), 0, dp(14), 0)
        setTextColor(ColorStateList(arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
            intArrayOf(ColorUtils.setAlphaComponent(color(R.color.ink), 97), color(R.color.primary))))
        layoutParams = LinearLayout.LayoutParams(-2, -2)
        setOnClickListener { action() }
    }

internal fun Context.heartling(identifier: String) = HeartlingView(this).apply {
    tag = identifier
    layoutParams = LinearLayout.LayoutParams(dp(144), dp(144)).apply { gravity = Gravity.CENTER_HORIZONTAL }
}

/** The same weighted hero + translucent bottom panel composition as Atlas/Glossia. */
internal fun Context.welcome(create: () -> Unit, restore: () -> Unit, enabled: Boolean): View {
    val content = column(0).apply { background = PaperAtmosphere(this@welcome) }
    val hero = column(24).apply {
        gravity = Gravity.CENTER; minimumHeight = dp(300)
        addView(heartling("welcome_heartling"))
        addView(heading("A little space for you.", 32f).apply { gravity = Gravity.CENTER })
        addView(label("Welcome to Habibi", 18f).apply { gravity = Gravity.CENTER })
        addView(label("Your rhythms, your ideas, your everyday.\nPrivate by design. Made yours.", 16f, true).apply { gravity = Gravity.CENTER })
    }
    content.addView(hero, LinearLayout.LayoutParams(-1, -2, 1f))
    content.addView(column(24).apply {
        background = GradientDrawable().apply {
            setColor(color(R.color.panel))
            val r = dp(32).toFloat(); cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
            setStroke(dp(1), color(R.color.surface))
        }
        addView(button("Create my Habibi", "create_habibi", true, create).apply { isEnabled = enabled })
        addView(button("Restore a backup", "restore_backup", action = restore).apply { isEnabled = enabled })
        addView(label("No account. No password. Your private vault lives on this device.", 13f, true).apply { gravity = Gravity.CENTER })
    })
    return scroll(content)
}

private class PaperAtmosphere(val context: Context) : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    override fun draw(canvas: Canvas) {
        canvas.drawColor(context.color(R.color.paper))
        val w = bounds.width().toFloat(); val h = bounds.height().toFloat()
        if (w <= 0f || h <= 0f) return
        paint.shader = RadialGradient(w * .85f, h * .55f, w, ColorUtils.setAlphaComponent(context.color(R.color.glow), 96), Color.TRANSPARENT, Shader.TileMode.CLAMP)
        canvas.drawRect(bounds, paint)
        paint.shader = RadialGradient(w * .15f, h * .2f, w * .8f, context.color(R.color.accent), Color.TRANSPARENT, Shader.TileMode.CLAMP)
        canvas.drawRect(bounds, paint)
    }
    override fun setAlpha(alpha: Int) { paint.alpha = alpha }
    override fun setColorFilter(colorFilter: ColorFilter?) { paint.colorFilter = colorFilter }
    @Deprecated("Deprecated in Android") override fun getOpacity() = PixelFormat.OPAQUE
}
