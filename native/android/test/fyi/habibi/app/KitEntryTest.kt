package fyi.habibi.app

import android.content.Context
import android.os.Looper
import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.TextView
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration
import java.time.LocalDate
import java.util.concurrent.Executor
import javax.crypto.KeyGenerator

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class, qualifiers = "w411dp-h891dp-420dpi")
class KitEntryTest {
    private val endpoint = InferenceEndpoint("http://localhost:8083/inference", "fixture-only")
    private val app get() = RuntimeEnvironment.getApplication() as HabibiApplication
    private fun View.walk(): List<View> = listOf(this) + if (this is ViewGroup) (0 until childCount).flatMap { getChildAt(it).walk() } else emptyList()
    private fun MainActivity.tagged(tag: String) = window.decorView.findViewWithTag<View>(tag) ?: error("Missing $tag")
    private fun MainActivity.open(session: HabibiSession) {
        window.decorView.walk().filterIsInstance<BottomNavigationView>().single().selectedItemId = R.id.conversations
        tagged("conversation_${session.conversation.id}").performClick()
    }
    private fun strength() = JSONObject("""{"apiVersion":1,"name":"Strength journal","description":"Your training sets","fields":[
        {"key":"date","label":"Training date","type":"date","unit":"","min":null,"max":null},
        {"key":"exercise","label":"Exercise","type":"text","unit":"","min":null,"max":null},
        {"key":"weight","label":"Weight","type":"number","unit":"kg","min":0,"max":500},
        {"key":"reps","label":"Repetitions","type":"number","unit":"reps","min":1,"max":100}
        ],"source":"function summarize(s){return JSON.stringify({metrics:[]})}"}""")
    private fun card() = JSONObject("""{"type":"kit_entry","version":1,"data":{"title":"Log this set","kitId":"energy-kit","prefill":[
        {"key":"exercise","value":"Squat"},{"key":"weight","value":7}]},"actions":[{"id":"save_entry","label":"Save set"}],"fallback":"Enter your set privately."}""")
    private fun values() = JSONObject().put("date", LocalDate.now().toString()).put("exercise", "Private deadlift 🏋️").put("weight", 9.5).put("reps", 37)
    private fun install(session: HabibiSession) {
        session.tool("save_kit", JSONObject().put("definition", strength())); session.decide(session.review!!.ticket, true)
    }
    private fun ready(store: MemoryVault = MemoryVault(), core: FixtureCore = FixtureCore(), wire: FixtureTransport = FixtureTransport()): HabibiSession {
        val session = fixtureSession(store, core, wire)
        app.injectedSession = session; app.voiceRecognizerFactory = { FixtureRecognizer(false) }
        session.start(); session.create(profile()); install(session); session.configure(endpoint)
        wire.replies.add(componentReply(card())); session.send("Show a private set card")
        return session
    }
    private fun HabibiSession.entryLine() = lines.single { it.component?.let { value -> JSONObject(value).optString("type") } == "kit_entry" }
    private fun MainActivity.edit(line: ChatLine, key: String) = tagged("kit_entry_${line.id}_$key") as TextInputEditText
    private fun MainActivity.fill(line: ChatLine) {
        edit(line, "exercise").setText("Private deadlift 🏋️"); edit(line, "weight").setText("9.5"); edit(line, "reps").setText("37")
    }
    private fun HabibiSession.entries() = state!!.getJSONArray("kits").getJSONObject(0).getJSONArray("entries")
    private fun FixtureCore.operations() = calls.map { it.getString("operation") }

    @Test fun conversationShowsInstalledNativeFieldsEditableContextAndUnchangedResultTableWithoutPrivateWrites() {
        val store = MemoryVault(); val core = FixtureCore(); val wire = FixtureTransport(); val session = ready(store, core, wire)
        wire.replies.add(componentReply()); session.send("Also display synthetic results")
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get(); activity.open(session)
        val line = session.entryLine()
        assertEquals(LocalDate.now().toString(), activity.edit(line, "date").text.toString())
        assertEquals("Squat", activity.edit(line, "exercise").text.toString()); assertEquals("7", activity.edit(line, "weight").text.toString())
        assertEquals("", activity.edit(line, "reps").text.toString())
        assertEquals(InputType.TYPE_CLASS_NUMBER, activity.edit(line, "reps").inputType and InputType.TYPE_MASK_CLASS)
        assertEquals("Repetitions (reps)", activity.edit(line, "reps").contentDescription.toString())
        assertFalse(activity.edit(line, "reps").isSaveEnabled)
        assertTrue(activity.tagged("kit_entry_save_${line.id}").isEnabled)
        assertNotNull(activity.tagged("component_show_source"))
        val durable = store.durable; val calls = core.calls.size; val requests = wire.bodies.size
        activity.fill(line); shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(2))
        assertEquals(calls, core.calls.size); assertEquals(durable, store.durable); assertEquals(requests, wire.bodies.size)
        assertEquals(0, session.entries().length()); assertNull(session.entryLine().entryId)
        activity.tagged("component_show_source").performClick()
        assertEquals(requests, wire.bodies.size)
        controller.pause().stop().destroy()
    }

    @Test fun accessibleSaveDurablyUpdatesExistingCardAndReloadShowsStoredValuesWithoutProviderDisclosure() {
        val store = MemoryVault(); val core = FixtureCore(); val wire = FixtureTransport(); val session = ready(store, core, wire)
        val first = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = first.get(); activity.open(session)
        val line = session.entryLine(); activity.fill(line)
        val composer = activity.tagged("conversation_message") as TextInputEditText
        composer.setText("Keep my unsent thought"); composer.setSelection(5)
        val requests = wire.bodies.size
        assertTrue(activity.tagged("kit_entry_save_${line.id}").performAccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, null))
        val saved = session.entryLine(); assertNotNull(saved.entryId)
        assertEquals(line.id, saved.id); assertEquals(1, session.entries().length())
        assertEquals("Private deadlift 🏋️", session.entries().getJSONObject(0).getJSONObject("values").getString("exercise"))
        assertFalse(activity.tagged("kit_entry_save_${line.id}").isEnabled); assertFalse(activity.edit(line, "reps").isEnabled)
        assertEquals("37", activity.edit(line, "reps").text.toString()); assertEquals("Private deadlift 🏋️", activity.edit(line, "exercise").text.toString())
        assertSame(composer, activity.tagged("conversation_message")); assertEquals(5, composer.selectionStart)
        assertEquals("Keep my unsent thought", composer.text.toString()); assertEquals(requests, wire.bodies.size)
        val calls = core.calls.size; session.submitKitEntry(session.conversation.id, line.id, values())
        assertEquals(calls, core.calls.size); assertEquals(1, session.entries().length())
        first.pause().stop().destroy()
        val restartedWire = FixtureTransport(); val restarted = fixtureSession(store, FixtureCore(), restartedWire)
        app.injectedSession = restarted; restarted.start()
        val second = Robolectric.buildActivity(MainActivity::class.java).setup(); second.get().open(restarted)
        assertEquals(saved.entryId, restarted.entryLine().entryId)
        assertFalse(second.get().tagged("kit_entry_save_${line.id}").isEnabled)
        assertEquals("Private deadlift 🏋️", second.get().edit(line, "exercise").text.toString())
        restarted.configure(endpoint); restarted.send("Continue without disclosing my saved set")
        val request = restartedWire.bodies.single().toString()
        assertFalse(request.contains("Private deadlift")); assertFalse(request.contains(saved.entryId!!)); assertFalse(request.contains("entryId"))
        val acknowledgment = wire.bodies.last().getJSONArray("input").toString()
        assertTrue(acknowledgment.contains("displayed")); assertFalse(acknowledgment.contains("Private deadlift"))
        second.pause().stop().destroy()
    }

    @Test fun invalidInputsUseInstalledRangesAndCalendarValidationAndNeverCallTheCore() {
        val core = FixtureCore(); val session = ready(core = core)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get(); activity.open(session)
        val line = session.entryLine(); val before = core.calls.size
        activity.edit(line, "reps").setText("101"); activity.edit(line, "date").setText("2026-02-30")
        activity.tagged("kit_entry_save_${line.id}").performClick()
        assertEquals(before, core.calls.size); assertNull(session.entryLine().entryId)
        assertTrue((activity.tagged("kit_entry_status_${line.id}") as TextView).text.contains("Nothing was saved"))
        activity.edit(line, "date").setText(LocalDate.now().toString()); activity.edit(line, "reps").setText("0")
        activity.tagged("kit_entry_save_${line.id}").performClick(); assertEquals(before, core.calls.size)
        activity.edit(line, "reps").setText("10"); activity.edit(line, "exercise").setText(" ")
        activity.tagged("kit_entry_save_${line.id}").performClick(); assertEquals(before, core.calls.size)
        controller.pause().stop().destroy()
    }

    @Test fun missingKitAndInvalidOrUndeclaredPrefillFailClosedWithoutModelDefinedInputs() {
        val core = FixtureCore(); val wire = FixtureTransport(); val session = ready(core = core, wire = wire)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        fun changedPrefill(value: Any) = card().apply { getJSONObject("data").put("prefill", value) }
        val invalid = listOf(
            card().apply { getJSONObject("data").put("kitId", "missing-kit") },
            changedPrefill(JSONObject()),
            card().apply { getJSONObject("data").remove("prefill") },
            changedPrefill(JSONArray("""[{"key":"reps","value":"10"}]""")),
            changedPrefill(JSONArray("""[{"key":"reps","value":101}]""")),
            changedPrefill(JSONArray("""[{"key":"reps","value":true}]""")),
            changedPrefill(JSONArray("""[{"key":"constructor","value":"not a field"}]""")),
            changedPrefill(JSONArray("""[{"key":"reps","value":10},{"key":"reps","value":11}]""")),
            changedPrefill(JSONArray("""[{"key":"date","value":"2026-02-30"}]""")),
            changedPrefill(JSONArray("""[{"key":"exercise","value":{"type":"number"}}]"""))
        )
        val calls = core.calls.size; val sends = wire.bodies.size
        invalid.forEach { component ->
            val line = ChatLine("Habibi", "Enter privately", component = component.toString())
            val view = KitEntryCard(activity, session, session.conversation.id, line.id, component); view.render(line)
            assertTrue(view.walk().filterIsInstance<TextInputEditText>().isEmpty()); assertTrue(view.walk().filterIsInstance<MaterialButton>().isEmpty())
            assertTrue(view.walk().filterIsInstance<TextView>().any { it.text.contains("Kit entry unavailable") })
        }
        val empty = changedPrefill(JSONArray()); val line = ChatLine("Habibi", "Enter privately", component = empty.toString())
        val valid = KitEntryCard(activity, session, session.conversation.id, line.id, empty); valid.render(line)
        assertEquals(4, valid.walk().filterIsInstance<TextInputEditText>().size)
        assertEquals(calls, core.calls.size); assertEquals(sends, wire.bodies.size)
        controller.pause().stop().destroy()
    }

    @Test fun archiveCheckpointPrecedesAtomicSaveAutosaveIsFencedAndNewerComposerEditsSurvive() {
        val store = MemoryVault(); val core = FixtureCore(); val wire = FixtureTransport(); val session = ready(store, core, wire)
        val line = session.entryLine(); val chat = session.conversation
        session.conversationDraft = "Snapshot before saving"
        val before = core.calls.size; val sends = wire.bodies.size
        var writes = 0
        store.beforeSave = {
            assertNull(session.entryLine().entryId); assertEquals(0, session.entries().length())
            session.conversationDraft = if (++writes == 1) "Typed during checkpoint" else "Typed during atomic save"
            session.flushConversations(); assertFalse(session.newConversation())
            session.submitKitEntry(chat.id, line.id, values())
        }
        session.submitKitEntry(chat.id, line.id, values())
        assertEquals(listOf("save_conversations", "submit_kit_entry"), core.operations().drop(before))
        assertEquals(2, writes); assertEquals(sends, wire.bodies.size); assertSame(chat, session.conversation)
        assertEquals("Typed during atomic save", session.conversationDraft); assertNotNull(session.entryLine().entryId)
        assertEquals("Snapshot before saving", session.state!!.getJSONArray("conversations").getJSONObject(0).getString("composer"))
        store.beforeSave = {}; session.flushConversations()
        val restored = fixtureSession(store, FixtureCore()); restored.start()
        assertEquals("Typed during atomic save", restored.conversationDraft); assertEquals(session.entryLine().entryId, restored.entryLine().entryId)
        assertEquals(1, restored.entries().length())
    }

    @Test fun checkpointCoreAndDurableSaveFailuresKeepCardRetryableAndNeverPublishSuccess() {
        val store = MemoryVault(); val core = FixtureCore(); val session = ready(store, core)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get(); activity.open(session)
        val line = session.entryLine(); activity.fill(line); session.conversationDraft = "Requires a checkpoint"
        val before = core.operations().count { it == "submit_kit_entry" }
        core.failOperation = "save_conversations"; activity.tagged("kit_entry_save_${line.id}").performClick()
        assertEquals(before, core.operations().count { it == "submit_kit_entry" }); assertNull(session.entryLine().entryId)
        core.failOperation = "submit_kit_entry"; activity.tagged("kit_entry_save_${line.id}").performClick()
        assertEquals(0, session.entries().length()); assertNull(session.entryLine().entryId)
        core.failOperation = null; store.failSave = true; val durable = store.durable
        activity.tagged("kit_entry_save_${line.id}").performClick()
        assertEquals(durable, store.durable); assertNull(session.entryLine().entryId); assertEquals(0, session.entries().length())
        assertEquals("Private deadlift 🏋️", activity.edit(line, "exercise").text.toString())
        assertEquals("Not saved yet.", (activity.tagged("kit_entry_status_${line.id}") as TextView).text.toString())
        assertTrue(activity.tagged("kit_entry_save_${line.id}").isEnabled)
        store.failSave = false; activity.tagged("kit_entry_save_${line.id}").performClick()
        assertNotNull(session.entryLine().entryId); assertEquals(1, session.entries().length())
        controller.pause().stop().destroy()
    }

    @Test fun workChatReviewAndSyncFencesPreventSubmissionAndDisableTheNativeCard() {
        val store = MemoryVault(); val core = FixtureCore(); val wire = FixtureTransport(); val session = ready(store, core, wire)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get(); activity.open(session)
        val line = session.entryLine(); activity.fill(line)
        wire.replies.add(wire.reviewReply()); session.send("Review this Kit first")
        assertTrue(session.chatting); assertNotNull(session.review)
        val before = core.calls.size; session.submitKitEntry(session.conversation.id, line.id, values())
        assertEquals(before, core.calls.size); assertFalse(activity.tagged("kit_entry_save_${line.id}").isEnabled)
        assertFalse(activity.edit(line, "reps").isEnabled)
        session.stop(); assertTrue(activity.tagged("kit_entry_save_${line.id}").isEnabled)
        session.tool("save_kit", JSONObject().put("definition", strength()))
        assertFalse(session.chatting); assertNotNull(session.review)
        val reviewed = core.calls.size; session.submitKitEntry(session.conversation.id, line.id, values())
        assertEquals(reviewed, core.calls.size); assertFalse(activity.tagged("kit_entry_save_${line.id}").isEnabled)
        session.decide(session.review!!.ticket, false)
        controller.pause().stop().destroy()
        val queue = ArrayDeque<Runnable>(); val queuedCore = FixtureCore()
        val queued = HabibiSession(store, queuedCore::execute, Executor { queue.add(it) }, { it() })
        queued.start(); queue.removeFirst().run()
        assertEquals(line.id, queued.entryLine().id); assertTrue(queued.canSubmitKitEntry)
        queued.configure(null); queued.submitKitEntry(queued.conversation.id, line.id, values())
        assertEquals(1, queue.size); queue.removeFirst().run()
        queued.syncNow(); assertTrue(queued.syncing); queued.submitKitEntry(queued.conversation.id, line.id, values())
        assertEquals(1, queue.size); queue.removeFirst().run()
        assertFalse(queuedCore.operations().contains("submit_kit_entry"))
    }

    @Test fun unsavedInlineValuesResetOnNavigationRatherThanClaimingDraftPersistence() {
        val store = MemoryVault(); val session = ready(store)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get(); activity.open(session)
        val line = session.entryLine(); val durable = store.durable
        activity.fill(line); activity.onBackPressedDispatcher.onBackPressed(); activity.open(session)
        assertEquals("Squat", activity.edit(line, "exercise").text.toString()); assertEquals("", activity.edit(line, "reps").text.toString())
        assertEquals(durable, store.durable); assertEquals(0, session.entries().length())
        controller.pause().stop().destroy()
    }

    @Test fun privateValuesAndReceiptUseOnlyEncryptedStorageAndReloadWithoutInference() {
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val storage = SecureVaultStorage(app, keyProvider = { key })
        val core = FixtureCore(); val wire = FixtureTransport()
        val session = HabibiSession(storage, core::execute, Executor { it.run() }, { it() }, wire)
        session.start(); session.create(profile()); install(session); session.configure(endpoint)
        wire.replies.add(componentReply(card())); session.send("Show a private set card")
        val line = session.entryLine(); session.submitKitEntry(session.conversation.id, line.id, values())
        val receipt = session.entryLine().entryId!!
        val raw = app.getSharedPreferences("habibi.sealed-vault", Context.MODE_PRIVATE).all.toString()
        assertFalse(raw.contains("Private deadlift")); assertFalse(raw.contains(receipt)); assertFalse(raw.contains("entryId"))
        val freshWire = FixtureTransport()
        val restored = HabibiSession(storage, core::execute, Executor { it.run() }, { it() }, freshWire); restored.start()
        assertEquals(receipt, restored.entryLine().entryId)
        assertEquals("Private deadlift 🏋️", restored.entries().getJSONObject(0).getJSONObject("values").getString("exercise"))
        assertTrue(freshWire.bodies.isEmpty()); assertFalse(restored.connected)
    }

    @Test fun changedConversationUnknownMessageAndResultTableCannotSubmitAnEntry() {
        val core = FixtureCore(); val wire = FixtureTransport(); val session = ready(core = core, wire = wire)
        val chat = session.conversation.id; val line = session.entryLine()
        wire.replies.add(componentReply()); session.send("Show a table")
        val table = session.lines.single { it.component?.let { value -> JSONObject(value).optString("type") } == "result_table" }
        val before = core.calls.size
        session.submitKitEntry(chat, "unknown", values()); session.submitKitEntry(chat, table.id, values())
        assertEquals(before, core.calls.size)
        assertTrue(session.newConversation()); session.submitKitEntry(chat, line.id, values())
        assertEquals(before, core.calls.size); assertEquals(0, session.entries().length())
    }
}
