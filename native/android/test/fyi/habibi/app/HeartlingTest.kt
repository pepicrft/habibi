package fyi.habibi.app

import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.os.Looper
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.TextView
import androidx.core.view.ViewCompat
import com.google.android.material.bottomnavigation.BottomNavigationView
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.util.ReflectionHelpers
import java.time.Duration
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class, qualifiers = "w411dp-h891dp-420dpi")
class HeartlingTest {
    private val app get() = RuntimeEnvironment.getApplication() as HabibiApplication
    private fun View.walk(): List<View> = listOf(this) + if (this is ViewGroup) (0 until childCount).flatMap { getChildAt(it).walk() } else emptyList()
    private fun MainActivity.tagged(tag: String) = window.decorView.findViewWithTag<View>(tag) ?: error("Missing $tag")
    private fun MainActivity.open(session: HabibiSession) {
        window.decorView.walk().filterIsInstance<BottomNavigationView>().single().selectedItemId = R.id.conversations
        tagged("conversation_${session.conversation.id}").performClick()
    }
    private fun inject(store: MemoryVault = MemoryVault(), core: FixtureCore = FixtureCore(), transport: FixtureTransport = FixtureTransport()): HabibiSession {
        return fixtureSession(store, core, transport).also {
            app.injectedSession = it; app.voiceRecognizerFactory = { FixtureRecognizer(false) }
        }
    }
    private fun tick(millis: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis))
    private fun MainActivity.showWindow() {
        // Robolectric API 35 leaves AttachInfo's window GONE without a real window manager.
        // Deliver the same visibility state Android supplies for a foreground window.
        val attachInfo = ReflectionHelpers.getField<Any>(window.decorView, "mAttachInfo")
        ReflectionHelpers.setField(attachInfo, "mWindowVisibility", View.VISIBLE)
        window.decorView.dispatchWindowVisibilityChanged(View.VISIBLE)
        shadowOf(Looper.getMainLooper()).idle()
    }
    private fun View.expression() = ViewCompat.getStateDescription(this).toString()
    private fun View.assertStill() {
        assertEquals(0f, translationY, 0f)
        assertEquals(0f, rotation, .001f)
    }
    private fun View.hello() {
        val node = createAccessibilityNodeInfo()
        assertEquals("Say hello to Heartling", node.contentDescription.toString())
        assertEquals("android.widget.Button", node.className.toString())
        assertTrue(node.isClickable); assertTrue(node.isFocusable)
        assertTrue(performAccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, null))
        assertEquals("Curious", expression())
        assertTrue(performClick()); assertEquals("Delighted", expression())
    }

    @Test fun welcomeHomeAndEmptyConversationClicksAreAccessibleAndNeverSendOrWrite() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport()
        val session = inject(store, core, transport)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        activity.showWindow()
        activity.tagged("welcome_heartling").hello()
        assertTrue(core.calls.isEmpty()); assertEquals(0, store.saves); assertTrue(transport.bodies.isEmpty())
        session.create(profile())
        val durable = store.durable; val saves = store.saves
        val home = activity.tagged("home_heartling")
        assertEquals(activity.dp(144), home.layoutParams.width)
        home.hello()
        activity.open(session)
        val empty = activity.tagged("conversation_heartling")
        assertEquals(View.VISIBLE, empty.visibility); empty.hello()
        tick(20_000) // Include idle blink callbacks as well as the tap reaction's settlement.
        assertEquals(durable, store.durable); assertEquals(saves, store.saves)
        assertTrue(transport.bodies.isEmpty()); assertTrue(session.lines.isEmpty()); assertEquals("", session.conversationDraft)
        controller.pause().stop().destroy()
    }

    @Test fun workingIndicatorTracksChatCompletionCancellationAndFailureOnly() {
        var duringSend: () -> Unit = {}
        var fail = false
        val transport = object : InferenceTransport {
            override fun send(endpoint: InferenceEndpoint, body: JSONObject, cancelled: AtomicBoolean): JSONObject {
                duringSend()
                check(!fail) { "Fixture connection failure" }
                return JSONObject().put("output", org.json.JSONArray()).put("reply", "Ready.")
            }
            override fun cancel() {}
        }
        val session = HabibiSession(MemoryVault(), FixtureCore()::execute, Executor { it.run() }, { it() }, transport)
        app.injectedSession = session; app.voiceRecognizerFactory = { FixtureRecognizer(false) }
        session.start(); session.create(profile())
        session.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test"))
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        activity.open(session)
        val indicator = activity.tagged("conversation_working")
        val mascot = activity.tagged("working_heartling")
        assertEquals(View.GONE, indicator.visibility)
        assertFalse(mascot.isClickable); assertFalse(mascot.isFocusable); assertFalse(mascot.performClick())
        assertEquals("Attentive", mascot.expression())
        assertTrue(indicator.walk().filterIsInstance<TextView>().any { it.text.toString() == "Habibi is working…" })
        var sends = 0
        duringSend = {
            sends++
            assertTrue(session.chatting); assertEquals(View.VISIBLE, indicator.visibility)
            assertEquals(View.GONE, activity.tagged("conversation_heartling").visibility)
        }
        session.send("A real prompt"); assertEquals(1, sends)
        assertFalse(session.chatting); assertEquals(View.GONE, indicator.visibility)
        assertEquals(View.GONE, activity.tagged("conversation_heartling").visibility)
        val checkWorking = duringSend
        duringSend = { checkWorking(); session.stop() }
        session.send("Stop this reply"); assertEquals(2, sends)
        assertFalse(session.chatting); assertEquals(View.GONE, indicator.visibility)
        duringSend = checkWorking; fail = true
        session.send("This request will fail"); assertEquals(3, sends)
        assertFalse(session.chatting); assertEquals(View.GONE, indicator.visibility)
        controller.pause().stop().destroy()
    }

    @Test fun disabledAnimationsKeepOnlyStaticAlternatingExpressionAndNoDelayedReset() {
        Settings.Global.putFloat(app.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        inject()
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val mascot = controller.get().tagged("welcome_heartling")
        controller.get().showWindow()
        mascot.hello(); mascot.assertStill()
        tick(20_000)
        assertEquals("Delighted", mascot.expression()); mascot.assertStill()
        controller.pause().stop().destroy()
    }

    @Test fun hidingPausingAndDetachingCancelHopAndExpressionCallbacks() {
        Settings.Global.putFloat(app.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        inject()
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get(); val mascot = activity.tagged("welcome_heartling")
        activity.showWindow()
        fun startHop() {
            mascot.performClick(); tick(100)
            assertTrue("Enabled, foreground taps should hop", mascot.translationY < 0f)
        }
        startHop()
        mascot.visibility = View.INVISIBLE
        mascot.assertStill(); val hidden = mascot.expression(); tick(20_000)
        assertEquals(hidden, mascot.expression()); mascot.assertStill()
        mascot.visibility = View.VISIBLE
        startHop()
        controller.pause()
        mascot.assertStill(); val paused = mascot.expression(); tick(20_000)
        assertEquals(paused, mascot.expression()); mascot.assertStill()
        controller.resume()
        startHop()
        activity.tagged("create_habibi").performClick()
        assertFalse(mascot.isAttachedToWindow); mascot.assertStill()
        val detached = mascot.expression(); tick(20_000)
        assertEquals(detached, mascot.expression()); mascot.assertStill()
        controller.pause().stop().destroy()
    }

    @Test fun turningOffAnimationsDuringAHopCancelsItImmediately() {
        Settings.Global.putFloat(app.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        inject()
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val mascot = controller.get().tagged("welcome_heartling")
        controller.get().showWindow()
        mascot.performClick(); tick(100); assertTrue(mascot.translationY < 0f)
        Settings.Global.putFloat(app.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        shadowOf(Looper.getMainLooper()).idle()
        mascot.assertStill(); tick(20_000)
        assertEquals("Curious", mascot.expression()); mascot.assertStill()
        controller.pause().stop().destroy()
    }

    @Test @Config(sdk = [27]) fun android8RetainsNativeAccessibleClickAndReducedMotion() {
        Settings.Global.putFloat(app.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        inject()
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        controller.get().tagged("welcome_heartling").apply { hello(); assertStill() }
        controller.pause().stop().destroy()
    }

    @Test @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun atlasManifestFramesHardLightAlphaAndDayNightPrimaryAreUsedByThePublicView() {
        Settings.Global.putFloat(app.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        val session = inject(); session.start(); session.create(profile())
        val manifest = app.assets.open("heartling/heartling.json").bufferedReader().use { JSONObject(it.readText()) }
        val atlas = app.assets.open("heartling/${manifest.getString("image")}").use { BitmapFactory.decodeStream(it)!! }
        val w = manifest.getInt("frameWidth"); val h = manifest.getInt("frameHeight"); val columns = manifest.getInt("columns")
        assertFalse(app.assets.list("")!!.any { it.endsWith(".mjs") })
        val day = app.createConfigurationContext(Configuration(app.resources.configuration).apply { uiMode = Configuration.UI_MODE_NIGHT_NO })
        val night = app.createConfigurationContext(Configuration(app.resources.configuration).apply { uiMode = Configuration.UI_MODE_NIGHT_YES })
        assertNotEquals(day.color(R.color.primary), night.color(R.color.primary))
        val cases = listOf("forest" to day, "forest" to night, "clay" to day, "clay" to night, "lavender" to day, "lavender" to night, "forest" to day)
        for ((theme, context) in cases) {
            session.updateAppearance(theme, "system")
            val mascot = HeartlingView(context)
            mascot.layout(0, 0, w, h)
            fun assertFrame(state: String) {
                val output = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                mascot.draw(Canvas(output))
                val frame = manifest.getJSONObject("states").getJSONObject(state).getJSONArray("frames").getInt(0)
                val tint = context.color(R.color.primary)
                var transparent = 0; var translucent = 0; var shadows = 0; var highlights = 0
                fun channel(gray: Int, tintChannel: Int) = if (gray <= 127) 2 * gray * tintChannel / 255
                    else 255 - 2 * (255 - gray) * (255 - tintChannel) / 255
                for (y in 0 until h) for (x in 0 until w) {
                    val source = atlas.getPixel((frame % columns) * w + x, (frame / columns) * h + y)
                    val actual = output.getPixel(x, y)
                    val alpha = Color.alpha(source)
                    assertEquals("$state alpha at $x,$y", alpha, Color.alpha(actual))
                    if (alpha == 0) transparent++
                    else if (alpha < 255) translucent++
                    else {
                        val gray = Color.red(source)
                        if (gray <= 127) shadows++ else highlights++
                        assertEquals(Color.rgb(channel(gray, Color.red(tint)), channel(gray, Color.green(tint)), channel(gray, Color.blue(tint))), actual)
                    }
                }
                assertTrue(transparent > 0); assertTrue(translucent > 0); assertTrue(shadows > 0); assertTrue(highlights > 0)
                output.recycle()
            }
            assertFrame("idle")
            mascot.performClick(); assertFrame("curious")
            mascot.performClick(); assertFrame("delighted")
            mascot.working = true; assertFrame("attentive")
            mascot.working = false; assertFrame("idle")
        }
        atlas.recycle()
    }
}
