package fyi.habibi.app

import android.Manifest
import android.content.Intent
import android.content.res.ColorStateList
import android.net.Uri
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.widget.doAfterTextChanged
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.checkbox.MaterialCheckBox
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.progressindicator.LinearProgressIndicator
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

class MainActivity : AppCompatActivity() {
    private val session get() = (application as HabibiApplication).session
    private val themes get() = (application as HabibiApplication).themes
    private var appliedPalette: Map<String, Int>? = null
    private lateinit var root: LinearLayout
    private lateinit var toolbar: MaterialToolbar
    private lateinit var navigation: BottomNavigationView
    private lateinit var screen: FrameLayout
    private lateinit var notice: TextView
    private lateinit var progress: LinearProgressIndicator
    private var route = "welcome"
    private var tab = R.id.home
    private var kitId: String? = null
    private var keyboard = false
    private var binding = false
    private var reviewDialog: AlertDialog? = null
    private var shownReview: Long? = null
    private var destroying = false
    private var previousState: JSONObject? = null
    private var conversationScreen: ConversationScreen? = null
    private var kitsScreen: KitsCatalogScreen? = null
    // Search can contain personal Kit names. Keep it in memory, not Android saved state.
    private var kitsQuery = ""
    private var kitsFilter = "all"
    private var githubDetailOpen = false
    private var githubStartPending = false
    private var githubSheet: GitHubDetailSheet? = null
    private var resumed = false
    private val kitsExpiryRefresh = Runnable { render() }
    private var voicePermissionResult: ((Boolean) -> Unit)? = null
    // Encrypted file payloads only, memory-only; a rotated/interrupted picker
    // never restores a recovery key or silently imports a different backup.
    private var pendingBackupExport: String? = null
    private var selectedBackupImport: JSONObject? = null
    private val backupDestination = registerForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        val backup = pendingBackupExport; pendingBackupExport = null
        if (uri != null && backup != null) session.writeRecoveryFile(backup) { contentResolver.openOutputStream(uri, "wt") }
    }
    private val backupSource = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) session.readRecoveryFile({ contentResolver.openInputStream(uri) }) { backup ->
            if (!isDestroyed && route == "restore") { selectedBackupImport = backup; render() }
        }
    }
    private val microphonePermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val callback = voicePermissionResult; voicePermissionResult = null; callback?.invoke(granted)
    }
    private val observer: () -> Unit = { render() }
    private val goals = linkedMapOf("health" to "Health", "learning" to "Learning", "planning" to "Planning", "creativity" to "Creativity", "wellbeing" to "Wellbeing")

    private fun appearanceNightMode() = when (session.state?.optJSONObject("profile")?.optString("appearance", "system")) {
        "light" -> AppCompatDelegate.MODE_NIGHT_NO
        "dark" -> AppCompatDelegate.MODE_NIGHT_YES
        else -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        delegate.localNightMode = appearanceNightMode()
        super.onCreate(savedInstanceState)
        route = savedInstanceState?.getString("route") ?: "welcome"
        tab = savedInstanceState?.getInt("tab") ?: R.id.home
        kitId = savedInstanceState?.getString("kit")
        githubDetailOpen = savedInstanceState?.getBoolean("github_detail") == true || route == "github"
        githubStartPending = savedInstanceState?.getBoolean("github_start_pending") == true
        if (route == "github") route = "kits" // Migrate the old full-page route.
        previousState = session.state
        WindowCompat.setDecorFitsSystemWindows(window, false)
        root = column(0)
        toolbar = MaterialToolbar(this).apply {
            setNavigationOnClickListener { back() }
            navigationContentDescription = "Back"
        }
        root.addView(toolbar)
        progress = LinearProgressIndicator(this).apply { isIndeterminate = true }
        root.addView(progress, LinearLayout.LayoutParams(-1, dp(4)))
        notice = label("", 14f).apply {
            setPadding(dp(24), dp(8), dp(24), dp(8))
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        root.addView(notice)
        screen = FrameLayout(this)
        root.addView(screen, LinearLayout.LayoutParams(-1, 0, 1f))
        navigation = BottomNavigationView(this).apply {
            inflateMenu(R.menu.navigation)
            labelVisibilityMode = com.google.android.material.navigation.NavigationBarView.LABEL_VISIBILITY_LABELED
            setOnItemSelectedListener { item ->
                if (!binding) { tab = item.itemId; go(when (tab) { R.id.profile -> "profile"; R.id.conversations -> "conversations"; else -> "home" }) }
                true
            }
        }
        root.addView(navigation)
        setContentView(root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
            keyboard = insets.isVisible(WindowInsetsCompat.Type.ime())
            view.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
            updateNavigationVisibility()
            WindowInsetsCompat.CONSUMED
        }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { if (!back()) { isEnabled = false; onBackPressedDispatcher.onBackPressed(); isEnabled = true } }
        })
        session.observe(observer); themes.observe(observer)
        val endpoint = InferenceEndpoint.fromDebugIntent(intent)
        // A new Activity does not disconnect an existing application-owned run.
        if (endpoint != null) session.configure(endpoint)
        session.start()
        consumeSyncIntent(intent)
        if (route == "sync") session.inspectSync()
        if (route == "kits") session.inspectBundledKits()
        render()
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent)
        InferenceEndpoint.fromDebugIntent(intent)?.let(session::configure)
        consumeSyncIntent(intent)
    }
    private fun consumeSyncIntent(intent: Intent) {
        SyncOrigin.fromDebugIntent(intent)?.let(session::configureSync)
        if (intent.action == Intent.ACTION_VIEW) {
            val callback = intent.dataString
            // Never retain code/state in the task intent or instance state.
            intent.data = null; intent.replaceExtras(null as Bundle?)
            if (callback != null) {
                route = "sync"; tab = R.id.profile
                session.syncCallback(callback)
            }
        }
    }
    override fun onResume() {
        super.onResume(); resumed = true; conversationScreen?.resume()
        session.setDraftSyncActive(true)
        if (route == "kits") render() // Re-evaluate expiry, without replacing search or dismissing the sheet.
    }
    override fun onPause() {
        resumed = false; screen.removeCallbacks(kitsExpiryRefresh)
        session.setDraftSyncActive(false)
        conversationScreen?.pause(); session.flushConversations(); super.onPause()
    }
    override fun onDestroy() {
        destroying = true; conversationScreen?.close(); voicePermissionResult = null
        screen.removeCallbacks(kitsExpiryRefresh)
        pendingBackupExport = null; selectedBackupImport = null
        githubSheet?.dispose(); githubSheet = null; kitsScreen = null
        reviewDialog?.dismiss(); session.unobserve(observer); themes.unobserve(observer)
        super.onDestroy()
    }
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("route", route); outState.putInt("tab", tab); outState.putString("kit", kitId)
        outState.putBoolean("github_detail", githubDetailOpen) // No code, account or credentials.
        outState.putBoolean("github_start_pending", githubSheet?.startingAuthorization ?: githubStartPending)
        super.onSaveInstanceState(outState)
    }
    private fun go(next: String) {
        if (session.syncing) return
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(screen.windowToken, 0)
        if (route == "conversation" && next != route) session.flushConversations()
        if (route == "restore" && next != route) selectedBackupImport = null
        if (next != "kits") githubSheet?.dismiss()
        route = next; render()
        if (next == "sync") session.inspectSync()
        if (next == "kits") session.inspectBundledKits()
    }
    private fun back(): Boolean {
        if (githubDetailOpen) { githubSheet?.dismiss(); return true }
        if (session.syncing) return true
        val parent = when (route) {
            "conversation" -> "conversations"
            "name", "restore" -> if (session.state != null) "recovery" else "welcome"
            "goals" -> "name"
            "privacy" -> "goals"
            "kits", "personalization", "appearance", "recovery", "sync" -> "profile"
            "kit" -> "kits"
            "entry" -> "kit"
            "profile", "conversations" -> { tab = R.id.home; "home" }
            else -> return false
        }
        go(parent); return true
    }
    private fun page(title: String, subtitle: String? = null, body: LinearLayout.() -> Unit): View = scroll(column().apply {
        addView(heading(title))
        subtitle?.let { addView(label(it, 16f, true)) }
        body()
    })
    private fun action(value: String, id: String, primary: Boolean = false, block: () -> Unit) = button(value, id, primary, block).apply {
        isEnabled = !session.busy && session.loaded
    }
    private fun updateNavigationVisibility() {
        navigation.visibility = if (session.state != null && !keyboard && route !in setOf("conversation", "kits")) View.VISIBLE else View.GONE
    }
    private fun render() {
        if (isDestroyed || destroying) return
        screen.removeCallbacks(kitsExpiryRefresh)
        themes.useOrigin(session.syncOrigin)
        val profile = session.state?.optJSONObject("profile")
        val nightMode = appearanceNightMode()
        if (delegate.localNightMode != nightMode) delegate.localNightMode = nightMode
        val palette = themes.palette(this, profile)
        if (appliedPalette != palette) {
            // Rebuild only for a changed palette, keeping the app-owned conversation,
            // encrypted draft, selection and history. No provider request is started.
            conversationScreen?.close(); conversationScreen = null
            kitsScreen = null
            githubStartPending = githubSheet?.startingAuthorization ?: githubStartPending
            githubSheet?.dispose(); githubSheet = null
            appliedPalette = palette
        }
        if (session.state != null && (route in setOf("welcome", "name", "goals", "privacy") || (route == "restore" && previousState !== session.state))) { route = "home"; tab = R.id.home }
        if (session.state == null && session.loaded && route !in setOf("welcome", "name", "goals", "privacy", "restore")) route = "welcome"
        if (route != "kits" && githubDetailOpen) {
            githubDetailOpen = false; githubSheet?.dismiss(); githubSheet = null
        }
        previousState = session.state
        if (route != "conversation" || conversationScreen?.represents(session.conversation) != true) {
            conversationScreen?.close(); conversationScreen = null
        }
        val focus = currentFocus?.tag as? String
        val oldScroll = (screen.getChildAt(0) as? ScrollView)?.scrollY ?: 0
        progress.visibility = if (session.busy || !session.loaded) View.VISIBLE else View.GONE
        notice.text = session.error ?: if (session.kitAuthorizing && !githubDetailOpen) "GitHub authorization is active. Return to Profile → Kits → GitHub to finish or cancel." else null
        notice.visibility = if (notice.text.isNullOrEmpty()) View.GONE else View.VISIBLE
        toolbar.visibility = if (route == "welcome") View.GONE else View.VISIBLE
        toolbar.title = when (route) {
            "name", "goals", "privacy" -> "Make it yours"
            "kit", "entry" -> "Your kit"
            "conversation" -> session.conversation.title
            else -> route.replaceFirstChar { it.uppercase() }
        }
        toolbar.navigationIcon = if (route in setOf("home", "conversations", "profile")) null else androidx.core.content.ContextCompat.getDrawable(this, R.drawable.ic_back)
        applyChrome()
        binding = true; navigation.selectedItemId = tab; binding = false
        updateNavigationVisibility()
        if (route in setOf("restore", "recovery") || githubDetailOpen) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (route == "kits") {
            val catalog = kitsScreen ?: KitsCatalogScreen(this, session, kitsQuery, kitsFilter,
                { query, filter -> kitsQuery = query; kitsFilter = filter }, ::openGitHubDetail,
                { id -> kitId = id; go("kit") }, { tab = R.id.conversations; go("conversations") }).also { kitsScreen = it }
            if (screen.getChildAt(0) !== catalog.view) { screen.removeAllViews(); screen.addView(catalog.view) }
            catalog.render(); renderGitHubDetail(); scheduleKitsExpiry(); showReview(); return
        }
        if (route == "conversation") {
            val detail = conversationScreen ?: ConversationScreen(this, session, { done ->
                if (voicePermissionResult != null) done(false)
                else { voicePermissionResult = done; microphonePermission.launch(Manifest.permission.RECORD_AUDIO) }
            }, ::sendMessage, ::conversationDraftActions).also {
                conversationScreen = it; screen.removeAllViews(); screen.addView(it.view)
            }
            detail.render(); showReview(); return
        }
        val content = when (route) {
            "welcome" -> if (session.loadFailed) page("Your vault needs attention", "Habibi could not open the saved vault. Nothing has been reset or deleted.") {
                addView(action("Retry saved vault", "retry_vault", true) { session.reload() })
                addView(action("Restore a backup", "restore_backup") { go("restore") })
            } else welcome({ go("name") }, { go("restore") }, session.loaded && !session.busy)
            "name" -> namePage()
            "goals" -> goalsPage()
            "privacy" -> privacyPage()
            "restore" -> restorePage()
            "profile" -> profilePage()
            "sync" -> syncPage()
            "personalization" -> personalizationPage()
            "appearance" -> appearancePage()
            "recovery" -> recoveryPage()
            "conversations" -> conversationPage()
            "kit" -> kitPage()
            "entry" -> entryPage()
            else -> homePage()
        }
        screen.removeAllViews(); screen.addView(content)
        if (oldScroll > 0) content.post { (content as? ScrollView)?.scrollTo(0, oldScroll) }
        if (focus != null) screen.findViewWithTag<View>(focus)?.requestFocus()
        showReview()
    }
    private fun applyChrome() {
        root.setBackgroundColor(color(R.color.paper))
        toolbar.setBackgroundColor(color(R.color.paper))
        toolbar.setTitleTextColor(color(R.color.ink)); toolbar.setSubtitleTextColor(color(R.color.secondary))
        toolbar.navigationIcon?.mutate()?.setTint(color(R.color.ink))
        navigation.setBackgroundColor(color(R.color.surface))
        navigation.itemIconTintList = selectionColors(); navigation.itemTextColor = selectionColors()
        navigation.itemActiveIndicatorColor = ColorStateList.valueOf(color(R.color.accent))
        navigation.itemRippleColor = ColorStateList.valueOf(color(R.color.accent))
        progress.setIndicatorColor(color(R.color.primary)); progress.trackColor = color(R.color.accent)
        notice.setTextColor(color(R.color.ink))
        val light = ColorUtils.calculateLuminance(color(R.color.paper)) > .5
        WindowCompat.getInsetsController(window, root).apply {
            isAppearanceLightStatusBars = light; isAppearanceLightNavigationBars = light
        }
    }
    private fun namePage() = page("What should I call you?", "A name that feels like you. It stays in your private vault.") {
        addView(label("1 of 3 · A personal welcome", 13f, true))
        val (box, input) = input("Your name", "onboarding_name", session.onboardingName)
        input.doAfterTextChanged { session.onboardingName = it.toString() }; addView(box)
        addView(action("Continue", "name_continue", true) {
            if (input.text.toString().trim().isEmpty()) box.error = "Please enter your name."
            else { session.onboardingName = input.text.toString().trim(); go("goals") }
        })
    }
    private fun goalsPage() = page("A little more you.", "Choose one to five things you would like space for. You can change these later.") {
        addView(label("2 of 3 · Your intentions", 13f, true))
        goals.forEach { (id, title) ->
            addView(MaterialCheckBox(this@MainActivity).apply {
                text = title; tag = "goal_$id"; contentDescription = title; minimumHeight = dp(48)
                applyThemeColors()
                isChecked = id in session.onboardingGoals
                setOnCheckedChangeListener { _, checked -> if (checked) session.onboardingGoals.add(id) else session.onboardingGoals.remove(id) }
            })
        }
        addView(heading("How should Habibi sound?", 20f))
        addView(stylePicker(session.onboardingStyle) { session.onboardingStyle = it })
        val validation = label("", 14f)
        addView(validation)
        addView(action("Continue", "goals_continue", true) {
            if (session.onboardingGoals.isEmpty()) validation.text = "Choose at least one intention."
            else go("privacy")
        })
    }
    private fun stylePicker(style: String, selected: (String) -> Unit) = RadioGroup(this).apply {
        listOf("warm" to "Warm · gentle encouragement", "direct" to "Direct · clear and practical").forEach { (id, title) ->
            addView(RadioButton(this@MainActivity).apply {
                this.id = View.generateViewId(); text = title; tag = "style_$id"; contentDescription = title
                applyThemeColors()
                minimumHeight = dp(48); isChecked = id == style
                setOnCheckedChangeListener { _, checked -> if (checked) selected(id) }
            })
        }
    }
    private fun privacyPage() = page("Yours. Really yours.", "3 of 3 · A private beginning") {
        addView(card().apply {
            addView(heading("A key made on your device", 22f))
            addView(label("Habibi generates a random 256-bit symmetric content key locally. It encrypts your profile, kits, entries and conversations. A separate sync token is not your private key."))
            addView(label("Android Keystore protects your local vault. No account is needed for local use. Optional encrypted sync uses a separate browser sign-in and never sends your encryption key."))
            addView(label("If you choose host inference, your messages go to the configured harness and model provider. Connecting GitHub also lets the agent send read-only profile and public repository results to that provider. Credentials, vault keys and saved local Kit entries never go with them. You approve every kit change."))
            addView(label("Keep a recovery backup and its recovery key separately. Losing this device without both means losing your vault.", 15f, true))
        })
        addView(action("Create my private vault", "create_vault", true) {
            session.create(JSONObject().put("name", session.onboardingName).put("goals", JSONArray(session.onboardingGoals.toList())).put("style", session.onboardingStyle))
        })
    }
    private fun homePage(): View {
        val profile = session.state?.optJSONObject("profile") ?: JSONObject()
        return page("Hello, ${profile.optString("name", "you")}.", "A quieter place to notice what matters.") {
            addView(heartling("home_heartling"))
            addView(card().apply {
                addView(heading("One small thing, today.", 22f))
                addView(label("Build a rhythm that fits your life. Your kits turn everyday notes into useful little insights.", 16f, true))
                addView(action("Explore your kits", "home_kits", true) { tab = R.id.profile; go("kits") })
            })
            addView(card().apply {
                addView(heading("Room to think", 22f))
                addView(label("Design a tracker with Habibi, evaluate it with synthetic examples, and choose whether to keep it.", 16f, true))
                addView(action("Start a conversation", "home_conversation") { tab = R.id.conversations; go("conversations") })
            })
            addView(label("Private on this device · ${kits().length()} kits", 13f, true))
        }
    }
    private fun profilePage(): View {
        val profile = session.state?.getJSONObject("profile") ?: JSONObject()
        return page(profile.optString("name", "Your profile"), "Your Habibi, on your terms.") {
            addView(action("Kits", "profile_kits", true) { go("kits") })
            addView(action("Personalization", "profile_personalization") { go("personalization") })
            addView(action("Appearance", "profile_appearance") { go("appearance") })
            addView(action("Recovery", "profile_recovery") { go("recovery") })
            addView(action("Encrypted sync", "profile_sync") { go("sync") })
            addView(card().apply {
                addView(heading("Privacy", 22f))
                addView(label("Your profile, entries, conversations and drafts are encrypted locally. Optional manual sync uploads only encrypted snapshots. No analytics, automatic cloud backup or background delivery is used."))
                addView(label("Conversations use the host's configured harness, such as Amp or Claude Code, and its model provider. Messages, kit definitions/synthetic results and authorized GitHub profile/public repository tool results are shared, never credentials, vault keys or saved local Kit entries. Host/provider retention, terms and charges apply. Do not type information you do not want sent."))
                addView(label("There is no destructive sign-out. Closing Habibi keeps your encrypted vault here.", 14f, true))
            })
        }
    }
    private fun syncPage() = page("Encrypted sync", "Manual snapshots, encrypted on this device. No background delivery is promised.") {
        addView(label(session.syncOrigin.issuer, 14f, true))
        addView(label(session.syncMessage).apply { tag = "sync_status"; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE })
        addView(label("Account sign-in is separate from your vault key. On another device, import your existing encrypted recovery bundle and its separate recovery key first. The server cannot recover either."))
        addView(label("Sync now flushes saved conversations first. Finish replies, Kit reviews and unsaved forms before syncing. Each changed snapshot consumes immutable storage (100 MiB prototype quota); syncing is manual, not periodic.", 14f, true))
        if (session.authorizing) {
            addView(button("Cancel authorization", "sync_cancel") { session.cancelSyncAuthorization() })
        } else if (!session.syncConnected) {
            addView(action("Sign in with system browser", "sync_sign_in", true) {
                session.beginSyncAuthorization { url ->
                    if (!isDestroyed && !destroying) try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
                    } catch (_: Exception) { session.cancelSyncAuthorization() }
                    else session.cancelSyncAuthorization()
                }
            })
        }
        addView(action("Sync now", "sync_now", true) { session.syncNow() }.apply { isEnabled = isEnabled && session.syncConnected && !session.chatting && session.review == null })
        if (session.syncConflict && !session.syncPending) {
            val heads = session.syncHeads.toList()
            val decision = session.syncDecision
            addView(heading("Choose a version", 22f))
            addView(label("No last-writer-wins. These opaque IDs are encrypted versions, not summaries. Other profile, Kits, entries and conversations may be replaced on this and other devices. Export backups before choosing."))
            heads.forEach { addView(label(it, 13f, true)) }
            fun confirm(choice: String, selected: String?) {
                MaterialAlertDialogBuilder(this@MainActivity).setTitle(if (choice == "local") "Keep this device?" else "Use selected other version?")
                    .setMessage("${if (selected == null) "Keep this device's saved data." else "Use encrypted version $selected."}\n\nThis resolves ALL displayed branches:\n${heads.joinToString("\n")}\n\nOther data may be replaced, including profile, Kits, entries and conversations. Export recovery backups first. New branches require another confirmation.")
                    .setNegativeButton("Cancel", null).setPositiveButton("Confirm choice") { _, _ -> session.resolveSync(choice, selected, heads, decision) }.show()
            }
            addView(action("Keep this device", "sync_keep_local") { confirm("local", null) })
            heads.forEach { id -> addView(action("Use other version $id", "sync_use_$id") { confirm("remote", id) }) }
        }
        if (session.syncConnected || session.syncRemovalFailed) addView(action("Disconnect encrypted sync", "sync_disconnect") {
            MaterialAlertDialogBuilder(this@MainActivity).setTitle("Disconnect encrypted sync?")
                .setMessage("Revoke this account grant if reachable and remove local OAuth credentials. Keep the vault, encryption keys, encrypted data and pending sync progress. This does not delete server snapshots.")
                .setNegativeButton("Cancel", null).setPositiveButton("Disconnect") { _, _ -> session.disconnectSync() }.show()
        })
        addView(action("Recovery and backups", "sync_recovery") { go("recovery") })
    }
    private fun personalizationPage(): View {
        val profile = session.state?.getJSONObject("profile") ?: JSONObject()
        val nameKey = "profile_name"
        val chosen = (0 until profile.optJSONArray("goals").let { it?.length() ?: 0 }).map { profile.getJSONArray("goals").getString(it) }.toMutableSet()
        session.formDrafts["profile_goals"]?.let { saved -> chosen.clear(); chosen.addAll(saved.split(',').filter { it.isNotBlank() }) }
        var style = session.formDrafts["profile_style"] ?: profile.optString("style", "warm")
        return page("Personalization", "These details stay in your encrypted vault, not in cloud conversations.") {
            val (box, name) = input("Your name", nameKey, session.formDrafts[nameKey] ?: profile.optString("name"))
            name.doAfterTextChanged { session.formDrafts[nameKey] = it.toString() }; addView(box)
            goals.forEach { (id, title) ->
                addView(MaterialCheckBox(this@MainActivity).apply {
                    text = title; tag = "edit_goal_$id"; minimumHeight = dp(48); isChecked = id in chosen
                    applyThemeColors()
                    setOnCheckedChangeListener { _, check ->
                        if (check) chosen.add(id) else chosen.remove(id)
                        session.formDrafts["profile_goals"] = chosen.joinToString(",")
                    }
                })
            }
            addView(stylePicker(style) { style = it; session.formDrafts["profile_style"] = it })
            addView(action("Save personalization", "save_profile", true) {
                if (name.text.toString().trim().isEmpty() || chosen.isEmpty()) box.error = "Enter a name and choose at least one intention."
                else session.updateProfile(JSONObject(profile.toString()).put("name", name.text.toString().trim()).put("goals", JSONArray(chosen.toList())).put("style", style))
            })
        }
    }
    private fun appearancePage(): View {
        val profile = session.state?.optJSONObject("profile") ?: JSONObject()
        val catalog = themes.catalog
        val savedTheme = profile.optString("theme", catalog.defaultTheme)
        val appearance = profile.optString("appearance", "system")
        val enabled = session.loaded && !session.busy && !session.chatting && session.review == null && !session.syncing
        return page("Appearance", "Theme and mode save in your encrypted profile and travel with recovery and sync. Your app icon stays on this device.") {
            addView(heading("App icon", 20f))
            val selectedIcon = AppIcon.current(this@MainActivity)
            addView(RadioGroup(this@MainActivity).apply {
                AppIcon.entries.forEach { icon ->
                    addView(RadioButton(this@MainActivity).apply {
                        id = View.generateViewId(); tag = "app_icon_${icon.id}"; text = icon.title
                        contentDescription = "${icon.title} app icon"; minimumHeight = dp(76)
                        applyThemeColors(); isChecked = icon == selectedIcon
                        val preview = getDrawable(icon.resource)!!.apply { setBounds(0, 0, dp(56), dp(56)) }
                        setCompoundDrawablesRelative(preview, null, null, null); compoundDrawablePadding = dp(16)
                        setOnCheckedChangeListener { _, checked ->
                            if (checked) try { icon.select(this@MainActivity) }
                            catch (_: Exception) {
                                render()
                                MaterialAlertDialogBuilder(this@MainActivity).setTitle("Could not change app icon")
                                    .setMessage("Please try again. Your launcher may take a moment to update.").setPositiveButton("OK", null).show()
                            }
                        }
                    })
                }
            })
            addView(label("Choose the Heartling in your launcher. Android may take a moment to update it. Themed icons use your wallpaper colors.", 13f, true))
            if (catalog.themes.none { it.id == savedTheme }) addView(label("Your saved theme '$savedTheme' is unavailable. Showing ${catalog.resolve(null).name} without changing your preference.", 14f, true))
            if (!enabled) addView(label("Finish the conversation, review or sync before changing appearance.", 14f, true))
            addView(heading("Theme", 20f))
            addView(RadioGroup(this@MainActivity).apply {
                catalog.themes.forEach { theme ->
                    addView(RadioButton(this@MainActivity).apply {
                        id = View.generateViewId(); tag = "theme_${theme.id}"; text = theme.name
                        contentDescription = "${theme.name} theme"; minimumHeight = dp(48)
                        applyThemeColors(); isChecked = theme.id == savedTheme; isEnabled = enabled
                        setOnCheckedChangeListener { _, checked -> if (checked) session.updateAppearance(theme.id, appearance) }
                    })
                }
            })
            addView(heading("Mode", 20f))
            addView(RadioGroup(this@MainActivity).apply {
                listOf("system" to "Use device setting", "light" to "Light", "dark" to "Dark").forEach { (value, title) ->
                    addView(RadioButton(this@MainActivity).apply {
                        id = View.generateViewId(); tag = "appearance_$value"; text = title; contentDescription = title
                        minimumHeight = dp(48); applyThemeColors(); isChecked = value == appearance; isEnabled = enabled
                        setOnCheckedChangeListener { _, checked -> if (checked) session.updateAppearance(savedTheme, value) }
                    })
                }
            })
            addView(label(themes.message, 14f, true).apply { tag = "theme_catalog_status"; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE })
            addView(button("Refresh public themes", "refresh_themes") { themes.refresh(session.syncOrigin) }.apply { isEnabled = !themes.refreshing })
            addView(label("Refresh downloads only public theme tokens from ${session.syncOrigin.issuer}. No account credentials, messages or vault data are sent. Bundled or cached themes work offline.", 13f, true))
        }
    }
    private fun recoveryPage() = page("Keep a way back.", "A backup and its recovery key together can unlock your entire vault. Store them separately and privately.") {
        addView(label("Without both, a lost device means a lost vault. Android automatic backup is disabled. Sharing either item is an explicit action you control."))
        addView(action("Export recovery backup", "export_recovery", true) {
            session.exportRecovery { result -> if (!isDestroyed) showRecovery(result) }
        })
        addView(action("Import recovery backup", "import_recovery") { go("restore") })
    }
    private fun showRecovery(result: JSONObject) {
        // One item per dialog/share intent; never both in a single payload.
        val backup = result.get("backup").toString()
        val key = result.getString("recoveryKey")
        fun keyDialog() {
            val body = column().apply {
                addView(label("Save this recovery key somewhere different from the backup. Anyone with both can read your vault."))
                addView(label(key).apply { contentDescription = "Recovery key"; setTextIsSelectable(true) })
                addView(button("Share recovery key separately", "share_recovery_key") { share("Habibi recovery key", key) })
            }
            MaterialAlertDialogBuilder(this).setTitle("2 · Your recovery key").setView(scroll(body)).setPositiveButton("Done", null).show()
                .window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        val body = column().apply {
            addView(label("First save the encrypted backup. The next screen shows the recovery key separately. Do not store them together."))
            addView(button("Save encrypted backup file", "share_backup", true) {
                pendingBackupExport = backup
                backupDestination.launch("habibi-encrypted-backup.json")
            })
        }
        MaterialAlertDialogBuilder(this).setTitle("1 · Encrypted backup").setView(body)
            .setNegativeButton("Close", null).setPositiveButton("Show recovery key") { _, _ -> keyDialog() }.show()
            .window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    private fun share(title: String, value: String) {
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, title).putExtra(Intent.EXTRA_TEXT, value), title))
    }
    private fun restorePage() = page("Bring your Habibi back.", "Paste your encrypted backup and recovery key. They are processed only on this device.") {
        addView(action("Choose encrypted backup file", "choose_recovery_file") { backupSource.launch(arrayOf("application/json", "application/octet-stream", "text/plain")) })
        if (selectedBackupImport != null) {
            addView(label("Encrypted backup file selected. Enter its separate recovery key below. Nothing has been restored."))
            addView(action("Use pasted backup instead", "clear_recovery_file") { selectedBackupImport = null; render() })
        }
        val (backupBox, backup) = input("Encrypted backup JSON", "recovery_backup", multiline = true)
        backup.isEnabled = selectedBackupImport == null
        val (keyBox, key) = input("Recovery key", "recovery_key")
        key.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        addView(backupBox); addView(keyBox)
        addView(label("Keep your original backup until recovery has completed successfully. Nothing is sent to a server.", 14f, true))
        addView(action("Restore my vault", "recover_vault", true) {
            try {
                require(backup.text.toString().length <= 8 * 1024 * 1024) { "Encrypted backup is too large." }
                val value = selectedBackupImport ?: JSONTokener(backup.text.toString()).nextValue()
                require(value is JSONObject) { "Paste a valid recovery backup JSON object." }
                require(key.text.toString().isNotBlank()) { "Enter the recovery key." }
                val recover = { session.recover(value, key.text.toString().trim()) { if (!isDestroyed) { tab = R.id.home; go("home") } }; Unit }
                if (session.state != null || session.loadFailed) MaterialAlertDialogBuilder(this@MainActivity)
                    .setTitle("Replace this device's vault?")
                    .setMessage("Export your current vault first if you can. Only a successfully recovered and saved backup will replace it. This cannot merge two vaults.")
                    .setNegativeButton("Cancel", null).setPositiveButton("Restore backup") { _, _ -> recover() }.show()
                else recover()
            } catch (cause: Exception) { backupBox.error = cause.message ?: "Check the backup and key." }
        })
    }
    private fun conversationPage() = page("Conversations", "A little room for each idea. Conversations, cards and drafts are saved locally in your encrypted vault. Unsent edits save after a short pause.") {
        addView(label(if (session.connected) "Development inference bridge connected" else "Not connected · Connect an inference bridge to chat. Local vault and installed Kits remain available.", 14f, true))
        addView(button("New conversation", "new_conversation", true) {
            if (session.newConversation()) go("conversation")
        }.apply { isEnabled = session.canSwitchConversation })
        if (!session.canSwitchConversation) addView(label("Finish or stop the current reply and resolve any Kit review before switching conversations.", 14f, true))
        session.conversations.asReversed().forEach { chat ->
            addView(card().apply {
                addView(heading(chat.title, 20f))
                addView(label(if (chat.draft.isNotBlank()) "Draft · ${chat.draft.take(120)}" else chat.lines.lastOrNull()?.text?.take(140) ?: "What would you like to notice?", 14f, true))
                addView(button(if (session.chatting && chat.id == session.conversation.id) "Return to active conversation" else "Open conversation", "conversation_${chat.id}") {
                    if (session.selectConversation(chat.id)) go("conversation")
                }.apply { isEnabled = session.canSwitchConversation || chat.id == session.conversation.id })
            })
        }
    }
    private fun conversationDraftActions(definition: JSONObject) = card().apply {
        addView(heading("Draft · ${definition.optString("name")}", 20f))
        addView(label(definition.optString("description")))
        addView(action("Inspect draft", "inspect_draft") { showDefinition(definition) })
        addView(action("Evaluate synthetic examples", "evaluate_draft") { evaluateDraft(definition) }.apply { isEnabled = session.canSwitchConversation })
        addView(action("Review and save draft", "save_draft") { session.tool("save_kit", JSONObject().put("definition", definition)) }.apply { isEnabled = session.canSwitchConversation })
        if (kits().length() > 0) addView(action("Update an existing kit…", "update_from_draft") { chooseUpdate(definition) }.apply { isEnabled = session.canSwitchConversation })
    }
    private fun sendMessage(message: String) {
        if (message.isBlank() || session.busy || session.chatting || session.review != null) return
        if (session.inferenceConsent) session.send(message)
        else {
            val chatId = session.conversation.id
            MaterialAlertDialogBuilder(this)
                .setTitle("Use host inference?")
                .setMessage("The development proxy uses the host's configured harness, such as Amp or Claude Code, and its model provider. Messages, kit definitions and synthetic tests are sent. If GitHub is connected, the agent can also send read-only profile and public repository tool results to that provider. Credentials, saved local Kit entries and vault keys stay private. Host/provider retention, terms and charges apply.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Allow for this session") { _, _ ->
                    if (route == "conversation" && session.conversation.id == chatId) {
                        session.inferenceConsent = true; session.send(message)
                    }
                }.show()
        }
    }
    private fun kits() = session.state?.optJSONArray("kits") ?: JSONArray()
    private fun kit(): JSONObject? = (0 until kits().length()).map { kits().getJSONObject(it) }.firstOrNull { it.optString("id") == kitId }
    private fun openGitHubDetail() {
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(screen.windowToken, 0)
        githubDetailOpen = true; render()
    }
    private fun renderGitHubDetail() {
        if (!githubDetailOpen) return
        val detail = githubSheet ?: GitHubDetailSheet(this, session, githubStartPending, {
            githubSheet = null; githubDetailOpen = false; githubStartPending = false; render()
        }, ::go).also { githubSheet = it; githubStartPending = false; it.show() }
        detail.render()
    }
    private fun scheduleKitsExpiry() {
        if (!resumed || session.githubAccount?.expired != false) return
        val connections = session.state?.optJSONArray("connections") ?: return
        val connection = (0 until connections.length()).map { connections.getJSONObject(it) }.firstOrNull { it.optString("kitId") == "github" } ?: return
        val expires = connection.optLong("expiresAt", 0)
        if (expires <= 0) return // Non-expiring tokens need no UI timer and no network check.
        val delay = expires.coerceAtMost(Long.MAX_VALUE / 1000) * 1000 - System.currentTimeMillis()
        screen.postDelayed(kitsExpiryRefresh, maxOf(1L, delay))
    }
    private fun kitPage(): View {
        val item = kit() ?: return page("Kit unavailable", "This kit may have been removed. Your other kits are unchanged.") {
            addView(action("Back to Kits", "back_kits") { go("kits") })
        }
        val definition = item.getJSONObject("definition"); val entries = item.getJSONArray("entries")
        return page(definition.getString("name"), definition.optString("description")) {
            addView(action("Add an entry", "add_entry", true) { go("entry") })
            addView(action("Run local summary", "kit_summary") {
                session.summary(item.getString("id")) { value -> if (!isDestroyed && value != null) {
                    val metrics = value.optJSONArray("metrics") ?: JSONArray()
                    val text = (0 until metrics.length()).joinToString("\n\n") { index -> metrics.getJSONObject(index).let { "${it.optString("label")}: ${it.optString("value")} ${it.optString("unit")}" } }
                    MaterialAlertDialogBuilder(this@MainActivity).setTitle("Local summary").setMessage(text.ifBlank { "No metrics yet. Add an entry to get started." }).setPositiveButton("Done", null).show()
                } }
            })
            addView(action("Inspect kit definition", "inspect_kit") { showDefinition(definition) })
            addView(action("Refine with Habibi", "refine_kit") { tab = R.id.conversations; go("conversations") })
            addView(heading("Entries", 22f))
            if (entries.length() == 0) addView(label("Nothing to measure yet. Add your first entry when you are ready.", 16f, true))
            for (index in entries.length() - 1 downTo 0) {
                val entry = entries.getJSONObject(index)
                addView(card().apply {
                    addView(label(entry.optString("createdAt"), 13f, true))
                    val values = entry.getJSONObject("values"); val fields = definition.getJSONArray("fields")
                    for (i in 0 until fields.length()) {
                        val field = fields.getJSONObject(i)
                        addView(label("${field.optString("label")}: ${values.opt(field.getString("key")) ?: ""} ${field.optString("unit")}"))
                    }
                })
            }
            addView(action("Remove kit…", "remove_kit") { session.tool("remove_kit", JSONObject().put("id", item.getString("id"))) })
        }
    }
    private fun entryPage(): View {
        val item = kit() ?: return kitPage()
        val fields = item.getJSONObject("definition").getJSONArray("fields")
        val edits = linkedMapOf<String, Pair<JSONObject, com.google.android.material.textfield.TextInputEditText>>()
        return page("A moment to check in.", "This entry stays in your private vault. It is not sent to the agent.") {
            for (index in 0 until fields.length()) {
                val field = fields.getJSONObject(index); val key = field.getString("key"); val draftKey = "entry_${kitId}_$key"
                val title = field.getString("label") + field.optString("unit").takeIf { it.isNotBlank() }?.let { " ($it)" }.orEmpty()
                val (box, edit) = input(title, draftKey, session.formDrafts[draftKey] ?: "")
                when (field.getString("type")) {
                    "number" -> edit.inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED
                    "date" -> { edit.inputType = InputType.TYPE_CLASS_DATETIME or InputType.TYPE_DATETIME_VARIATION_DATE; box.helperText = "YYYY-MM-DD" }
                }
                edit.doAfterTextChanged { session.formDrafts[draftKey] = it.toString() }; addView(box)
                edits[key] = field to edit
            }
            val validation = label("", 14f); addView(validation)
            addView(action("Save entry", "save_entry", true) {
                try {
                    val values = JSONObject()
                    edits.forEach { (key, pair) ->
                        val (field, edit) = pair; val text = edit.text.toString().trim()
                        if (field.getString("type") == "number") values.put(key, text.toDoubleOrNull()?.takeIf { it.isFinite() } ?: error("${field.getString("label")} needs a number."))
                        else values.put(key, text)
                    }
                    session.addEntry(item.getString("id"), values) {
                        edits.keys.forEach { session.formDrafts.remove("entry_${kitId}_$it") }
                        if (!isDestroyed) go("kit")
                    }
                } catch (cause: Exception) { validation.text = cause.message ?: "Check your entry." }
            })
        }
    }
    private fun showDefinition(definition: JSONObject) {
        MaterialAlertDialogBuilder(this).setTitle("Kit definition")
            .setView(scroll(column().apply { addView(label(definition.toString(2), 14f).apply { setTextIsSelectable(true) }) }))
            .setPositiveButton("Done", null).show()
    }
    private fun evaluateDraft(definition: JSONObject) {
        val body = column(); val (box, edit) = input("Synthetic entries JSON", "synthetic_entries", "[]", true)
        body.addView(label("Use invented values only, not saved entries. Evaluation runs the real kit sandbox on this device.")); body.addView(box)
        val dialog = MaterialAlertDialogBuilder(this).setTitle("Evaluate kit").setView(scroll(body)).setNegativeButton("Cancel", null).setPositiveButton("Evaluate", null).show()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            try {
                val entries = JSONArray(edit.text.toString())
                session.tool("evaluate_kit", JSONObject().put("definition", definition).put("entries_json", entries.toString()))
                dialog.dismiss()
            } catch (_: Exception) { box.error = "Enter a JSON array of invented entries." }
        }
    }
    private fun chooseUpdate(definition: JSONObject) {
        val items = (0 until kits().length()).map { kits().getJSONObject(it) }
        MaterialAlertDialogBuilder(this).setTitle("Which kit should this update?")
            .setItems(items.map { it.getJSONObject("definition").getString("name") }.toTypedArray()) { _, which ->
                session.tool("update_kit", JSONObject().put("id", items[which].getString("id")).put("definition", definition))
            }.setNegativeButton("Cancel", null).show()
    }
    private fun showReview() {
        val pending = session.review
        if (pending == null) { shownReview = null; reviewDialog?.dismiss(); reviewDialog = null; return }
        if (shownReview == pending.ticket) return
        reviewDialog?.dismiss(); shownReview = pending.ticket
        val value = JSONObject(pending.review); val operation = value.getString("operation")
        val name = value.getJSONObject("definition").optString("name", "kit")
        val title = when (operation) { "remove_kit" -> "Remove $name?"; "update_kit" -> "Update $name?"; else -> "Save $name?" }
        val body = column().apply {
            addView(label("Habibi is asking for your permission. Nothing changes until you approve. You can always decline."))
            addView(label("${value.optInt("entryCount")} existing entries affected."))
            if (operation == "remove_kit") addView(label("Removing this kit also removes its entries from this vault. Export a recovery backup first if you need to keep them."))
            if (operation == "update_kit") addView(label("Review field and source changes carefully. Existing entries may be affected by the new definition."))
            addView(heading("Proposed definition", 20f))
            addView(label(value.getJSONObject("definition").toString(2), 14f).apply { setTextIsSelectable(true) })
        }
        reviewDialog = MaterialAlertDialogBuilder(this).setTitle(title).setView(scroll(body))
            .setNegativeButton("Decline") { _, _ -> session.decide(pending.ticket, false) }
            .setPositiveButton(if (operation == "remove_kit") "Remove kit" else "Approve and save") { _, _ -> session.decide(pending.ticket, true) }
            .setOnCancelListener { if (!destroying) session.decide(pending.ticket, false) }.show()
    }
}
