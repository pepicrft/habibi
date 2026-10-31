package fyi.habibi.app

import android.animation.ValueAnimator
import android.content.Context
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.LinearGradient
import android.graphics.Shader
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.LruCache
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.Button
import android.widget.ImageView
import androidx.core.view.ViewCompat
import androidx.core.graphics.PathParser
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.findViewTreeLifecycleOwner
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.sin

/** A local, native greeting. It deliberately has no session, storage or network dependency. */
class HeartlingView @JvmOverloads constructor(context: Context, private val interactive: Boolean = true) : View(context) {
    private enum class Expression(val state: String, val description: String) {
        IDLE("idle", "Relaxed"), CURIOUS("curious", "Curious"), DELIGHTED("delighted", "Delighted"),
        ATTENTIVE("attentive", "Attentive"), BLINK("blink", "Relaxed")
    }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val destination = RectF()
    private var expression = Expression.IDLE
    private var nextCurious = true
    private var hop: ValueAnimator? = null
    private var lifecycle: Lifecycle? = null
    private var observingMotion = false
    private var silhouette: Path? = null
    /** Geometry has already passed the shared core's bounded path/eye validation. */
    var avatar: JSONObject? = null
        set(value) {
            if (field?.toString() == value?.toString()) return
            field = value
            silhouette = value?.getJSONObject("body")?.getString("path")?.let(PathParser::createPathFromPathData)
            stopMotion()
            setExpression(if (working) Expression.ATTENTIVE else Expression.IDLE)
            if (interactive) contentDescription = if (value == null) "Say hello to Heartling" else "Say hello to your skin avatar"
            refreshMotion()
            invalidate()
        }
    private val mainHandler = Handler(Looper.getMainLooper())
    private val motionObserver = object : ContentObserver(mainHandler) {
        override fun onChange(selfChange: Boolean) { refreshMotion() }
    }
    private val lifecycleObserver = LifecycleEventObserver { _, _ -> refreshMotion() }
    private val settle = Runnable {
        setExpression(if (working) Expression.ATTENTIVE else Expression.IDLE)
        scheduleBlink()
    }
    private val blink = Runnable {
        if (canAnimate() && expression == Expression.IDLE) {
            setExpression(Expression.BLINK)
            postDelayed(settle, 140)
        }
    }

    /** Only the conversation's real chatting state should drive this presentation. */
    var working: Boolean = false
        set(value) {
            if (field == value) return
            field = value
            setExpression(if (value) Expression.ATTENTIVE else Expression.IDLE)
            refreshMotion()
        }

    init {
        isSaveEnabled = false
        importantForAccessibility = if (interactive) IMPORTANT_FOR_ACCESSIBILITY_YES else IMPORTANT_FOR_ACCESSIBILITY_NO
        if (interactive) {
            contentDescription = "Say hello to Heartling"
            isFocusable = true
            setOnClickListener { greet() }
        }
        ViewCompat.setStateDescription(this, expression.description)
    }

    override fun getAccessibilityClassName(): CharSequence = if (interactive) Button::class.java.name else ImageView::class.java.name

    private fun setExpression(value: Expression) {
        if (expression == value) return
        expression = value
        ViewCompat.setStateDescription(this, value.description)
        invalidate()
    }

    private fun greet() {
        if (!interactive || working) return
        stopMotion()
        setExpression(if (nextCurious) Expression.CURIOUS else Expression.DELIGHTED)
        nextCurious = !nextCurious
        // With system animations disabled, only the static expression changes.
        if (!canAnimate()) return
        val direction = if (expression == Expression.CURIOUS) -1f else 1f
        hop = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 460
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener {
                val progress = (it.animatedValue as Float).toDouble()
                translationY = (-sin(PI * progress) * context.dp(10)).toFloat()
                rotation = (sin(2 * PI * progress) * 6 * direction).toFloat()
            }
            start()
        }
        postDelayed(settle, 1400)
    }

    private fun active() = isAttachedToWindow && isShown && windowVisibility == VISIBLE &&
        lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) != false

    private fun canAnimate() = active() && ValueAnimator.areAnimatorsEnabled() &&
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f

    private fun scheduleBlink() {
        if (interactive && !working && expression == Expression.IDLE && canAnimate()) postDelayed(blink, 6000)
    }

    private fun stopMotion() {
        removeCallbacks(blink)
        removeCallbacks(settle)
        hop?.cancel(); hop = null
        translationY = 0f; rotation = 0f
        if (expression == Expression.BLINK) setExpression(Expression.IDLE)
    }

    private fun refreshMotion() {
        stopMotion()
        val active = active()
        if (active && !observingMotion) {
            context.contentResolver.registerContentObserver(
                Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, motionObserver
            )
            observingMotion = true
        } else if (!active && observingMotion) {
            context.contentResolver.unregisterContentObserver(motionObserver)
            mainHandler.removeCallbacksAndMessages(null)
            observingMotion = false
        }
        if (canAnimate()) {
            if (expression == Expression.CURIOUS || expression == Expression.DELIGHTED) postDelayed(settle, 1400)
            else scheduleBlink()
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        lifecycle = findViewTreeLifecycleOwner()?.lifecycle
        lifecycle?.addObserver(lifecycleObserver)
        refreshMotion()
    }

    override fun onDetachedFromWindow() {
        lifecycle?.removeObserver(lifecycleObserver)
        lifecycle = null
        stopMotion()
        if (observingMotion) context.contentResolver.unregisterContentObserver(motionObserver)
        observingMotion = false
        mainHandler.removeCallbacksAndMessages(null)
        super.onDetachedFromWindow()
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        refreshMotion()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        refreshMotion()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val side = minOf(width - paddingLeft - paddingRight, height - paddingTop - paddingBottom).toFloat()
        if (side <= 0f) return
        val left = paddingLeft + (width - paddingLeft - paddingRight - side) / 2f
        val top = paddingTop + (height - paddingTop - paddingBottom - side) / 2f
        val geometry = avatar
        val body = silhouette
        if (geometry != null && body != null) {
            canvas.save()
            canvas.translate(left, top)
            canvas.scale(side / 100f, side / 100f)
            drawAvatar(canvas, body, geometry.getJSONObject("eyes"))
            canvas.restore()
            return
        }
        destination.set(left, top, left + side, top + side)
        paint.color = Color.WHITE
        canvas.drawBitmap(HeartlingAtlas.frames(context).getValue(expression.state), null, destination, paint)
    }

    private fun drawAvatar(canvas: Canvas, body: Path, eyes: JSONObject) {
        val primary = context.color(R.color.primary)
        val shade = Color.rgb((Color.red(primary) * 0.78f).toInt(), (Color.green(primary) * 0.78f).toInt(), (Color.blue(primary) * 0.78f).toInt())
        paint.style = Paint.Style.FILL
        paint.color = Color.WHITE
        paint.shader = LinearGradient(25f, 15f, 75f, 90f, primary, shade, Shader.TileMode.CLAMP)
        canvas.drawPath(body, paint)
        paint.shader = null
        paint.style = Paint.Style.STROKE; paint.strokeWidth = 0.7f; paint.color = 0x2effffff
        canvas.drawPath(body, paint)
        val x = eyes.getDouble("x").toFloat()
        val y = eyes.getDouble("y").toFloat()
        val spacing = eyes.getDouble("spacing").toFloat()
        val scale = eyes.getDouble("scale").toFloat()
        val radius = 3.2f * scale
        val gaze = when (expression) { Expression.CURIOUS -> 0.8f; Expression.ATTENTIVE -> -0.8f; else -> 0f } * scale
        for (center in listOf(x - spacing / 2 + gaze, x + spacing / 2 + gaze)) {
            paint.color = 0xc7000000.toInt()
            if (expression == Expression.BLINK || expression == Expression.DELIGHTED) {
                val lid = Path().apply {
                    moveTo(center - radius, y)
                    quadTo(center, y - if (expression == Expression.DELIGHTED) radius * 1.6f else 0f, center + radius, y)
                }
                paint.style = Paint.Style.STROKE; paint.strokeWidth = 1.6f * scale; paint.strokeCap = Paint.Cap.ROUND
                canvas.drawPath(lid, paint)
            } else {
                paint.style = Paint.Style.FILL
                canvas.drawOval(center - radius, y - radius * 1.25f, center + radius, y + radius * 1.25f, paint)
                paint.color = 0xa6ffffff.toInt()
                canvas.drawOval(center - radius * 0.4f, y - radius * 0.7f, center + radius * 0.15f, y - radius * 0.15f, paint)
            }
        }
        paint.style = Paint.Style.FILL
    }
}

/** Decode once; cache hard-light frames by the resolved (including night mode) primary color. */
private object HeartlingAtlas {
    private var manifest: JSONObject? = null
    private var source: Bitmap? = null
    private val tinted = LruCache<Int, Map<String, Bitmap>>(2)

    @Synchronized fun frames(context: Context): Map<String, Bitmap> {
        val tint = context.color(R.color.primary)
        tinted.get(tint)?.let { return it }
        val geometry = manifest ?: context.assets.open("heartling/heartling.json").bufferedReader().use {
            JSONObject(it.readText())
        }.also {
            require(it.getInt("version") == 1 && it.getString("tintToken") == "primary" && it.getString("blendMode") == "hard-light")
            manifest = it
        }
        val atlas = source ?: context.assets.open("heartling/${geometry.getString("image")}").use {
            requireNotNull(BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inScaled = false }))
        }.also {
            require(it.width == geometry.getInt("width") && it.height == geometry.getInt("height"))
            source = it
        }
        val frameWidth = geometry.getInt("frameWidth")
        val frameHeight = geometry.getInt("frameHeight")
        val columns = geometry.getInt("columns")
        require(frameWidth > 0 && frameHeight > 0 && columns > 0 && columns * frameWidth == atlas.width)
        fun channel(gray: Int, color: Int) = if (gray <= 127) 2 * gray * color / 255
            else 255 - 2 * (255 - gray) * (255 - color) / 255
        val pixels = IntArray(frameWidth * frameHeight)
        val states = geometry.getJSONObject("states")
        val frames = states.keys().asSequence().associateWith { state ->
            val frame = states.getJSONObject(state).getJSONArray("frames").getInt(0)
            atlas.getPixels(pixels, 0, frameWidth, (frame % columns) * frameWidth, (frame / columns) * frameHeight, frameWidth, frameHeight)
            pixels.indices.forEach { index ->
                val pixel = pixels[index]
                val gray = Color.red(pixel)
                pixels[index] = Color.argb(Color.alpha(pixel), channel(gray, Color.red(tint)),
                    channel(gray, Color.green(tint)), channel(gray, Color.blue(tint)))
            }
            Bitmap.createBitmap(pixels, frameWidth, frameHeight, Bitmap.Config.ARGB_8888)
        }
        tinted.put(tint, frames)
        return frames
    }
}
