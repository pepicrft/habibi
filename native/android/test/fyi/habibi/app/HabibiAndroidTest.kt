package fyi.habibi.app

import android.os.Bundle
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.checkbox.MaterialCheckBox
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

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class, qualifiers = "w411dp-h891dp-420dpi")
class HabibiAndroidTest {
    private fun View.walk(): List<View> = listOf(this) + if (this is ViewGroup) (0 until childCount).flatMap { getChildAt(it).walk() } else emptyList()
    private fun MainActivity.tagged(tag: String) = window.decorView.findViewWithTag<View>(tag) ?: error("Missing view: $tag")
    private fun MainActivity.text() = window.decorView.walk().filterIsInstance<TextView>().joinToString("\n") { it.text.toString() }
    private fun inject(store: MemoryVault = MemoryVault(), core: FixtureCore = FixtureCore()): HabibiSession {
        val session = fixtureSession(store, core)
        (RuntimeEnvironment.getApplication() as HabibiApplication).injectedSession = session
        return session
    }
    @Test fun welcomeWizardNativeTabsAndKitsBackStack() {
        val session = inject()
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        assertTrue(activity.text().contains("A little space for you."))
        activity.tagged("create_habibi").performClick()
        (activity.tagged("onboarding_name") as TextInputEditText).setText("Sam")
        activity.tagged("name_continue").performClick()
        activity.tagged("goals_continue").performClick()
        assertTrue(activity.text().contains("Choose at least one intention."))
        (activity.tagged("goal_creativity") as MaterialCheckBox).isChecked = true
        activity.tagged("goals_continue").performClick()
        assertTrue(activity.text().contains("Connect with ChatGPT"))
        assertTrue(activity.text().contains("Skip for now"))
        assertFalse(activity.text().contains("Default model"))
        activity.tagged("provider_continue").performClick()
        assertTrue(activity.text().contains("256-bit symmetric"))
        activity.tagged("create_vault").performClick()
        assertTrue(activity.text().contains("Hello, Sam.")); assertNotNull(session.state)
        val tabs = activity.window.decorView.walk().filterIsInstance<BottomNavigationView>().single()
        assertEquals(3, tabs.menu.size()); assertEquals(View.VISIBLE, tabs.visibility)
        tabs.selectedItemId = R.id.conversations
        assertTrue(activity.text().contains("Not connected"))
        activity.tagged("conversation_${session.conversation.id}").performClick()
        assertFalse(activity.tagged("send_message").isEnabled); assertEquals(View.GONE, tabs.visibility)
        activity.onBackPressedDispatcher.onBackPressed(); assertEquals(View.VISIBLE, tabs.visibility)
        tabs.selectedItemId = R.id.profile; activity.tagged("profile_kits").performClick()
        assertTrue(activity.text().contains("No kits yet"))
        activity.onBackPressedDispatcher.onBackPressed(); assertNotNull(activity.tagged("profile_personalization"))
        activity.onBackPressedDispatcher.onBackPressed(); assertTrue(activity.text().contains("Hello, Sam."))
        assertFalse(activity.text().contains("fixture-content-key"))
        controller.pause().stop().destroy()
    }
    @Test fun profileDefaultAndConversationMenuKeepOverridesLocalAndPreserveTheComposer() {
        val session = inject(); session.start(); session.create(profile())
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        val tabs = activity.window.decorView.walk().filterIsInstance<BottomNavigationView>().single()
        tabs.selectedItemId = R.id.profile; activity.tagged("profile_provider").performClick()
        activity.tagged("default_model").performClick()
        (ShadowDialog.getLatestDialog() as AlertDialog).listView.performItemClick(null, 2, 2)
        assertEquals("gpt-6-luna", session.defaultModel)
        activity.onBackPressedDispatcher.onBackPressed(); tabs.selectedItemId = R.id.conversations
        activity.tagged("conversation_${session.conversation.id}").performClick()
        val editor = activity.tagged("conversation_message") as TextInputEditText
        editor.setText("Keep this draft"); editor.setSelection(4)
        assertNull(activity.window.decorView.findViewWithTag<View>("conversation_model"))
        for ((choice, expected) in listOf(1 to "gpt-6.1-sol", 0 to "gpt-6-luna")) {
            val toolbar = activity.tagged("conversation_toolbar") as MaterialToolbar
            assertTrue(toolbar.menu.getItem(0).title.toString().contains("Model"))
            toolbar.menu.performIdentifierAction(android.view.Menu.FIRST, 0)
            (ShadowDialog.getLatestDialog() as AlertDialog).listView.performItemClick(null, choice, choice.toLong())
            assertEquals(expected, session.conversationModel)
            assertEquals("gpt-6-luna", session.defaultModel)
            assertSame(editor, activity.tagged("conversation_message"))
            assertEquals("Keep this draft", editor.text.toString()); assertEquals(4, editor.selectionStart)
        }
        assertNull(session.conversation.modelOverride)
        controller.pause().stop().destroy()
    }

    @Test fun costumeReviewTryOnAndTakingItOffStayLocalUntilSend() {
        val store = MemoryVault(); val core = FixtureCore(); val session = inject(store, core)
        session.start(); session.create(profile())
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        val tabs = activity.window.decorView.walk().filterIsInstance<BottomNavigationView>().single()
        tabs.selectedItemId = R.id.profile; activity.tagged("profile_costumes").performClick()
        assertTrue(activity.text().contains("Your wardrobe is ready"))
        assertEquals(View.GONE, tabs.visibility)
        activity.tagged("costumes_bundled_Coach").performClick()
        var dialog = ShadowDialog.getLatestDialog() as AlertDialog
        dialog.findViewById<View>(android.R.id.content)!!.findViewWithTag<View>("costumes_try").performClick()
        val trialID = session.conversation.id
        assertEquals("Coach", session.conversation.costume!!.getString("name"))
        assertTrue(activity.text().contains("Take one step at a time."))
        assertEquals("Help me find a first step.", (activity.tagged("conversation_message") as TextInputEditText).text.toString())
        assertTrue(session.wardrobe.isEmpty()); assertTrue(session.lines.isEmpty())
        activity.onBackPressedDispatcher.onBackPressed(); tabs.selectedItemId = R.id.profile
        activity.tagged("profile_costumes").performClick(); activity.tagged("costumes_bundled_Coach").performClick()
        dialog = ShadowDialog.getLatestDialog() as AlertDialog
        dialog.findViewById<View>(android.R.id.content)!!.findViewWithTag<View>("costumes_add").performClick()
        dialog = ShadowDialog.getLatestDialog() as AlertDialog
        assertTrue(session.wardrobe.isEmpty()) // Opening review never installs.
        store.failSave = true
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
        assertTrue(session.wardrobe.isEmpty()); assertTrue(dialog.isShowing)
        store.failSave = false
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
        assertEquals(1, session.wardrobe.size)
        activity.onBackPressedDispatcher.onBackPressed(); tabs.selectedItemId = R.id.conversations
        activity.tagged("conversation_$trialID").performClick()
        val editor = activity.tagged("conversation_message") as TextInputEditText
        activity.tagged("conversation_costume").performClick()
        dialog = ShadowDialog.getLatestDialog() as AlertDialog
        dialog.listView.performItemClick(null, 0, 0)
        assertNull(session.conversation.costume)
        assertFalse(activity.text().contains("Take one step at a time."))
        assertSame(editor, activity.tagged("conversation_message"))
        assertEquals("Help me find a first step.", editor.text.toString())
        session.flushConversations()
        val restored = fixtureSession(store, core); restored.start(); restored.selectConversation(trialID)
        assertNull(restored.conversation.costume); assertEquals(1, restored.wardrobe.size)
        assertEquals("Help me find a first step.", restored.conversationDraft)
        controller.pause().stop().destroy()
    }

    @Test fun rotationKeepsOnboardingDraftAndRestoredVaultKeepsNavigation() {
        val store = MemoryVault(); val core = FixtureCore(); inject(store, core)
        val first = Robolectric.buildActivity(MainActivity::class.java).setup()
        first.get().tagged("create_habibi").performClick()
        (first.get().tagged("onboarding_name") as TextInputEditText).setText("Sam")
        val out = Bundle(); first.saveInstanceState(out).pause().stop().destroy()
        val rotated = Robolectric.buildActivity(MainActivity::class.java).create(out).start().restoreInstanceState(out).resume().visible()
        assertEquals("Sam", (rotated.get().tagged("onboarding_name") as TextInputEditText).text.toString())
        rotated.pause().stop().destroy()
        val session = inject(store, core); session.start(); session.create(profile())
        val signed = Robolectric.buildActivity(MainActivity::class.java).setup()
        signed.get().window.decorView.walk().filterIsInstance<BottomNavigationView>().single().selectedItemId = R.id.profile
        signed.get().tagged("profile_kits").performClick()
        val saved = Bundle(); signed.saveInstanceState(saved).pause().stop().destroy()
        inject(store, core) // Simulate a new application session after process death.
        val restarted = Robolectric.buildActivity(MainActivity::class.java).create(saved).start().restoreInstanceState(saved).resume().visible()
        assertTrue(restarted.get().text().contains("Your kits")); assertNotNull(restarted.get().tagged("design_kit"))
        restarted.pause().stop().destroy()
    }
    @Test fun profileRecoveryImportIsReachableAndDoesNotOverwriteBeforeConfirmation() {
        val store = MemoryVault(); val core = FixtureCore(); val session = inject(store, core)
        session.start(); session.create(profile()); val durable = store.durable
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        activity.window.decorView.walk().filterIsInstance<BottomNavigationView>().single().selectedItemId = R.id.profile
        activity.tagged("profile_recovery").performClick(); activity.tagged("import_recovery").performClick()
        assertNotNull(activity.tagged("recovery_backup")); assertEquals(durable, store.durable)
        assertEquals("Alex", session.state!!.getJSONObject("profile").getString("name"))
        controller.pause().stop().destroy()
    }
    @Test fun nativeApprovalSurvivesRotationAndNeverAcceptsAutomatically() {
        val store = MemoryVault(); val core = FixtureCore(); val session = inject(store, core)
        session.start(); session.create(profile())
        val first = Robolectric.buildActivity(MainActivity::class.java).setup()
        session.tool("save_kit", JSONObject().put("definition", definition()))
        assertTrue((ShadowDialog.getLatestDialog() as AlertDialog).isShowing)
        assertFalse(core.calls.any { it.getString("operation") == "commit_kit" })
        val saved = Bundle(); first.saveInstanceState(saved).pause().stop().destroy()
        assertNotNull(session.review)
        val rotated = Robolectric.buildActivity(MainActivity::class.java).create(saved).start().restoreInstanceState(saved).resume().visible()
        (ShadowDialog.getLatestDialog() as AlertDialog).getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
        shadowOf(Looper.getMainLooper()).idle()
        assertNull(session.review); assertEquals(0, session.state!!.getJSONArray("kits").length())
        session.tool("save_kit", JSONObject().put("definition", definition()))
        (ShadowDialog.getLatestDialog() as AlertDialog).getButton(AlertDialog.BUTTON_POSITIVE).performClick()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(1, session.state!!.getJSONArray("kits").length()); assertEquals(3, store.saves)
        assertEquals(1, session.state!!.getJSONArray("conversations").getJSONObject(0).getJSONArray("messages").length())
        rotated.pause().stop().destroy()
    }
    @Test fun installedKitRendersNativeTypedFieldsAndKeepsEntryAfterRestart() {
        val store = MemoryVault(); val core = FixtureCore(); val session = inject(store, core)
        session.start(); session.create(profile()); session.tool("save_kit", JSONObject().put("definition", definition())); session.decide(session.review!!.ticket, true)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        activity.tagged("home_kits").performClick(); activity.tagged("kit_energy-kit").performClick(); activity.tagged("add_entry").performClick()
        (activity.tagged("entry_energy-kit_energy") as TextInputEditText).setText("7")
        activity.tagged("save_entry").performClick()
        assertTrue(activity.text().contains("Energy: 7"))
        val restarted = fixtureSession(store, core); restarted.start()
        assertEquals(1, restarted.state!!.getJSONArray("kits").getJSONObject(0).getJSONArray("entries").length())
        controller.pause().stop().destroy()
    }
}
