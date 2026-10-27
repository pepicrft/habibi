package fyi.habibi.app

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.RadioButton
import android.widget.TextView
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.button.MaterialButton
import com.google.android.material.progressindicator.LinearProgressIndicator
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
import java.io.File
import java.util.concurrent.Executor
import javax.crypto.KeyGenerator

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class)
class NativeThemesTest {
    private val app get() = RuntimeEnvironment.getApplication() as HabibiApplication
    private fun bytes() = app.assets.open("themes.json").use { it.readBytes() }
    private fun immediateThemes(wire: SyncTransport = SyncTransport { _, _, _, _, _ -> error("No startup network is allowed") }) =
        NativeThemes(app, wire, Executor { it.run() }, { it() })
    private fun View.walk(): List<View> = listOf(this) + if (this is ViewGroup) (0 until childCount).flatMap { getChildAt(it).walk() } else emptyList()
    private fun MainActivity.tagged(tag: String) = window.decorView.findViewWithTag<View>(tag) ?: error("Missing $tag")
    private fun MainActivity.tabs() = window.decorView.walk().filterIsInstance<BottomNavigationView>().single()
    private fun MainActivity.appearance() { tabs().selectedItemId = R.id.profile; tagged("profile_appearance").performClick() }
    private fun inject(store: MemoryVault = MemoryVault(), core: FixtureCore = FixtureCore(), transport: FixtureTransport = FixtureTransport()): HabibiSession {
        app.injectedThemes = immediateThemes()
        return fixtureSession(store, core, transport).also {
            app.injectedSession = it; app.voiceRecognizerFactory = { FixtureRecognizer(false) }
            it.start(); it.create(profile().put("extra", JSONObject().put("keep", true)))
        }
    }

    @Test @Config(sdk = [28, 35])
    fun iconChoicesKeepOneLauncherSurviveRecreationAndLeaveVaultAndOAuthEntryUnchanged() {
        val session = inject()
        val savedProfile = session.state!!.getJSONObject("profile").toString()
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(app.packageName)
        val callback = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("fyi.habibi.android://callback"))
            .addCategory(Intent.CATEGORY_BROWSABLE).setPackage(app.packageName)
        fun launcherName() = app.packageManager.queryIntentActivities(launcher, 0).map { it.activityInfo.name }
        assertEquals(listOf("${app.packageName}.LauncherForest"), launcherName())
        var controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        for (id in listOf("midnight", "blossom", "forest")) {
            val activity = controller.get(); activity.appearance()
            val choice = activity.tagged("app_icon_$id") as RadioButton
            assertNotNull(choice.compoundDrawablesRelative[0])
            choice.performClick()
            assertTrue(choice.isChecked)
            val title = id.replaceFirstChar { it.uppercaseChar() }
            assertEquals(listOf("${app.packageName}.Launcher$title"), launcherName())
            assertEquals(listOf("${app.packageName}.MainActivity"), app.packageManager.queryIntentActivities(callback, 0).map { it.activityInfo.name })
            assertEquals(savedProfile, session.state!!.getJSONObject("profile").toString())
            controller.pause().stop().destroy()
            controller = Robolectric.buildActivity(MainActivity::class.java).setup()
            controller.get().appearance()
            assertTrue((controller.get().tagged("app_icon_$id") as RadioButton).isChecked)
        }
        controller.pause().stop().destroy()
    }

    @Test fun bundledServerCatalogSupportsLegacyProfilesUnknownIdsAndSystemModesWithoutWrites() {
        val catalog = ThemeCatalog.parse(bytes())
        assertEquals("forest", catalog.defaultTheme)
        assertEquals(listOf("forest", "clay", "lavender"), catalog.themes.map { it.id })
        val themes = immediateThemes()
        val light = app.createConfigurationContext(Configuration(app.resources.configuration).apply { uiMode = Configuration.UI_MODE_NIGHT_NO })
        val dark = app.createConfigurationContext(Configuration(app.resources.configuration).apply { uiMode = Configuration.UI_MODE_NIGHT_YES })
        assertEquals(catalog.resolve("forest").light, themes.palette(light, profile()))
        assertEquals(catalog.resolve("forest").dark, themes.palette(dark, profile()))
        val unknown = profile().put("theme", "not-in-this-catalog").put("appearance", "dark")
        assertEquals(catalog.resolve("forest").dark, themes.palette(light, unknown))
        assertEquals("not-in-this-catalog", unknown.getString("theme"))
        assertEquals(catalog.resolve("clay").light, themes.palette(dark, profile().put("theme", "clay").put("appearance", "light")))
    }

    @Test fun appearanceSavesOnlyAfterDurableProfileInstallPreservesOtherPrefsAndFailureKeepsOldPalette() {
        val store = MemoryVault(); val core = FixtureCore(); val session = inject(store, core)
        val before = session.state!!.getJSONObject("profile").toString()
        val oldColor = app.color(R.color.primary)
        store.beforeSave = { assertEquals(before, session.state!!.getJSONObject("profile").toString()); assertEquals(oldColor, app.color(R.color.primary)) }
        store.failSave = true
        session.updateAppearance("clay", "dark")
        assertEquals(before, session.state!!.getJSONObject("profile").toString()); assertEquals(oldColor, app.color(R.color.primary))
        store.failSave = false
        session.updateAppearance("clay", "dark")
        val saved = session.state!!.getJSONObject("profile")
        assertEquals("clay", saved.getString("theme")); assertEquals("dark", saved.getString("appearance"))
        assertEquals("Alex", saved.getString("name")); assertTrue(saved.getJSONObject("extra").getBoolean("keep"))
        assertEquals(app.themes.catalog.resolve("clay").dark.getValue("primary"), app.color(R.color.primary))
        val restarted = fixtureSession(store, core); restarted.start()
        assertEquals(saved.toString(), restarted.state!!.getJSONObject("profile").toString())
        assertTrue(core.calls.filter { it.optString("operation") == "profile" }.all { it.getJSONObject("profile").getJSONObject("extra").getBoolean("keep") })
    }

    @Test fun selectedAppearanceIsEncryptedAtRestWithNoPlaintextPreferenceCopyAndReloads() {
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val storage = SecureVaultStorage(app, keyProvider = { key })
        val core = FixtureCore()
        val session = HabibiSession(storage, core::execute, Executor { it.run() }, { it() })
        session.start(); session.create(profile()); session.updateAppearance("lavender", "dark")
        val raw = app.getSharedPreferences("habibi.sealed-vault", Context.MODE_PRIVATE).all.toString()
        assertFalse(raw.contains("lavender")); assertFalse(raw.contains("appearance")); assertFalse(raw.contains("theme"))
        val restarted = HabibiSession(storage, core::execute, Executor { it.run() }, { it() }); restarted.start()
        assertEquals("lavender", restarted.state!!.getJSONObject("profile").getString("theme"))
        assertEquals("dark", restarted.state!!.getJSONObject("profile").getString("appearance"))
    }

    @Test fun appearanceUiRecolorsNativeChromeControlsAndKeepsPrefsWhenPersonalizationSaves() {
        val store = MemoryVault(); val core = FixtureCore(); val session = inject(store, core)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        activity.appearance()
        (activity.tagged("theme_clay") as RadioButton).performClick()
        assertEquals("clay", session.state!!.getJSONObject("profile").getString("theme"))
        val primary = app.themes.catalog.resolve("clay").light.getValue("primary")
        assertEquals(primary, activity.color(R.color.primary))
        assertEquals(primary, (activity.tagged("refresh_themes") as MaterialButton).currentTextColor)
        assertEquals(primary, activity.tabs().itemIconTintList!!.getColorForState(intArrayOf(android.R.attr.state_enabled, android.R.attr.state_checked), 0))
        assertEquals(primary, activity.window.decorView.walk().filterIsInstance<LinearProgressIndicator>().single().indicatorColor.single())
        assertEquals(activity.color(R.color.paper), (activity.window.decorView.walk().filterIsInstance<MaterialToolbar>().single().background as ColorDrawable).color)
        activity.onBackPressedDispatcher.onBackPressed(); activity.tagged("profile_personalization").performClick()
        (activity.tagged("profile_name") as TextInputEditText).setText("Renamed")
        activity.tagged("save_profile").performClick()
        assertEquals("Renamed", session.state!!.getJSONObject("profile").getString("name"))
        assertEquals("clay", session.state!!.getJSONObject("profile").getString("theme"))
        assertEquals("system", session.state!!.getJSONObject("profile").getString("appearance"))
        controller.pause().stop().destroy()
    }

    @Test fun livePaletteAndModeChangesPreserveConversationHistoryDraftSelectionAndRecoveryAfterRotation() {
        val transport = FixtureTransport(); val session = inject(transport = transport)
        session.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test")); session.send("A preserved conversation")
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        activity.tabs().selectedItemId = R.id.conversations; activity.tagged("conversation_${session.conversation.id}").performClick()
        val editor = activity.tagged("conversation_message") as TextInputEditText
        editor.setText("An unsent thought"); editor.setSelection(2, 6)
        val id = session.conversation.id; val lines = session.lines; val bodies = transport.bodies.size
        session.updateAppearance("lavender", "system")
        val recolored = activity.tagged("conversation_message") as TextInputEditText
        assertNotSame(editor, recolored); assertEquals("An unsent thought", recolored.text.toString())
        assertEquals(2, recolored.selectionStart); assertEquals(6, recolored.selectionEnd)
        assertEquals(activity.color(R.color.ink), recolored.currentTextColor)
        assertEquals(lines, session.lines); assertEquals(id, session.conversation.id); assertEquals(bodies, transport.bodies.size)
        session.updateAppearance("lavender", "dark")
        assertEquals(app.themes.catalog.resolve("lavender").dark.getValue("primary"), activity.color(R.color.primary))
        shadowOf(Looper.getMainLooper()).idle() // AppCompat recreates for the changed platform appearance.
        assertEquals("An unsent thought", (controller.get().tagged("conversation_message") as TextInputEditText).text.toString())
        val saved = Bundle(); controller.saveInstanceState(saved).pause().stop().destroy()
        val rotated = Robolectric.buildActivity(MainActivity::class.java).create(saved).start().restoreInstanceState(saved).resume().visible()
        assertEquals("An unsent thought", (rotated.get().tagged("conversation_message") as TextInputEditText).text.toString())
        assertEquals(lines, session.lines); assertEquals(bodies, transport.bodies.size)
        rotated.pause().stop().destroy()
    }

    @Test fun appearanceCannotMutateDuringQueuedWorkChatReviewOrSync() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport(); val session = inject(store, core, transport)
        session.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test"))
        transport.replies.add(transport.reviewReply()); session.send("Review this kit")
        assertTrue(session.chatting); assertNotNull(session.review)
        val durable = store.durable; val calls = core.calls.size
        session.updateAppearance("clay", "dark")
        assertEquals(durable, store.durable); assertEquals(calls, core.calls.size); assertNotNull(session.review)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        controller.get().appearance(); assertFalse(controller.get().tagged("theme_clay").isEnabled)
        session.stop(); controller.pause().stop().destroy()
        val queue = ArrayDeque<Runnable>(); val queuedCore = FixtureCore(); val queuedStore = MemoryVault()
        val queued = HabibiSession(queuedStore, queuedCore::execute, Executor { queue.add(it) }, { it() })
        queued.start(); queue.removeFirst().run(); queued.create(profile()); queue.removeFirst().run()
        queued.configure(null); assertTrue(queued.busy)
        queued.updateAppearance("clay", "dark"); assertEquals(1, queue.size); queue.removeFirst().run()
        queued.syncNow(); assertTrue(queued.syncing)
        queued.updateAppearance("clay", "dark"); assertEquals(1, queue.size); queue.removeFirst().run()
        assertFalse(queued.state!!.getJSONObject("profile").has("theme"))
    }

    @Test fun publicRefreshUsesExactOriginNoAuthAndBoundedCacheWhileFailuresKeepLastGoodCatalog() {
        var calls = 0; var response = SyncResponse(200, bytes())
        val origin = SyncOrigin.fromDebugIntent(Intent().putExtra("sync_url", "http://localhost:4000")) ?: SyncOrigin.production
        val wire = SyncTransport { actual, method, path, headers, body ->
            calls++; assertEquals(origin, actual); assertEquals("GET", method); assertEquals("/assets/themes.json", path)
            assertEquals(mapOf("Accept" to "application/json"), headers); assertNull(body)
            response
        }
        val themes = immediateThemes(wire); themes.useOrigin(origin); assertEquals(0, calls)
        themes.refresh(origin); assertEquals(1, calls); assertTrue(themes.message.contains("refreshed"))
        val good = themes.catalog
        val cached = File(app.cacheDir, "public-themes-v1.json")
        assertTrue(cached.length() <= ThemeCatalog.MAX_BYTES + 1024)
        assertEquals(origin.issuer, JSONObject(cached.readText()).getString("issuer"))
        assertFalse(cached.readText().contains("fixture-content-key")); assertFalse(cached.readText().contains("appearance"))
        val offline = immediateThemes(); offline.useOrigin(origin)
        assertEquals(good, offline.catalog); assertTrue(offline.message.contains("Cached"))
        for (bad in listOf(SyncResponse(302, bytes()), SyncResponse(200, "{}".toByteArray()), SyncResponse(200, ByteArray(ThemeCatalog.MAX_BYTES + 1)))) {
            response = bad; themes.refresh(origin)
            assertEquals(good, themes.catalog); assertTrue(themes.message.contains("Could not refresh"))
        }
        val invalidColor = JSONObject(String(bytes())).apply { getJSONArray("themes").getJSONObject(0).getJSONObject("colors").put("primary", "javascript:bad") }
        response = SyncResponse(200, invalidColor.toString().toByteArray()); themes.refresh(origin)
        assertEquals(good, themes.catalog)
        assertEquals(5, calls)
    }

    @Test fun refreshAppliesChangedServerTokensWithoutProfileWritesAndUnknownSelectionRemainsStored() {
        val store = MemoryVault(); val core = FixtureCore(); val session = inject(store, core)
        session.updateAppearance("future-theme", "light")
        val durable = store.durable; val saves = store.saves
        val changed = JSONObject(String(bytes())).apply {
            getJSONArray("themes").getJSONObject(0).getJSONObject("colors").put("primary", "#123456")
        }
        app.injectedThemes = immediateThemes(SyncTransport { _, _, _, _, _ -> SyncResponse(200, changed.toString().toByteArray()) })
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get(); activity.appearance()
        assertTrue(activity.window.decorView.walk().filterIsInstance<TextView>().any { it.text.contains("without changing your preference") })
        activity.tagged("refresh_themes").performClick()
        assertEquals(android.graphics.Color.parseColor("#123456"), activity.color(R.color.primary))
        assertEquals("future-theme", session.state!!.getJSONObject("profile").getString("theme"))
        assertEquals(durable, store.durable); assertEquals(saves, store.saves)
        shadowOf(Looper.getMainLooper()).idle()
        controller.pause().stop().destroy()
    }
}
