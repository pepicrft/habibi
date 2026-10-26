package fyi.habibi.app

import android.os.Bundle
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.bottomnavigation.BottomNavigationView
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
