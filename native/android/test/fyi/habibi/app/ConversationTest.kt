package fyi.habibi.app

import android.Manifest
import android.os.Bundle
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewConfiguration
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.textfield.TextInputEditText
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog
import java.time.Duration
import java.util.concurrent.Executor

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class, qualifiers = "w411dp-h891dp-420dpi")
class ConversationTest {
    private fun View.walk(): List<View> = listOf(this) + if (this is ViewGroup) (0 until childCount).flatMap { getChildAt(it).walk() } else emptyList()
    private fun MainActivity.tagged(tag: String) = window.decorView.findViewWithTag<View>(tag) ?: error("Missing $tag")
    private fun MainActivity.tabs() = window.decorView.walk().filterIsInstance<BottomNavigationView>().single()
    private fun MainActivity.open(session: HabibiSession) { tabs().selectedItemId = R.id.conversations; tagged("conversation_${session.conversation.id}").performClick() }
    private fun MainActivity.layoutNow() {
        val root = window.decorView
        root.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(2100, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, 1080, 2100)
        shadowOf(Looper.getMainLooper()).idle()
    }
    private fun inject(transport: FixtureTransport = FixtureTransport(), core: FixtureCore = FixtureCore()): HabibiSession {
        val session = fixtureSession(MemoryVault(), core, transport)
        (RuntimeEnvironment.getApplication() as HabibiApplication).apply { injectedSession = session; voiceRecognizerFactory = { FixtureRecognizer(false) } }
        session.start(); session.create(profile()); session.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test"))
        return session
    }
    @Test fun conflictPickerSwitchesDraftsWithoutSendingOrDiscardingEitherVersion() {
        val core = FixtureCore(); val session = inject(core = core)
        val id = session.conversation.id
        core.recoveredState = JSONObject(session.state!!.toString()).put("conversations", org.json.JSONArray().put(JSONObject()
            .put("id", id).put("createdAt", session.conversation.createdAt).put("composer", "Phone version").put("messages", org.json.JSONArray())))
            .put("drafts", org.json.JSONArray().put(JSONObject().put("id", id).put("versions", org.json.JSONArray()
                .put(JSONObject().put("text", "Phone version")).put(JSONObject().put("text", "Tablet version")))))
        session.recover(JSONObject(), "fixture-key")
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        activity.open(session); activity.layoutNow()
        val editor = activity.tagged("conversation_message") as TextInputEditText
        assertEquals("Phone version", editor.text.toString())
        activity.tagged("draft_versions").performClick()
        val picker = ShadowDialog.getLatestDialog() as AlertDialog
        assertEquals("Tablet version", picker.listView.adapter.getItem(0))
        picker.listView.performItemClick(picker.listView.getChildAt(0), 0, 0)
        activity.layoutNow()
        assertSame(editor, activity.tagged("conversation_message"))
        assertEquals("Tablet version", editor.text.toString())
        assertEquals(listOf("Phone version"), session.otherDrafts)
        assertTrue(session.lines.isEmpty())
        assertFalse(core.calls.any { it.getString("operation") == "agent_request" })
        controller.pause().stop().destroy()
    }

    @Test fun reactionsUpdateExistingRowsWithAnAccessibleBadgeWithoutReplacingTheComposer() {
        val transport = FixtureTransport(); val session = inject(transport)
        session.send("That's all for now")
        val target = session.lines.first().id
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        activity.open(session); activity.layoutNow()
        val row = activity.tagged("message_$target")
        val composer = activity.tagged("conversation_message") as TextInputEditText
        composer.setText("Unsent draft"); composer.setSelection(3)
        val badge = activity.tagged("reaction_$target") as TextView
        assertEquals(View.GONE, badge.visibility)
        for (emoji in listOf("👍", "❤️")) {
            transport.replies.add(JSONObject().put("tool", JSONObject().put("name", "react_to_message").put("callId", "reaction")
                .put("arguments", JSONObject().put("message_id", target).put("emoji", emoji))))
            session.send("Thanks"); activity.layoutNow()
            assertSame(row, activity.tagged("message_$target"))
            assertSame(badge, activity.tagged("reaction_$target"))
            assertEquals(View.VISIBLE, badge.visibility); assertEquals(emoji, badge.text.toString())
            assertEquals("Habibi reacted $emoji", badge.contentDescription)
            assertFalse(badge.isClickable)
            assertSame(composer, activity.tagged("conversation_message"))
        }
        controller.pause().stop().destroy()
    }

    @Test fun inboxPushHidesTabsAcrossImeInsetsAndBackRestoresDraftAndCursor() {
        val session = inject(); val first = session.conversation.id
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        activity.open(session); assertEquals(View.GONE, activity.tabs().visibility)
        val root = (activity.findViewById<ViewGroup>(android.R.id.content)).getChildAt(0)
        for (shown in listOf(true, false, true, false)) {
            val insets = WindowInsetsCompat.Builder().setInsets(WindowInsetsCompat.Type.ime(), Insets.of(0, 0, 0, if (shown) 500 else 0))
                .setVisible(WindowInsetsCompat.Type.ime(), shown).build()
            ViewCompat.dispatchApplyWindowInsets(root, insets)
            assertEquals(View.GONE, activity.tabs().visibility)
        }
        val editor = activity.tagged("conversation_message") as TextInputEditText
        editor.setText("An unfinished thought"); editor.setSelection(3, 8)
        session.updateProfile(profile("Changed"))
        assertSame(editor, activity.tagged("conversation_message")); assertEquals(3, editor.selectionStart); assertEquals(8, editor.selectionEnd)
        activity.onBackPressedDispatcher.onBackPressed(); assertEquals(View.VISIBLE, activity.tabs().visibility)
        activity.tagged("new_conversation").performClick(); val second = session.conversation.id
        assertNotEquals(first, second); assertEquals("", (activity.tagged("conversation_message") as TextInputEditText).text.toString())
        (activity.tagged("conversation_message") as TextInputEditText).setText("Another draft")
        activity.onBackPressedDispatcher.onBackPressed(); activity.tagged("conversation_$first").performClick()
        val restored = activity.tagged("conversation_message") as TextInputEditText
        assertEquals("An unfinished thought", restored.text.toString()); assertEquals(3, restored.selectionStart); assertEquals(8, restored.selectionEnd)
        val saved = Bundle(); controller.saveInstanceState(saved).pause().stop().destroy()
        val rotated = Robolectric.buildActivity(MainActivity::class.java).create(saved).start().restoreInstanceState(saved).resume().visible()
        assertEquals(View.GONE, rotated.get().tabs().visibility)
        assertEquals("An unfinished thought", (rotated.get().tagged("conversation_message") as TextInputEditText).text.toString())
        rotated.pause().stop().destroy()
    }
    @Test fun historiesAreIsolatedAndQueuedSendOrReviewBlocksSwitching() {
        val transport = FixtureTransport(); val session = inject(transport); val first = session.conversation.id
        session.send("First prompt"); val firstIds = session.lines.map { it.id }
        session.conversationDraft = "First draft"; assertTrue(session.newConversation()); val second = session.conversation.id
        session.send("Second prompt")
        assertFalse(transport.bodies.last().toString().contains("First prompt"))
        session.conversationDraft = "Second draft"; assertTrue(session.selectConversation(first))
        assertEquals(firstIds, session.lines.map { it.id }); assertEquals("First draft", session.conversationDraft)
        transport.replies.add(transport.reviewReply()); session.send("Review this")
        assertFalse(session.canSwitchConversation); assertFalse(session.selectConversation(second)); assertFalse(session.newConversation())
        session.stop(); assertTrue(session.selectConversation(second)); assertEquals("Second draft", session.conversationDraft)
        val queue = ArrayDeque<Runnable>()
        val queued = HabibiSession(MemoryVault(), FixtureCore()::execute, Executor { queue.add(it) }, { it() }, FixtureTransport())
        queued.start(); queue.removeFirst().run(); queued.create(profile()); queue.removeFirst().run()
        queued.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test")); queue.removeFirst().run()
        val queuedId = queued.conversation.id; queued.send("Queued")
        assertFalse(queued.newConversation()); assertEquals(queuedId, queued.conversation.id)
        queued.conversationDraft = "Typed while waiting"; queue.removeFirst().run()
        assertEquals("Typed while waiting", queued.conversationDraft)
    }
    @Test fun lifecycleDepartureFlushesDraftBeforeDebounceAndRelaunchRendersRestoredCardAndDraft() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport(); val session = fixtureSession(store, core, transport)
        val app = RuntimeEnvironment.getApplication() as HabibiApplication
        app.injectedSession = session; app.voiceRecognizerFactory = { FixtureRecognizer(false) }
        session.start(); session.create(profile()); session.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test"))
        transport.replies.add(componentReply()); session.send("Remember this card")
        val first = Robolectric.buildActivity(MainActivity::class.java).setup(); first.get().open(session)
        (first.get().tagged("conversation_message") as TextInputEditText).setText("Unsent at departure 🌙")
        val saved = Bundle(); first.saveInstanceState(saved).pause().stop().destroy()
        val restarted = fixtureSession(store, FixtureCore()); app.injectedSession = restarted
        val second = Robolectric.buildActivity(MainActivity::class.java).create(saved).start().restoreInstanceState(saved).resume().visible()
        assertEquals("Unsent at departure 🌙", (second.get().tagged("conversation_message") as TextInputEditText).text.toString())
        assertEquals(session.conversation.id, restarted.conversation.id)
        assertEquals(session.lines, restarted.lines); assertFalse(restarted.connected)
        assertNotNull(second.get().tagged("component_show_source"))
        second.pause().stop().destroy()
    }
    @Test fun promptNavigationPreservesDraftAndReaderPositionLatestResumesFollowing() {
        val transport = FixtureTransport(); val session = inject(transport)
        repeat(12) { session.send("Prompt $it\n" + "A longer thought to make history scroll. ".repeat(6)) }
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get(); activity.open(session); activity.layoutNow()
        val editor = activity.tagged("conversation_message") as TextInputEditText
        editor.setText("Do not send or change"); editor.setSelection(4)
        val scroll = activity.tagged("conversation_transcript") as ScrollView
        assertTrue(scroll.scrollY > 0)
        val composer = activity.tagged("conversation_composer")
        assertFalse(scroll.walk().contains(composer)) // Composer is pinned, not a transcript child.
        scroll.scrollTo(0, 0); val before = scroll.scrollY
        assertEquals(View.VISIBLE, activity.tagged("conversation_latest").visibility)
        session.send("New output while reading history"); activity.layoutNow()
        assertEquals(before, scroll.scrollY); assertSame(editor, activity.tagged("conversation_message")); assertEquals(4, editor.selectionStart)
        activity.tagged("conversation_prompts").performClick()
        val prompts = ShadowDialog.getLatestDialog() as AlertDialog
        assertEquals(13, prompts.listView.adapter.count)
        assertTrue(prompts.listView.adapter.getItem(0).toString().contains("New output"))
        prompts.listView.performItemClick(null, 7, 7)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(scroll.scrollY > 0); assertEquals("Do not send or change", editor.text.toString()); assertEquals(4, editor.selectionStart)
        activity.tagged("conversation_latest").performClick(); activity.layoutNow()
        assertEquals(View.GONE, activity.tagged("conversation_latest").visibility)
        val bottom = scroll.scrollY; session.send("Follow this output"); activity.layoutNow()
        assertTrue(scroll.scrollY > bottom); assertEquals("Do not send or change", editor.text.toString())
        controller.pause().stop().destroy()
    }
    @Test fun consentCancelKeepsDraftAllowSendsOnceAndComposerSurvivesReply() {
        val transport = FixtureTransport(); val session = inject(transport)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get(); activity.open(session)
        val field = activity.tagged("conversation_message") as TextInputEditText; field.setText("A real prompt")
        activity.tagged("send_message").performClick()
        (ShadowDialog.getLatestDialog() as AlertDialog).getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(transport.bodies.isEmpty()); assertEquals("A real prompt", field.text.toString())
        activity.tagged("send_message").performClick()
        (ShadowDialog.getLatestDialog() as AlertDialog).getButton(AlertDialog.BUTTON_POSITIVE).performClick()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(1, transport.bodies.size); assertEquals("", field.text.toString()); assertSame(field, activity.tagged("conversation_message"))
        assertEquals(listOf("You", "Habibi"), session.lines.map { it.role }); assertEquals(View.GONE, activity.tabs().visibility)
        controller.pause().stop().destroy()
    }
    @Test fun stableHeldMicrophoneTapStopAndDiscardOnlyAppendEditableTextAndFenceDeparture() {
        val transport = FixtureTransport(); val session = inject(transport); val recognizer = FixtureRecognizer()
        val app = RuntimeEnvironment.getApplication() as HabibiApplication
        app.voiceRecognizerFactory = { recognizer }; shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get(); activity.open(session)
        val editor = activity.tagged("conversation_message") as TextInputEditText; editor.setText("Typed first")
        val mic = activity.tagged("voice_microphone")
        fun touch(action: Int) { val event = MotionEvent.obtain(0, 0, action, 20f, 20f, 0); mic.dispatchTouchEvent(event); event.recycle() }
        touch(MotionEvent.ACTION_DOWN); shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ViewConfiguration.getLongPressTimeout().toLong() + 1))
        assertSame(mic, activity.tagged("voice_microphone")); assertEquals(View.VISIBLE, activity.tagged("voice_waveform").visibility)
        recognizer.sessions.last().partial("held words"); touch(MotionEvent.ACTION_UP)
        assertEquals(1, recognizer.stops); recognizer.sessions.last().result("Held words")
        assertEquals("Typed first Held words", editor.text.toString()); assertEquals(1, recognizer.sessions.size)
        mic.performClick(); val discarded = recognizer.sessions.last(); discarded.partial("Remove me")
        activity.tagged("voice_discard").performClick(); discarded.result("Remove me")
        assertEquals("Typed first Held words", editor.text.toString())
        mic.performClick(); val tapped = recognizer.sessions.last(); mic.performClick(); tapped.result("Tap words")
        assertEquals("Typed first Held words Tap words", editor.text.toString())
        mic.performClick(); val departing = recognizer.sessions.last(); controller.pause(); departing.result("Stale after pause")
        assertEquals("Typed first Held words Tap words", session.conversationDraft)
        assertTrue(transport.bodies.isEmpty()); assertTrue(session.lines.isEmpty()); controller.stop().destroy()
    }
    @Test fun componentValidationAndActionsAreLocalBoundedToSelectedConversationAndFailClosed() {
        val transport = FixtureTransport(); val core = FixtureCore(); val session = inject(transport, core)
        transport.replies.add(componentReply()); session.send("Show synthetic data")
        val line = session.lines.single { it.component != null }; val original = session.conversation.id
        assertTrue(transport.bodies.last().toString().contains("displayed\\\":true"))
        val bodies = transport.bodies.size; var disclosures = 0
        session.componentSource(original, line.id, "show_source") { data -> assertEquals("Synthetic energy", data.getString("title")); disclosures++ }
        session.componentSource(original, line.id, "open_url") { disclosures++ }
        session.componentSource(original, "unknown", "show_source") { disclosures++ }
        core.failOperation = "validate_component"
        session.componentSource(original, line.id, "show_source") { disclosures++ }
        assertEquals(1, disclosures); assertEquals(bodies, transport.bodies.size)
        core.failOperation = null; session.newConversation()
        session.componentSource(original, line.id, "show_source") { disclosures++ }; assertEquals(1, disclosures)
        val rejected = FixtureTransport(); val rejecting = FixtureCore(); val bad = inject(rejected, rejecting)
        rejecting.failOperation = "validate_component"; rejected.replies.add(componentReply()); bad.send("Reject this")
        assertTrue(bad.lines.none { it.component != null }); assertFalse(rejected.bodies.last().toString().contains("displayed"))
    }
    @Test @Config(sdk = [27]) fun nativeComponentFallbackRemainsInteractiveOnAndroid8() {
        val transport = FixtureTransport(); val session = inject(transport)
        transport.replies.add(componentReply()); session.send("Show data")
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get(); activity.open(session)
        assertTrue(activity.window.decorView.walk().filterIsInstance<TextView>().any { it.text.toString() == "Synthetic energy: Monday, 7" })
        activity.tagged("component_show_source").performClick()
        val dialog = ShadowDialog.getLatestDialog() as AlertDialog
        assertTrue(dialog.isShowing); assertTrue(dialog.window!!.decorView.walk().filterIsInstance<TextView>().any { it.text.toString().contains("Monday") })
        val bodies = transport.bodies.size; activity.onBackPressedDispatcher.onBackPressed()
        assertFalse(dialog.isShowing); assertEquals(bodies, transport.bodies.size)
        controller.pause().stop().destroy()
    }
}
