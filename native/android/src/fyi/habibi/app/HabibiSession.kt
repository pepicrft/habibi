package fyi.habibi.app

import android.app.Application
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDate
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object HabibiCore {
    init { System.loadLibrary("habibi_core") }
    external fun execute(input: String): String
}

class HabibiApplication : Application() {
    // Test injection is application-scoped and cannot be selected through intents.
    internal var injectedSession: HabibiSession? = null
    internal var voiceRecognizerFactory: (() -> DeviceRecognizer)? = null
    internal var injectedThemes: NativeThemes? = null
    internal val themes get() = injectedThemes ?: realThemes
    private val realThemes by lazy { NativeThemes(this) }
    internal val session: HabibiSession get() = injectedSession ?: realSession
    private val realSession by lazy {
        val preferences = getSharedPreferences("habibi.draft-replica", Context.MODE_PRIVATE)
        val deviceId = preferences.getString("id", null) ?: UUID.randomUUID().toString().also {
            check(preferences.edit().putString("id", it).commit()) { "Could not save the draft replica identity." }
        }
        HabibiSession(SecureVaultStorage(this), { HabibiCore.execute(it) },
            oauth = NativeOAuth(SecureVaultStorage(this, "oauth-v1"), HttpSyncTransport()), draftDeviceId = deviceId,
            saveDraftDeviceId = { id ->
                check(preferences.edit().putString("id", id).commit()) { "Could not save the draft replica identity." }
            })
    }
}

internal interface VaultStorage {
    fun load(): JSONObject?
    /** Return only when the whole identity + document record is durable. */
    fun save(record: JSONObject)
}

internal class SecureVaultStorage(context: Context, private val recordName: String = "vault-v1",
    private val keyProvider: ((Boolean) -> SecretKey)? = null) : VaultStorage {
    private val preferences = context.getSharedPreferences(if (recordName == "vault-v1") "habibi.sealed-vault" else "habibi.sealed-$recordName", Context.MODE_PRIVATE)
    private val alias = "fyi.habibi.app.$recordName"

    private fun key(create: Boolean): SecretKey {
        keyProvider?.let { return it(create) }
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "The device encryption key is unavailable. Your saved vault has not been changed." }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            generateKey()
        }
    }

    @Synchronized override fun load(): JSONObject? {
        val stored = preferences.getString(recordName, null) ?: return null
        check(stored.length <= 12 * 1024 * 1024) { "Protected storage is too large. Your vault has not been changed." }
        val envelope = JSONObject(stored)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, Base64.decode(envelope.getString("iv"), Base64.NO_WRAP)))
        cipher.updateAAD(recordName.toByteArray(Charsets.UTF_8))
        return JSONObject(String(cipher.doFinal(Base64.decode(envelope.getString("data"), Base64.NO_WRAP)), Charsets.UTF_8))
    }

    @Synchronized override fun save(record: JSONObject) {
        val plaintext = record.toString().toByteArray(Charsets.UTF_8)
        check(plaintext.size <= 8 * 1024 * 1024) { "Protected storage is too large. Your previous data is unchanged." }
        val previous = preferences.getString(recordName, null)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        // A successful explicit recovery can replace a vault whose device key
        // was lost. Loading never creates a replacement key or resets data.
        cipher.init(Cipher.ENCRYPT_MODE, key(true))
        cipher.updateAAD(recordName.toByteArray(Charsets.UTF_8))
        val envelope = JSONObject().put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("data", Base64.encodeToString(cipher.doFinal(plaintext), Base64.NO_WRAP))
        if (!preferences.edit().putString(recordName, envelope.toString()).commit()) {
            // SharedPreferences updates memory before its disk write. Restore its
            // previous memory value too; a failed candidate must never be restored.
            val rollback = preferences.edit()
            if (previous == null) rollback.remove(recordName) else rollback.putString(recordName, previous)
            check(rollback.commit()) { "Storage failed. Close Habibi and retry; no updated state was published." }
            error("Could not save your vault. Your previous data is unchanged.")
        }
    }
}

internal data class ChatLine(val role: String, val text: String, val id: String = UUID.randomUUID().toString(),
    val component: String? = null, val createdAt: String = Instant.now().toString(), val detail: String? = null,
    val entryId: String? = null, val reaction: String? = null)
internal class Conversation(val id: String = UUID.randomUUID().toString(), val createdAt: String = Instant.now().toString()) {
    @Volatile var lines: List<ChatLine> = emptyList()
    @Volatile var draft = ""
    @Volatile var composerClock = JSONObject()
    @Volatile var draftRevision = 0L
    @Volatile var definition: JSONObject? = null
    @Volatile var toolResult: String? = null
    val history = JSONArray()
    var selectionStart = 0
    var selectionEnd = 0
    var scrollY = 0
    var following = true
    val title get() = lines.firstOrNull { it.role == "You" }?.text?.lineSequence()?.firstOrNull()?.take(72) ?: "New conversation"
}
internal data class KitReview(val ticket: Long, val recordFingerprint: String, val review: String, val callId: String?, val run: AtomicBoolean?)
private class CoreFailure(message: String) : Exception(message)

/** Application-owned session. Bridge/storage calls are serialized. Device OAuth
 * polls use a separate bounded worker and rejoin the serial durable install gate.
 * Only durable candidates become public state. No identity is ever handed to UI. */
internal class HabibiSession(
    private val storage: VaultStorage,
    private val bridge: (String) -> String,
    private val worker: Executor = Executors.newSingleThreadExecutor(),
    private val publish: ((() -> Unit) -> Unit) = { Handler(Looper.getMainLooper()).post(it) },
    private val transport: InferenceTransport = HttpInferenceTransport(),
    private val oauth: NativeOAuth? = null,
    private val syncTransport: SyncTransport = HttpSyncTransport(),
    private val githubTransport: GitHubTransport = HttpGitHubTransport(),
    private val github: GitHubDeviceFlow = GitHubDeviceFlow(githubTransport),
    private var draftDeviceId: String = UUID.randomUUID().toString(),
    private val saveDraftDeviceId: (String) -> Unit = {},
) {
    private var record: JSONObject? = null
    @Volatile var state: JSONObject? = null; private set
    @Volatile var loaded = false; private set
    @Volatile var loadFailed = false; private set
    @Volatile var busy = false; private set
    @Volatile var error: String? = null; private set
    @Volatile var review: KitReview? = null; private set
    @Volatile var syncOrigin = SyncOrigin.production; private set
    @Volatile var syncConnected = false; private set
    @Volatile var syncRemovalFailed = false; private set
    @Volatile var syncMessage = "Not connected · Manual encrypted sync is optional."; private set
    @Volatile var syncHeads: List<String> = emptyList(); private set
    @Volatile var syncConflict = false; private set
    @Volatile var syncPending = false; private set
    @Volatile var syncDecision = ""; private set
    @Volatile var draftSyncMessage = "Draft sync connects through Encrypted sync in Profile."; private set
    @Volatile private var draftSyncActive = false
    @Volatile private var draftSyncDeparture = false
    private val draftSyncQueued = AtomicBoolean(false)
    private val syncLock = AtomicBoolean(false)
    val syncing get() = syncLock.get()
    val authorizing get() = oauth?.authorizing() == true
    val kitAuthorizing get() = github.authorizing()
    val githubAuthorization get() = github.authorization
    @Volatile private var githubNotice: String? = null
    private val githubAttempts = AtomicInteger()
    val githubMessage get() = githubNotice ?: if (github.message == "Not connected" && githubAccount != null) "Connected · Check connection to verify GitHub access." else github.message
    @Volatile var bundledKits = JSONArray(); private set
    private val bundledGitHubClientId: String get() = (0 until bundledKits.length())
        .map { bundledKits.getJSONObject(it) }.firstOrNull { it.optString("id") == "github" }?.opt("clientId") as? String ?: ""
    val githubConfigured get() = bundledGitHubClientId.isNotBlank()
    val githubAccount: GitHubAccount? get() {
        val connections = state?.optJSONArray("connections") ?: return null
        val connection = (0 until connections.length()).map { connections.getJSONObject(it) }.firstOrNull { it.optString("kitId") == "github" } ?: return null
        return GitHubAccount(connection.getString("account"),
            connection.has("expiresAt") && connection.getLong("expiresAt") <= System.currentTimeMillis() / 1000)
    }
    private fun resetGitHubNotice() {
        githubNotice = when (githubAccount?.expired) {
            null -> "Not connected"
            true -> "Connection expired. Reconnect to continue."
            false -> "Connected · Check connection to verify GitHub access."
        }
    }
    val canManageConnections get() = loaded && state != null && !busy && !chatting && review == null && !syncing && !authorizing && !kitAuthorizing && !entrySubmission.get()
    @Volatile var conversations: List<Conversation> = listOf(Conversation()); private set
    @Volatile var conversation: Conversation = conversations.first(); private set
    var draft: JSONObject?
        get() = conversation.definition
        private set(value) {
            synchronized(archiveLock) { conversation.definition = value; archiveRevision++ }
            scheduleConversationSave()
        }
    var toolResult: String?
        get() = conversation.toolResult
        private set(value) { conversation.toolResult = value }
    var lines: List<ChatLine>
        get() = conversation.lines
        private set(value) {
            synchronized(archiveLock) { conversation.lines = value; archiveRevision++ }
            scheduleConversationSave()
        }
    @Volatile var chatting = false; private set
    @Volatile var connected = false; private set
    var inferenceConsent = false
    private val history get() = conversation.history
    private val pendingWork = AtomicInteger()
    private var endpoint: InferenceEndpoint? = null
    @Volatile private var run: AtomicBoolean? = null
    private var requests = 0
    private var reviewTicket = 0L
    private val listeners = linkedSetOf<() -> Unit>()
    private val archiveLock = Any()
    private var archiveRevision = 0L
    private var savedArchiveRevision = 0L
    private var failedArchiveRevision: Long? = null
    private var archiveError: String? = null
    private val flushQueued = AtomicBoolean(false)
    private val entrySubmission = AtomicBoolean(false)
    private val autosaveHandler by lazy { Handler(Looper.getMainLooper()) }
    private val autosave = Runnable { flushConversations() }
    private val draftSyncDebounce = Runnable { synchronizeDrafts() }
    private val draftSyncPoll = object : Runnable {
        override fun run() {
            if (!draftSyncActive) return
            synchronizeDrafts()
            autosaveHandler.postDelayed(this, 5000)
        }
    }
    // Onboarding/form UI is ephemeral. Conversation drafts use only the encrypted vault.
    var onboardingName = ""
    var onboardingGoals = linkedSetOf<String>()
    var onboardingStyle = "warm"
    var conversationDraft: String
        get() = conversation.draft
        set(value) {
            synchronized(archiveLock) {
                if (syncing) return // Editor is disabled while the remote candidate owns the install gate.
                if (conversation.draft == value) return
                conversation.draft = value; conversation.draftRevision++; archiveRevision++
            }
            scheduleConversationSave()
            requestDraftSync()
        }
    val formDrafts = mutableMapOf<String, String>()

    fun observe(listener: () -> Unit) { listeners.add(listener) }
    fun unobserve(listener: () -> Unit) { listeners.remove(listener) }
    private fun changed() = publish { listeners.toList().forEach { it() } }
    private fun failure(cause: Throwable) {
        // Never log exceptions, request payloads, recovery data or identity.
        error = when (cause) {
            is UnsatisfiedLinkError -> "The native core is unavailable in this build. Your saved vault is unchanged."
            else -> cause.message ?: "That did not work. Your saved vault is unchanged."
        }
    }
    private fun work(action: () -> Unit) {
        // Reserve work before enqueueing: a quick second tap cannot switch the
        // active history while a send/tool call is waiting for the worker.
        pendingWork.incrementAndGet(); busy = true
        worker.execute {
            busy = true; error = archiveError; changed()
            try { action() } catch (cause: Exception) { failure(cause) }
            catch (cause: UnsatisfiedLinkError) { failure(cause) }
            finally { busy = pendingWork.decrementAndGet() > 0; changed() }
        }
    }

    private fun call(operation: String, payload: JSONObject = JSONObject()): JSONObject {
        val request = JSONObject(payload.toString()).put("operation", operation).toString()
        check(request.toByteArray(Charsets.UTF_8).size <= 8 * 1024 * 1024) { "Native request is too large. Your saved vault is unchanged." }
        val envelope = JSONObject(bridge(request))
        envelope.optJSONObject("error")?.let { throw CoreFailure(it.optString("message", "Native operation failed")) }
        return envelope.getJSONObject("ok")
    }
    private fun authenticated(): JSONObject = JSONObject((record ?: error("Create or restore your Habibi first.")).toString())
    private fun install(candidate: JSONObject) {
        val identity = candidate.opt("identity") ?: authenticated().get("identity")
        val nextRecord = JSONObject().put("identity", identity).put("document", candidate.get("document"))
        val nextState = if (candidate.has("state")) candidate.getJSONObject("state") else state
            ?: error("A metadata-only candidate needs an existing unlocked vault.")
        storage.save(nextRecord) // The publication gate: never move below state assignment.
        record = nextRecord
        if (candidate.has("state")) state = JSONObject(nextState.toString())
        loadFailed = false
    }

    private fun scheduleConversationSave() {
        autosaveHandler.removeCallbacks(autosave)
        if (entrySubmission.get()) return // Submission owns its archived message until the atomic install finishes.
        autosaveHandler.postDelayed(autosave, 500)
    }
    /** Also used on lifecycle departure and for retry after a failed save. A
     * pending review owns its document fingerprint until the decision finishes. */
    fun flushConversations() {
        if (!loaded || state == null || review != null || entrySubmission.get()) return
        if (synchronized(archiveLock) { archiveRevision == savedArchiveRevision }) return
        if (!flushQueued.compareAndSet(false, true)) return
        work {
            try { checkpointConversations(retry = true) } finally { flushQueued.set(false) }
        }
    }
    private fun archivedConversations(): JSONArray = JSONArray().apply {
        conversations.forEach { chat ->
            put(JSONObject().put("id", chat.id).put("createdAt", chat.createdAt).put("composer", chat.draft)
                .put("composerClock", chat.composerClock)
                .put("draft", chat.definition?.let { JSONObject(it.toString()) }).put("messages", JSONArray().apply {
                    chat.lines.forEach { line ->
                        put(JSONObject().put("id", line.id).put("createdAt", line.createdAt).put("text", line.text)
                            .put("kind", when (line.role) { "You" -> "user"; "Habibi" -> "assistant"; else -> "tool" })
                            .put("component", line.component?.let(::JSONObject)).put("detail", line.detail)
                            .apply { line.entryId?.let { put("entryId", it) }; line.reaction?.let { put("reaction", it) } })
                    }
                }))
        }
    }
    private fun checkpointConversations(retry: Boolean = false) {
        if (record == null || review != null) return
        val (revision, snapshot) = synchronized(archiveLock) {
            if (archiveRevision == savedArchiveRevision) return
            if (!retry && archiveRevision == failedArchiveRevision) return
            autosaveHandler.removeCallbacks(autosave)
            archiveRevision to archivedConversations()
        }
        try {
            install(call("save_conversations", authenticated().put("conversations", snapshot).put("deviceId", draftDeviceId)))
            synchronized(archiveLock) {
                savedArchiveRevision = revision
                val saved = state?.optJSONArray("conversations") ?: JSONArray()
                for (index in 0 until saved.length()) {
                    val chat = saved.getJSONObject(index)
                    conversations.firstOrNull { it.id == chat.getString("id") }?.composerClock = chat.optJSONObject("composerClock") ?: JSONObject()
                }
            }
            failedArchiveRevision = null
            if (error == archiveError) error = null
            archiveError = null
            // An edit during storage.save belongs to the next snapshot. Never
            // loop here: continuous typing or a failing disk must not spin.
            if (synchronized(archiveLock) { archiveRevision != savedArchiveRevision }) scheduleConversationSave()
        } catch (cause: Exception) {
            failedArchiveRevision = revision
            failure(cause)
            archiveError = "Conversation changes are not saved. ${error.orEmpty()} Edit your draft or leave this screen to retry."
            error = archiveError
        }
    }
    private fun restoredConversations(value: JSONObject): List<Conversation> {
        val archived = value.optJSONArray("conversations") ?: JSONArray()
        return (0 until archived.length()).map { index ->
            val item = archived.getJSONObject(index)
            Conversation(item.getString("id"), item.getString("createdAt")).apply {
                draft = item.getString("composer")
                composerClock = item.optJSONObject("composerClock") ?: JSONObject()
                definition = item.optJSONObject("draft")?.let { JSONObject(it.toString()) }
                val messages = item.getJSONArray("messages")
                lines = (0 until messages.length()).map { messageIndex ->
                    val message = messages.getJSONObject(messageIndex)
                    ChatLine(when (message.getString("kind")) { "user" -> "You"; "assistant" -> "Habibi"; else -> "Kit tool" },
                        message.getString("text"), message.getString("id"), message.optJSONObject("component")?.toString(),
                        message.getString("createdAt"), message.optString("detail").takeIf { message.has("detail") && !message.isNull("detail") },
                        message.optString("entryId").takeIf { message.has("entryId") && !message.isNull("entryId") },
                        message.optString("reaction").takeIf { message.has("reaction") && !message.isNull("reaction") })
                }
                toolResult = lines.lastOrNull { it.detail != null }?.detail
                // Only display text resumes context. Tool calls, outputs, reviews,
                // approvals and pending work can never be replayed after launch.
                lines.filter { it.role == "You" || it.role == "Habibi" }.forEach {
                    history.put(JSONObject().put("role", if (it.role == "You") "user" else "assistant").put("content", it.text))
                }
            }
        }
    }
    private fun replaceConversations(restored: List<Conversation>, selected: String? = null) {
        autosaveHandler.removeCallbacks(autosave)
        synchronized(archiveLock) {
            conversations = restored.ifEmpty { listOf(Conversation()) }
            conversation = conversations.firstOrNull { it.id == selected } ?: conversations.first()
            archiveRevision++; savedArchiveRevision = archiveRevision
        }
        archiveError = null; failedArchiveRevision = null; inferenceConsent = false
    }

    val otherDrafts: List<String> get() {
        val drafts = state?.optJSONArray("drafts") ?: return emptyList()
        for (index in 0 until drafts.length()) {
            val draft = drafts.getJSONObject(index)
            if (draft.getString("id") != conversation.id) continue
            val versions = draft.getJSONArray("versions")
            return (0 until versions.length()).map { versions.getJSONObject(it).getString("text") }
                .filter { it.isNotEmpty() && it != conversationDraft }.distinct().sorted()
        }
        return emptyList()
    }
    private fun renewDraftReplica() {
        val id = UUID.randomUUID().toString()
        saveDraftDeviceId(id)
        draftDeviceId = id
    }
    fun selectDraftVersion(text: String) = work {
        check(text in otherDrafts) { "The available draft versions changed. Open the picker again." }
        checkpointConversations(retry = true)
        check(archiveError == null) { archiveError.orEmpty() }
        // Editing an alternate branch must not acknowledge the previous branch.
        renewDraftReplica()
        conversationDraft = text
        val drafts = state!!.getJSONArray("drafts")
        for (index in 0 until drafts.length()) {
            val draft = drafts.getJSONObject(index)
            if (draft.getString("id") == conversation.id) {
                val versions = draft.getJSONArray("versions")
                conversation.composerClock = (0 until versions.length()).map { versions.getJSONObject(it) }
                    .first { it.getString("text") == text }.optJSONObject("clock") ?: JSONObject()
            }
        }
    }
    fun setDraftSyncActive(active: Boolean) {
        draftSyncActive = active
        draftSyncDeparture = !active
        autosaveHandler.removeCallbacks(draftSyncPoll)
        if (active) autosaveHandler.post(draftSyncPoll)
        else {
            autosaveHandler.removeCallbacks(draftSyncDebounce)
            synchronizeDrafts(finishing = true) // Best effort only; process suspension is not delivery.
        }
    }
    private fun requestDraftSync() {
        autosaveHandler.removeCallbacks(draftSyncDebounce)
        if (syncConnected) {
            draftSyncMessage = "Draft changes waiting to sync."
            changed()
        }
        if (draftSyncActive) autosaveHandler.postDelayed(draftSyncDebounce, 1500)
    }
    fun synchronizeDrafts(finishing: Boolean = false) {
        if ((!draftSyncActive && !finishing) || !loaded || state == null || (busy && !finishing) || chatting || review != null || syncing || kitAuthorizing || authorizing) return
        if (oauth?.connected(syncOrigin) != true || !draftSyncQueued.compareAndSet(false, true)) return
        if (finishing) draftSyncDeparture = false
        work {
            try {
                val auth = oauth ?: return@work
                val status = coordinator().status()
                val path = "/v1/vaults/${status.getString("vaultId")}/drafts"
                fun request(method: String, target: String = path, body: ByteArray? = null, condition: Map<String, String> = emptyMap()): SyncResponse {
                    val headers = condition + mapOf("Authorization" to "Bearer ${auth.access(syncOrigin)}", "X-Habibi-Vault-Token" to status.getString("token")) +
                        if (body == null) emptyMap() else mapOf("Content-Type" to "application/octet-stream")
                    return syncTransport.request(syncOrigin, method, target, headers, body)
                }
                repeat(3) {
                    if ((!draftSyncActive && !finishing) || chatting || review != null || syncing || kitAuthorizing || authorizing) return@work
                    val remote = request("GET")
                    if (remote.code == 401) {
                        val token = auth.access(syncOrigin)
                        check(syncTransport.request(syncOrigin, "GET", "/v1/me", mapOf("Authorization" to "Bearer $token"), null).success().json().optString("sub").isNotBlank())
                        val body = JSONObject().put("id", status.getString("vaultId")).put("token", status.getString("token")).toString().toByteArray()
                        val registered = syncTransport.request(syncOrigin, "POST", "/v1/vaults", mapOf("Authorization" to "Bearer $token", "Content-Type" to "application/json"), body)
                        check(registered.code == 201 || registered.code == 409)
                        return@repeat
                    }
                    check(remote.code == 200 || remote.code == 404)
                    val condition = if (remote.code == 200) {
                        check(remote.etag == "\"${digest(remote.body)}\"") { "Invalid encrypted draft response." }
                        mapOf("If-Match" to remote.etag)
                    } else mapOf("If-None-Match" to "*")
                    if (!draftSyncActive && !finishing) return@work
                    checkpointConversations(retry = true)
                    if (archiveError != null || synchronized(archiveLock) { archiveRevision != savedArchiveRevision }) return@work
                    val (revision, before) = synchronized(archiveLock) { archiveRevision to conversations.associate { it.id to it.draftRevision } }
                    val args = authenticated().put("deviceId", draftDeviceId)
                    if (remote.code == 200) args.put("envelope", base64url(remote.body))
                    val candidate = call("sync_drafts", args)
                    val drafts = restoredConversations(candidate.getJSONObject("state"))
                    val uploadedComposers = drafts.associate { it.id to it.draft }
                    if (candidate.optBoolean("changed", true)) install(candidate) // Persist before publication or PUT.
                    synchronized(archiveLock) {
                        drafts.forEach { saved ->
                            val local = conversations.firstOrNull { it.id == saved.id }
                            if (local == null) conversations = conversations + saved
                            else if (local.draftRevision == before[local.id]) {
                                local.draft = saved.draft; local.composerClock = saved.composerClock
                            }
                        }
                        if (archiveRevision == revision) savedArchiveRevision = revision
                    }
                    if (synchronized(archiveLock) { archiveRevision != savedArchiveRevision }) scheduleConversationSave()
                    changed()
                    if (candidate.getBoolean("upload")) {
                        if (!draftSyncActive && !finishing) return@work
                        val uploaded = request("PUT", body = decodeEnvelope(candidate.getString("envelope")), condition = condition)
                        if (uploaded.code == 412) return@repeat // Fetch the winner and preserve its branches too.
                        check(uploaded.code == 204)
                    }
                    synchronized(archiveLock) {
                        draftSyncMessage = if (conversations.all { uploadedComposers[it.id] == it.draft || (it.draft.isEmpty() && it.id !in uploadedComposers) })
                            "Draft versions synced encrypted." else "Draft changes waiting to sync."
                    }
                    return@work
                }
                draftSyncMessage = "Draft sync will retry; local versions are saved."
            } catch (_: Exception) {
                draftSyncMessage = "Draft sync paused / offline. Local versions are kept; retrying while the app is open."
            } finally {
                draftSyncQueued.set(false)
                if (draftSyncDeparture && !draftSyncActive) synchronizeDrafts(finishing = true)
            }
        }
    }

    fun inspectBundledKits() = work { loadBundledKits() }
    // Pure public package lookup, never authenticated() or a model tool.
    fun kitPage(id: String): JSONObject = call("kit_page", JSONObject().put("id", id))

    private fun loadBundledKits() {
        // Catalog lookup deliberately has no identity or encrypted document.
        val kits = call("bundled_kits").getJSONArray("kits")
        bundledKits = JSONArray().apply {
            for (index in 0 until kits.length()) {
                val kit = kits.getJSONObject(index)
                if (kit.optString("id") == "github" && kit.optString("authentication") == "device_code" &&
                    kit.getJSONArray("permissions").toString() == JSONArray().put("read:user").toString()) put(kit)
            }
        }
    }
    private fun connectionGate() {
        check(record != null && !chatting && review == null && !syncing && !authorizing && !entrySubmission.get()) {
            "Finish the conversation, Kit review, sync or authorization before managing connections."
        }
        check(formDrafts.isEmpty()) { "Save your open personalization or entry form before managing connections." }
    }
    fun beginGitHubAuthorization() {
        if (!canManageConnections) return
        val attempt = githubAttempts.incrementAndGet()
        work {
            if (githubAttempts.get() != attempt) return@work
            connectionGate()
            loadBundledKits()
            if (!githubConfigured) {
                githubNotice = "The publisher hasn't configured GitHub for this build. Connect is unavailable."
                return@work
            }
            checkpointConversations(retry = true)
            check(archiveError == null) { archiveError.orEmpty() }
            githubNotice = null
            try {
                synchronized(github) {
                    if (githubAttempts.get() != attempt) return@work
                    github.begin(bundledGitHubClientId, ::changed) { ticket, connection ->
                        work {
                            github.commit(ticket) {
                                connectionGate()
                                // Core request and checked durable install both remain
                                // on the existing serial vault worker, not the poller.
                                install(call("connect_kit", authenticated().put("connection", connection)))
                            }
                        }
                    }
                }
            } catch (_: Exception) { githubNotice = "This build's GitHub configuration is invalid. Contact the publisher for an updated build." }
        }
    }
    fun cancelGitHubAuthorization() {
        synchronized(github) { githubAttempts.incrementAndGet(); githubNotice = null; github.cancel() }
        changed()
    }
    fun openGitHubVerification(openBrowser: (String) -> Unit) {
        if (kitAuthorizing && githubAuthorization?.code != null) openBrowser(GitHubDeviceFlow.VERIFICATION_URL)
    }
    fun checkGitHubConnection() {
        if (!canManageConnections) return
        work {
            try {
                connectionGate()
                val account = githubAccount ?: error("No connection")
                check(!account.expired)
                val request = call("connection_request", authenticated().put("id", "github"))
                val response = requestGitHub(GitHubEndpoint.USER, request)
                val login = GitHubDeviceFlow.account(response.json())
                check(login.equals(account.login, ignoreCase = true))
                githubNotice = "Connection checked · Signed in as $login."
            } catch (_: Exception) {
                githubNotice = "GitHub connection could not be verified. It may be offline, expired or revoked. Reconnect to authorize again."
            }
        }
    }
    fun disconnectGitHub() {
        if (!canManageConnections) return
        work {
            try {
                connectionGate()
                install(call("disconnect_kit", authenticated().put("id", "github")))
                githubNotice = "Disconnected on this device. Sync manually to share the removal. Revoke access in GitHub settings to invalidate tokens in old backups or other devices."
            } catch (_: Exception) { githubNotice = "Could not save the disconnection. Your previous encrypted connection is unchanged. Try again." }
        }
    }

    fun configureSync(origin: SyncOrigin) = work {
        check(!syncing && !authorizing) { "Cancel authorization before changing sync origin." }
        syncOrigin = origin
        syncRemovalFailed = false
        syncHeads = emptyList(); syncConflict = false; syncPending = false; syncDecision = ""
        syncConnected = oauth?.connected(origin) == true
        syncMessage = if (syncConnected) "Connected · Tap Sync now to check encrypted versions." else "Not connected · Sign in to enable manual encrypted sync."
    }
    private fun coordinator() = EncryptedSync(syncTransport, { (oauth ?: error("OAuth is unavailable in this build.")).access(syncOrigin) }, syncOrigin,
        { operation, arguments ->
            val payload = authenticated().put("origin", syncOrigin.issuer)
            arguments.keys().forEach { key -> payload.put(key, arguments.get(key)) }
            call(operation, payload)
        }, { candidate ->
            val selected = conversation.id
            val nextState = candidate.optJSONObject("state")
            val restored = nextState?.let(::restoredConversations)
            if (restored != null && nextState.optJSONArray("drafts")?.toString() != state?.optJSONArray("drafts")?.toString()) renewDraftReplica()
            install(candidate)
            if (restored != null) {
                // A remote selection resets protocol/tool/consent and form state,
                // even when stable message/conversation IDs happen to match.
                run?.set(true); run = null; requests = 0; review = null; chatting = false
                formDrafts.clear(); replaceConversations(restored, selected)
                resetGitHubNotice()
            }
            updateSyncStatus(candidate)
        })
    private fun updateSyncStatus(status: JSONObject) {
        syncPending = status.optJSONObject("pending") != null
        syncConflict = status.getBoolean("conflict")
        val heads = status.getJSONArray("heads")
        syncHeads = (0 until heads.length()).map { heads.getJSONObject(it).getString("id") }
        syncDecision = recordFingerprint()
        syncConnected = oauth?.connected(syncOrigin) == true
        syncMessage = when {
            syncPending -> "Pending encrypted upload · Retry Sync now; the exact saved snapshot will be reused."
            syncConflict -> "Conflict · No version was silently selected. Choose explicitly below."
            !syncConnected -> "Not connected · Local changes and sync progress are kept. Sign in again."
            status.getBoolean("dirty") -> "Connected · Local changes are pending. Tap Sync now to upload an encrypted snapshot."
            else -> "Connected · Encrypted versions checked. New edits wait for Sync now."
        }
    }
    fun inspectSync() = work {
        syncConnected = oauth?.connected(syncOrigin) == true
        if (record != null) updateSyncStatus(coordinator().status())
    }
    fun beginSyncAuthorization(openBrowser: (String) -> Unit) {
        if (busy || syncing || kitAuthorizing) return
        work {
            check(!kitAuthorizing) { "Finish or cancel GitHub authorization first." }
            val auth = oauth ?: error("OAuth is unavailable in this build.")
            val url = auth.begin(syncOrigin)
            syncMessage = "Authorization open in your browser · Return here after consent, or cancel."
            publish { if (auth.authorizing()) openBrowser(url) }
        }
    }
    fun cancelSyncAuthorization() {
        oauth?.cancel()
        syncMessage = "Authorization cancelled · No callback can resume it. Sign in again when ready."
        changed()
    }
    fun syncCallback(raw: String) = work {
        try {
            (oauth ?: error("OAuth is unavailable in this build.")).callback(raw, syncOrigin)
            syncConnected = true
            syncMessage = "Connected · Account sign-in does not recover keys. Tap Sync now to sync this vault."
            requestDraftSync()
        } catch (cause: Exception) {
            syncConnected = oauth?.connected(syncOrigin) == true
            syncMessage = "Authorization did not finish · Sign in again. Local data is unchanged."
            throw cause
        }
    }
    fun disconnectSync() {
        oauth?.cancel()
        work {
            syncConnected = false
            try {
                val revoked = (oauth ?: error("OAuth is unavailable in this build.")).disconnect(syncOrigin)
                syncRemovalFailed = false
                syncMessage = if (revoked) "Disconnected · Grant revoked. Local vault, keys, pending uploads and scan progress are kept."
                    else "Disconnected locally · Server revocation could not be confirmed. The grant may remain active until expiry. Local vault and sync progress are kept."
            } catch (cause: Exception) {
                syncRemovalFailed = true
                syncMessage = "Disconnect did not finish · Local credentials could not be removed. A restart may restore them. Retry disconnect; the server grant may still be active. Your vault is unchanged."
                throw cause
            }
        }
    }
    fun syncNow() = performSync(null, null, emptyList(), null)
    fun resolveSync(choice: String, selected: String?, displayedHeads: List<String>, decision: String) = performSync(choice, selected, displayedHeads, decision)
    private fun performSync(choice: String?, selected: String?, displayedHeads: List<String>, decision: String?) {
        if (busy || kitAuthorizing || !syncLock.compareAndSet(false, true)) return
        work {
            try {
                check(!kitAuthorizing) { "Finish or cancel GitHub authorization before syncing." }
                check(!chatting && review == null) { "Stop the conversation and resolve any Kit review before syncing." }
                check(formDrafts.isEmpty()) { "Save your open personalization or entry form before syncing. Unsaved forms will not be replaced." }
                checkpointConversations(retry = true)
                check(archiveError == null && synchronized(archiveLock) { archiveRevision == savedArchiveRevision }) { "Save conversation changes successfully before syncing." }
                if (choice != null) check(recordFingerprint() == decision) { "Your local data changed since confirmation. Review the versions and choose again." }
                syncMessage = "Checking encrypted versions · Editing is paused until sync finishes."
                changed()
                val coordinator = coordinator()
                val result = if (choice == null) coordinator.run() else coordinator.resolve(choice, selected, displayedHeads)
                updateSyncStatus(result)
            } catch (cause: Exception) {
                // Surface DURABLE pending/conflict state even after lost replies.
                runCatching { updateSyncStatus(coordinator().status()) }
                syncMessage = "Sync paused / offline · ${syncMessage} Retry Sync now."
                throw cause
            } finally { syncLock.set(false) }
        }
    }

    fun start() { if (!loaded) reload() }
    fun reload() = work {
        try {
            val saved = storage.load()
            if (saved != null) {
                val restored = call("restore", saved)
                val chats = restoredConversations(restored.getJSONObject("state"))
                record = saved
                state = restored.getJSONObject("state")
                replaceConversations(chats)
                resetGitHubNotice()
            }
            loadFailed = false
        } catch (cause: Exception) {
            loadFailed = true
            throw cause
        } finally { loaded = true }
    }
    fun create(profile: JSONObject) = work {
        check(loaded && !loadFailed && record == null) { "A saved vault already exists or could not be read. Restore it instead of replacing it." }
        install(call("create", JSONObject().put("profile", profile)))
    }
    fun recover(backup: Any, recoveryKey: String, saved: () -> Unit = {}) = work {
        check(!kitAuthorizing) { "Finish or cancel GitHub authorization before restoring." }
        check(!chatting && review == null) { "Stop the conversation and resolve any kit review before restoring." }
        val candidate = call("recover", JSONObject().put("backup", backup).put("recoveryKey", recoveryKey))
        val chats = restoredConversations(candidate.getJSONObject("state"))
        // A backup can predate this device's published clock counters.
        renewDraftReplica()
        install(candidate)
        replaceConversations(chats)
        resetGitHubNotice()
        publish(saved)
    }
    fun updateProfile(profile: JSONObject) = work {
        check(!kitAuthorizing) { "Finish or cancel GitHub authorization before editing your profile." }
        install(call("profile", authenticated().put("profile", profile)))
        formDrafts.keys.filter { it.startsWith("profile_") }.forEach(formDrafts::remove)
    }
    fun updateAppearance(theme: String, appearance: String) {
        if (busy || chatting || review != null || syncing || kitAuthorizing) return
        require(ThemeCatalog.validId.matches(theme) && appearance in setOf("system", "light", "dark"))
        work {
            check(!chatting && review == null && !syncing) { "Finish the conversation, review or sync before changing appearance." }
            val profile = JSONObject((state ?: error("Create a vault first.")).getJSONObject("profile").toString())
                .put("theme", theme).put("appearance", appearance)
            install(call("profile", authenticated().put("profile", profile)))
        }
    }
    fun addEntry(id: String, values: JSONObject, saved: () -> Unit) = work {
        check(!kitAuthorizing) { "Finish or cancel GitHub authorization before saving an entry." }
        install(call("add_entry", authenticated().put("id", id).put("values", values)))
        publish(saved)
    }
    fun summary(id: String, complete: (JSONObject?) -> Unit) = work {
        val result = call("summary", authenticated().put("id", id).put("today", LocalDate.now().toString()))
        publish { complete(result) }
    }
    fun exportRecovery(complete: (JSONObject) -> Unit) = work {
        checkpointConversations(retry = true)
        check(archiveError == null) { archiveError.orEmpty() }
        val result = call("export_recovery", authenticated())
        publish { complete(result) } // Caller displays backup and key separately; never stored in UI state.
    }
    /** SAF streams avoid Android's ~1 MiB intent/clipboard transaction ceiling.
     * The selected file contains only the encrypted backup, NEVER its key. */
    fun writeRecoveryFile(backup: String, open: () -> OutputStream?) = work {
        val bytes = backup.toByteArray(Charsets.UTF_8)
        check(bytes.size <= 8 * 1024 * 1024) { "Encrypted backup is too large." }
        try { (open() ?: error("No destination")).use { it.write(bytes); it.flush() } }
        catch (_: Exception) { error("Could not write the encrypted backup file. Keep your original backup and try exporting again.") }
    }
    fun readRecoveryFile(open: () -> InputStream?, complete: (JSONObject) -> Unit) = work {
        val backup = try {
            val bytes = (open() ?: error("No source")).use { input ->
                val output = ByteArrayOutputStream(); val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer); if (count < 0) break
                    check(output.size() + count <= 8 * 1024 * 1024)
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            JSONObject(String(bytes, Charsets.UTF_8))
        } catch (_: Exception) { error("Could not read an encrypted backup JSON file (maximum 8 MiB). No vault was changed.") }
        publish { complete(backup) }
    }
    fun tool(name: String, arguments: JSONObject) = work {
        check(!kitAuthorizing) { "Finish or cancel GitHub authorization before using Kit tools." }
        check(review == null) { "Resolve the current kit review first." }
        val output = executeTool(name, arguments)
        val pending = output.optJSONObject("review")
        if (pending != null) queueReview(pending, null, null)
        else lines = lines + ChatLine("Kit tool", "$name completed" + if (output.has("draft")) ". Draft ready to review." else ".", detail = toolResult)
        checkpointConversations()
    }
    private fun requestGitHub(endpoint: GitHubEndpoint, descriptor: JSONObject): SyncResponse {
        check(descriptor.keys().asSequence().toSet() == setOf("url", "method", "headers"))
        check(descriptor.getString("url") == endpoint.url && descriptor.getString("method") == "GET" && endpoint.method == "GET")
        val headers = descriptor.getJSONObject("headers").let { value -> value.keys().asSequence().associateWith { value.getString(it) } }
        val bearer = headers["Authorization"] ?: error("Missing authorization")
        check(bearer.startsWith("Bearer ") && headers == GitHubDeviceFlow.userHeaders(bearer.removePrefix("Bearer ")))
        return githubTransport.request(endpoint, headers, null).also {
            check(it.code == 200 && it.body.size <= endpoint.responseLimit)
        }
    }
    private fun executeTool(name: String, arguments: JSONObject, active: AtomicBoolean? = null): JSONObject {
        // The core's review is bound to the input document too. Flush BEFORE
        // asking for it, never between receiving it and capturing the fingerprint.
        checkpointConversations()
        check(active?.get() != true)
        val output = if (name == "github_get_profile" || name == "github_list_repositories") {
            // Only the core's sanitized result can cross into agent history or
            // the archive. Descriptors, raw bodies and credentials stay here.
            try {
                check(arguments.length() == 0 && githubAccount?.expired == false)
                val endpoint = if (name == "github_get_profile") GitHubEndpoint.USER else GitHubEndpoint.REPOSITORIES
                val descriptor = call("connection_request", authenticated().put("id", "github").put("name", name).put("arguments", arguments))
                check(active?.get() != true)
                val response = requestGitHub(endpoint, descriptor)
                check(active?.get() != true)
                val body: Any = if (endpoint == GitHubEndpoint.USER) response.json() else JSONArray(String(response.body, Charsets.UTF_8))
                call("connection_result", JSONObject().put("name", name).put("response", body))
            } catch (_: Exception) { error("The GitHub tool failed. Check the connection or reconnect in Profile → Kits → GitHub.") }
        } else call("kit_tool", authenticated().put("name", name).put("arguments", arguments).put("today", LocalDate.now().toString()))
        check(active?.get() != true)
        output.optJSONObject("draft")?.let { draft = it }
        toolResult = output.opt("result")?.toString()
        return output
    }
    private fun recordFingerprint() = Base64.encodeToString(MessageDigest.getInstance("SHA-256")
        .digest(authenticated().toString().toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    private fun queueReview(value: JSONObject, callId: String?, currentRun: AtomicBoolean?) {
        review = KitReview(++reviewTicket, recordFingerprint(), value.toString(), callId, currentRun)
        changed()
    }
    fun decide(ticket: Long, approved: Boolean) = work {
        val pending = review?.takeIf { it.ticket == ticket } ?: return@work
        var result: Any = JSONObject().put("approved", false).put("changed", false)
        try {
            if (approved && pending.run?.get() != true) {
                check(recordFingerprint() == pending.recordFingerprint) { "Your vault changed during review. Nothing was approved. Ask for a new review." }
                val candidate = call("commit_kit", authenticated().put("review", JSONObject(pending.review)))
                install(candidate)
                result = candidate.opt("result") ?: JSONObject().put("approved", true).put("changed", true)
                lines = lines + ChatLine("Notice", "Kit change approved and saved on this device.")
            }
        } catch (cause: Exception) {
            if (pending.callId != null) appendTool(pending.callId, result)
            chatting = false
            throw cause
        } finally {
            review = null
            checkpointConversations(retry = true)
        }
        if (pending.callId != null) {
            appendTool(pending.callId, result)
            val active = pending.run
            if (active != null && !active.get()) continueChat(active)
        }
    }

    fun configure(endpoint: InferenceEndpoint?) = work {
        if (!chatting) { this.endpoint = endpoint; connected = endpoint != null }
    }
    val canSwitchConversation get() = !busy && !chatting && review == null && !kitAuthorizing
    fun newConversation(): Boolean {
        if (!canSwitchConversation) return false
        synchronized(archiveLock) {
            conversation = Conversation(); conversations = conversations + conversation; archiveRevision++
        }
        scheduleConversationSave()
        changed()
        return true
    }
    fun selectConversation(id: String): Boolean {
        if (id == conversation.id) return true
        if (!canSwitchConversation) return false
        conversation = conversations.firstOrNull { it.id == id } ?: return false
        changed()
        return true
    }
    fun send(message: String) {
        if (busy || chatting || review != null || syncing || kitAuthorizing) return
        val sentDraftRevision = conversation.draftRevision
        work {
            check(!kitAuthorizing && !syncing) { "Finish authorization or sync before chatting." }
            check(!chatting) { "A reply is already running." }
            check(endpoint != null) { "Not connected. A developer must connect an inference bridge for conversations. Your local vault and Kits still work." }
            check(message.isNotBlank()) { "Write a message first." }
            check(review == null) { "Resolve the kit review first." }
            history.put(JSONObject().put("role", "user").put("content", message))
            lines = lines + ChatLine("You", message)
            synchronized(archiveLock) {
                if (conversation.draftRevision == sentDraftRevision && conversationDraft.trim() == message.trim()) conversationDraft = ""
            }
            checkpointConversations()
            val active = AtomicBoolean(false); run = active; chatting = true; requests = 0
            changed()
            continueChat(active)
        }
    }
    val canSubmitKitEntry get() = loaded && state != null && !busy && !chatting && review == null && !syncing && !kitAuthorizing && !entrySubmission.get()

    /** A private user action, never an agent tool/output. The core binds the
     * archived message to its installed Kit and atomically stamps its receipt. */
    fun submitKitEntry(conversationId: String, messageId: String, values: JSONObject) {
        if (!canSubmitKitEntry || conversation.id != conversationId) return
        val chat = conversation
        val message = chat.lines.firstOrNull { it.id == messageId && it.entryId == null } ?: return
        if (message.component?.let { JSONObject(it).optString("type") } != "kit_entry") return
        val submitted = JSONObject(values.toString())
        if (!entrySubmission.compareAndSet(false, true)) return
        autosaveHandler.removeCallbacks(autosave)
        work {
            try {
                check(conversation === chat && !chatting && review == null && !syncing) { "Finish the conversation, review or sync before saving an entry." }
                checkpointConversations(retry = true)
                check(archiveError == null) { archiveError.orEmpty() }
                val candidate = call("submit_kit_entry", authenticated().put("conversationId", conversationId)
                    .put("messageId", messageId).put("values", submitted))
                val entryId = candidate.getJSONObject("result").getString("entryId")
                check(entryId.isNotBlank()) { "The entry receipt is missing. Your saved vault is unchanged." }
                install(candidate)
                synchronized(archiveLock) {
                    // This receipt is already durable. Keep the same conversation
                    // and any composer edits made during either storage write.
                    chat.lines = chat.lines.map { if (it.id == messageId) it.copy(entryId = entryId) else it }
                }
            } finally {
                entrySubmission.set(false)
                if (synchronized(archiveLock) { archiveRevision != savedArchiveRevision }) scheduleConversationSave()
            }
        }
    }
    /** A renderer event is untrusted. Revalidate against this conversation's
     * original card and allow only a local disclosure of its existing data. */
    fun componentSource(conversationId: String, messageId: String, action: String, complete: (JSONObject) -> Unit) {
        if (conversation.id != conversationId || action != "show_source") return
        val serialized = lines.firstOrNull { it.id == messageId }?.component ?: return
        work {
            if (conversation.id != conversationId) return@work
            val validated = call("validate_component", JSONObject().put("component", JSONObject(serialized))).getJSONObject("component")
            val actions = validated.getJSONArray("actions")
            if ((0 until actions.length()).none { actions.getJSONObject(it).getString("id") == action }) return@work
            val data = JSONObject(validated.getJSONObject("data").toString())
            publish { if (conversation.id == conversationId && lines.any { it.id == messageId && it.component == serialized }) complete(data) }
        }
    }
    private fun appendTool(callId: String, result: Any) {
        history.put(JSONObject().put("type", "function_call_output").put("call_id", callId).put("output", result.toString()))
    }
    private fun continueChat(active: AtomicBoolean) {
        try {
            while (!active.get() && requests++ < 8) {
                // Only availability IDs, never account names, credentials or the
                // vault document, are sent when advertising connected tools.
                val connections = JSONArray().apply { if (githubAccount?.expired == false) put("github") }
                val targets = JSONArray().apply {
                    lines.filter { it.role == "You" }.takeLast(80).forEach {
                        put(JSONObject().put("messageId", it.id).put("text", it.text).put("reaction", it.reaction ?: JSONObject.NULL))
                    }
                }
                val request = call("agent_request", JSONObject().put("history", history).put("today", LocalDate.now().toString())
                    .put("connections", connections).put("reactionTargets", targets))
                val response = transport.send(endpoint ?: error("Not connected"), request.getJSONObject("body"), active)
                if (active.get()) break
                val parsed = call("agent_response", JSONObject().put("response", response))
                parsed.optJSONArray("output")?.let { output -> for (index in 0 until output.length()) history.put(output.get(index)) }
                parsed.optString("reply").takeIf { it.isNotBlank() }?.let {
                    lines = lines + ChatLine("Habibi", it); checkpointConversations(); changed()
                }
                val tool = parsed.optJSONObject("tool") ?: break
                val callId = tool.getString("callId")
                try {
                    if (tool.getString("name") == "react_to_message") {
                        val arguments = tool.getJSONObject("arguments")
                        val target = arguments.getString("message_id")
                        check(lines.any { it.id == target && it.role == "You" }) { "User message not found in this conversation." }
                        if (active.get()) { appendTool(callId, JSONObject().put("reacted", false)); break }
                        lines = lines.map { if (it.id == target) it.copy(reaction = arguments.getString("emoji")) else it }
                        appendTool(callId, JSONObject().put("reacted", true))
                        checkpointConversations()
                        changed()
                        break // A reaction is a complete response, not another inference step.
                    }
                    if (tool.getString("name") == "present_component") {
                        val component = call("validate_component", JSONObject().put("component", tool.getJSONObject("arguments").getJSONObject("component"))).getJSONObject("component")
                        if (active.get()) break
                        lines = lines + ChatLine("Habibi", component.getString("fallback"), component = component.toString())
                        appendTool(callId, JSONObject().put("displayed", true))
                        checkpointConversations()
                        changed()
                        continue
                    }
                    val output = executeTool(tool.getString("name"), tool.getJSONObject("arguments"), active)
                    if (active.get()) { appendTool(callId, JSONObject().put("approved", false).put("changed", false)); break }
                    val pending = output.optJSONObject("review")
                    if (pending != null) { queueReview(pending, callId, active); return }
                    appendTool(callId, output.opt("result") ?: JSONObject())
                    lines = lines + ChatLine("Kit tool", "${tool.getString("name")} completed" + if (output.has("draft")) ". Draft ready to review." else ".", detail = toolResult)
                    checkpointConversations()
                    changed()
                } catch (cause: Exception) {
                    // Close the protocol call without publishing a late result,
                    // so the next user message can resume a valid tool history.
                    if (active.get()) { appendTool(callId, JSONObject().put("approved", false).put("changed", false)); break }
                    val reason = if (cause is CoreFailure) cause.message else "The local tool failed. No change was published."
                    appendTool(callId, JSONObject().put("error", reason))
                    lines = lines + ChatLine("Kit tool", reason ?: "The local tool failed.")
                    checkpointConversations()
                    changed() // Let the agent correct invalid synthetic inputs/definitions within the same cap.
                }
            }
            if (!active.get() && requests > 8) error("Conversation paused after eight requests. Send another message to continue.")
        } finally {
            checkpointConversations()
            if (review?.run !== active) { chatting = false; changed() }
        }
    }
    fun stop() {
        run?.set(true)
        transport.cancel()
        work {
            review?.takeIf { it.run != null }?.let {
                if (it.callId != null) appendTool(it.callId, JSONObject().put("approved", false).put("changed", false))
                review = null
            }
            chatting = false
            lines = lines + ChatLine("Notice", "Stopped. Previously saved changes are kept.")
            checkpointConversations()
        }
    }
}
