package fyi.habibi.app

import android.os.Bundle
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.bottomsheet.BottomSheetDialog
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
import org.robolectric.shadows.ShadowDialog
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.util.concurrent.Executor

private const val GITHUB_DEVICE_CODE = "0123456789abcdef0123456789abcdef01234567"
private class GitHubClock : GitHubScheduler {
    var time = 1_800_000_000_000L
    private class Task(val due: Long, val action: () -> Unit) { var cancelled = false }
    private val tasks = mutableListOf<Task>()
    override fun schedule(delayMillis: Long, action: () -> Unit): GitHubScheduledTask {
        val task = Task(time + delayMillis, action); tasks.add(task)
        return GitHubScheduledTask { task.cancelled = true }
    }
    val delay get() = tasks.filterNot { it.cancelled }.minOfOrNull { it.due - time }
    fun next() {
        val task = tasks.filterNot { it.cancelled }.minByOrNull { it.due } ?: return
        tasks.remove(task); time = maxOf(time, task.due); task.action()
    }
}
private fun githubJson(value: JSONObject, code: Int = 200) = SyncResponse(code, value.toString().toByteArray())
private fun githubToken() = JSONObject().put("access_token", "private-github-access").put("token_type", "bearer")
    .put("scope", "read:user").put("refresh_token", "must-never-store-refresh")
private fun githubParameters(body: ByteArray) = String(body).split('&').associate {
    URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('='), "UTF-8")
}
private class GitHubWire : GitHubTransport {
    data class Request(val endpoint: GitHubEndpoint, val headers: Map<String, String>, val body: ByteArray?)
    val requests = mutableListOf<Request>()
    val replies = ArrayDeque<JSONObject>()
    var device = JSONObject().put("device_code", GITHUB_DEVICE_CODE).put("user_code", "ABCD-EFGH")
        .put("verification_uri", GitHubDeviceFlow.VERIFICATION_URL).put("expires_in", 900).put("interval", 5)
    var identity = JSONObject().put("id", 42).put("login", "private-octocat").put("name", "Octocat")
        .put("bio", "Build things").put("public_repos", 3).put("followers", 2)
    var repositories = JSONArray().put(JSONObject().put("name", "public-project").put("private", false)
        .put("full_name", "private-octocat/public-project").put("description", "A public project").put("language", "Kotlin").put("stargazers_count", 7)
        .put("html_url", "https://github.com/private-octocat/public-project").put("raw_only", "private-repository-response"))
    var userCode = 200
    var tokenCode = 200
    var onRequest: (GitHubEndpoint) -> Unit = {}
    override fun request(endpoint: GitHubEndpoint, headers: Map<String, String>, body: ByteArray?): SyncResponse {
        requests.add(Request(endpoint, headers, body)); onRequest(endpoint)
        return when (endpoint) {
            GitHubEndpoint.DEVICE_CODE -> githubJson(device)
            GitHubEndpoint.ACCESS_TOKEN -> githubJson(replies.removeFirstOrNull() ?: githubToken(), tokenCode)
            GitHubEndpoint.USER -> githubJson(identity, userCode)
            GitHubEndpoint.REPOSITORIES -> SyncResponse(200, repositories.toString().toByteArray())
        }
    }
}
private fun githubFailure(action: () -> Unit): String {
    try { action() } catch (cause: Exception) { return cause.message.orEmpty() }
    throw AssertionError("Expected failure")
}
private fun githubToolReply(name: String, arguments: JSONObject = JSONObject()) = JSONObject()
    .put("output", JSONArray().put(JSONObject().put("type", "function_call").put("call_id", name).put("name", name).put("arguments", arguments.toString())))
    .put("tool", JSONObject().put("callId", name).put("name", name).put("arguments", arguments))

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class)
class GitHubConnectorTest {
    private fun View.walk(): List<View> = listOf(this) + if (this is ViewGroup) (0 until childCount).flatMap { getChildAt(it).walk() } else emptyList()
    private fun MainActivity.tagged(tag: String) = window.decorView.findViewWithTag<View>(tag) ?: error("Missing $tag")
    private fun sheet() = ShadowDialog.getLatestDialog() as BottomSheetDialog
    private fun BottomSheetDialog.tagged(tag: String) = window!!.decorView.findViewWithTag<View>(tag) ?: error("Missing sheet $tag")
    private fun openCatalog(activity: MainActivity) {
        activity.window.decorView.walk().filterIsInstance<BottomNavigationView>().single().selectedItemId = R.id.profile
        activity.tagged("profile_kits").performClick()
    }

    @Test fun pendingAndSlowDownRespectIntervalsAndOnlyValidatedUserIsCommittedWithoutRefresh() {
        val clock = GitHubClock(); val wire = GitHubWire(); val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        wire.replies.add(JSONObject().put("error", "authorization_pending"))
        wire.replies.add(JSONObject().put("error", "slow_down"))
        wire.replies.add(JSONObject().put("error", "slow_down").put("interval", 20))
        wire.replies.add(githubToken().put("expires_in", 3600))
        var saved: JSONObject? = null
        flow.begin("Ov23.public-client", {}) { ticket, connection ->
            assertEquals(GitHubEndpoint.USER, wire.requests.last().endpoint)
            flow.commit(ticket) { saved = connection }
        }
        assertEquals(0L, clock.delay); assertTrue(wire.requests.isEmpty())
        clock.next(); assertEquals("ABCD-EFGH", flow.authorization!!.code); assertEquals(5000L, clock.delay)
        val start = wire.requests.single()
        assertEquals(mapOf("client_id" to "Ov23.public-client", "scope" to "read:user"), githubParameters(start.body!!))
        assertEquals("application/json", start.headers["Accept"])
        clock.next(); assertEquals(5000L, clock.delay)
        clock.next(); assertEquals(10_000L, clock.delay)
        clock.next(); assertEquals(20_000L, clock.delay)
        clock.next()
        assertFalse(flow.authorizing()); assertNull(flow.authorization); assertNotNull(saved)
        assertEquals("private-octocat", saved!!.getString("account"))
        assertEquals(clock.time / 1000 + 3600, saved!!.getLong("expiresAt"))
        assertFalse(saved!!.has("refresh_token")); assertFalse(saved.toString().contains("must-never-store-refresh"))
        assertEquals(setOf("kitId", "clientId", "account", "accessToken", "scope", "expiresAt"), saved!!.keys().asSequence().toSet())
        wire.requests.filter { it.endpoint == GitHubEndpoint.ACCESS_TOKEN }.forEach {
            assertEquals("urn:ietf:params:oauth:grant-type:device_code", githubParameters(it.body!!)["grant_type"])
            assertEquals(GITHUB_DEVICE_CODE, githubParameters(it.body!!)["device_code"])
            assertFalse(githubParameters(it.body!!).containsKey("client_secret"))
        }
        assertEquals(GitHubDeviceFlow.userHeaders("private-github-access"), wire.requests.last().headers)
    }

    @Test fun fixedVerificationUriAndStrictCodeExpiryIntervalValidationFailClosed() {
        val mutations: List<(JSONObject) -> Unit> = listOf(
            { it.put("verification_uri", "https://github.com/login/device?code=ABCD-EFGH") },
            { it.put("verification_uri", "https://attacker.invalid") }, { it.put("user_code", "<script>") },
            { it.put("device_code", "bad\ncredential") }, { it.put("expires_in", 0) },
            { it.put("device_code", "a".repeat(39)) }, { it.put("device_code", "a".repeat(41)) }, { it.put("device_code", "g".repeat(40)) },
            { it.put("expires_in", 901) }, { it.put("expires_in", "900") }, { it.put("interval", 0) }, { it.put("interval", 1.5) },
        )
        mutations.forEach { mutate ->
            val clock = GitHubClock(); val wire = GitHubWire(); mutate(wire.device)
            val flow = GitHubDeviceFlow(wire, clock) { clock.time }
            flow.begin("public-client", {}) { _, _ -> fail("Invalid challenge must not save") }; clock.next()
            assertFalse(flow.authorizing()); assertNull(flow.authorization); assertNull(clock.delay)
            assertEquals(1, wire.requests.size)
        }
    }

    @Test fun scopeTypeTokenExpiryAndAuthenticatedIdentityAreCheckedBeforeAnySave() {
        val mutations: List<(JSONObject) -> Unit> = listOf(
            { it.put("scope", "repo") }, { it.put("scope", "read:user,user:email") },
            { it.put("token_type", "mac") }, { it.put("access_token", "token\r\nHeader: bad") },
            { it.put("access_token", 1234) }, { it.put("expires_in", 0) }, { it.put("expires_in", "3600") },
        )
        mutations.forEach { mutate ->
            val clock = GitHubClock(); val wire = GitHubWire(); wire.replies.add(githubToken().also(mutate))
            val flow = GitHubDeviceFlow(wire, clock) { clock.time }
            flow.begin("public-client", {}) { _, _ -> fail("Invalid token must not save") }; clock.next(); clock.next()
            assertFalse(flow.authorizing()); assertEquals(2, wire.requests.size)
        }
        for (status in listOf(401, 403, 500)) {
            val clock = GitHubClock(); val wire = GitHubWire().apply { userCode = status }
            val flow = GitHubDeviceFlow(wire, clock) { clock.time }
            flow.begin("public-client", {}) { _, _ -> fail("Unauthenticated identity must not save") }; clock.next(); clock.next()
            assertFalse(flow.authorizing())
        }
        val clock = GitHubClock(); val wire = GitHubWire().apply { identity.put("login", "bad\naccount") }
        val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        flow.begin("public-client", {}) { _, _ -> fail("Invalid identity must not save") }; clock.next(); clock.next()
        assertFalse(flow.authorizing())
    }

    @Test fun deadlinesUseRequestStartAndDelayedTokenResponsesCannotExtendLifetimesOrStartIdentityAfterExpiry() {
        for (delay in listOf(899_000L, 900_000L)) {
            val clock = GitHubClock(); val wire = GitHubWire(); val started = clock.time
            val flow = GitHubDeviceFlow(wire, clock) { clock.time }
            wire.onRequest = { if (it == GitHubEndpoint.DEVICE_CODE) clock.time += delay }
            flow.begin("public-client", {}) { _, _ -> fail("Expired device transaction must not save") }; clock.next()
            if (delay < 900_000) {
                assertEquals((started + 900_000) / 1000, flow.authorization!!.expiresAt)
                assertEquals(1000L, clock.delay); clock.next()
            }
            assertFalse(flow.authorizing()); assertNull(flow.authorization); assertEquals(1, wire.requests.size)
        }
        run {
            val clock = GitHubClock(); val wire = GitHubWire(); val flow = GitHubDeviceFlow(wire, clock) { clock.time }
            wire.replies.add(githubToken().put("expires_in", 3600))
            var pollStart = 0L; var saved: JSONObject? = null
            wire.onRequest = { if (it == GitHubEndpoint.ACCESS_TOKEN) { pollStart = clock.time; clock.time += 20_000 } }
            flow.begin("public-client", {}) { ticket, value -> flow.commit(ticket) { saved = value } }; clock.next(); clock.next()
            assertEquals(pollStart / 1000 + 3600, saved!!.getLong("expiresAt"))
        }
        for (tokenLifetime in listOf<Long?>(null, 1)) {
            val clock = GitHubClock(); val wire = GitHubWire(); val flow = GitHubDeviceFlow(wire, clock) { clock.time }
            val token = githubToken(); tokenLifetime?.let { token.put("expires_in", it) }; wire.replies.add(token)
            wire.onRequest = { if (it == GitHubEndpoint.ACCESS_TOKEN) clock.time += if (tokenLifetime == null) 895_000 else 1000 }
            flow.begin("public-client", {}) { _, _ -> fail("Expired response must not reach identity or save") }; clock.next(); clock.next()
            assertFalse(flow.authorizing()); assertEquals(2, wire.requests.size)
        }
        run {
            val clock = GitHubClock(); val wire = GitHubWire(); val flow = GitHubDeviceFlow(wire, clock) { clock.time }
            wire.onRequest = { if (it == GitHubEndpoint.USER) clock.time += 895_000 }
            flow.begin("public-client", {}) { _, _ -> fail("Identity response past deadline cannot save") }; clock.next(); clock.next()
            assertFalse(flow.authorizing())
        }
    }

    @Test fun http400TokenErrorsFollowDeviceStateMachineButAmbiguousErrorWithTokenAlwaysFailsClosed() {
        val clock = GitHubClock(); val wire = GitHubWire(); val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        wire.tokenCode = 400; wire.replies.add(JSONObject().put("error", "authorization_pending"))
        wire.replies.add(JSONObject().put("error", "slow_down").put("interval", 12))
        flow.begin("public-client", {}) { ticket, _ -> flow.commit(ticket) {} }; clock.next(); clock.next()
        assertEquals(5000L, clock.delay); clock.next(); assertEquals(12_000L, clock.delay)
        wire.tokenCode = 200; clock.next(); assertFalse(flow.authorizing())
        for (status in listOf(200, 400)) for (error in listOf("authorization_pending", "slow_down", "access_denied", "")) {
            wire.tokenCode = status; wire.replies.add(githubToken().put("error", error)); val before = wire.requests.size
            flow.begin("public-client", {}) { _, _ -> fail("Ambiguous response must not save") }; clock.next(); clock.next()
            assertFalse(flow.authorizing()); assertNull(clock.delay); assertEquals(before + 2, wire.requests.size)
        }
        wire.tokenCode = 400
        flow.begin("public-client", {}) { _, _ -> fail("HTTP 400 without error must not accept success") }; clock.next(); clock.next()
        assertFalse(flow.authorizing())
    }

    @Test fun emptyScopeAndNonExpiringTokenAreSupportedButDenialAndExpiryAreTerminal() {
        val clock = GitHubClock(); val wire = GitHubWire(); val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        wire.replies.add(githubToken().put("scope", "")); var saved: JSONObject? = null
        flow.begin("public-client", {}) { ticket, connection -> flow.commit(ticket) { saved = connection } }
        clock.next(); clock.next(); assertEquals("", saved!!.getString("scope")); assertFalse(saved!!.has("expiresAt"))
        for (reason in listOf("access_denied", "expired_token", "incorrect_client_credentials")) {
            wire.replies.add(JSONObject().put("error", reason)); saved = null
            flow.begin("public-client", {}) { _, _ -> fail("Terminal errors must not save") }; clock.next(); clock.next()
            assertFalse(flow.authorizing()); assertNull(clock.delay); assertNull(saved)
        }
        wire.device.put("expires_in", 3)
        val count = wire.requests.size
        flow.begin("public-client", {}) { _, _ -> fail("Expired code must not poll or save") }; clock.next(); clock.next()
        assertFalse(flow.authorizing()); assertEquals(count + 1, wire.requests.size)
    }

    @Test fun cancellationDuringEveryHttpStepAndAfterQueuedSuccessCannotSaveOrResume() {
        for (cancelAt in listOf(GitHubEndpoint.DEVICE_CODE, GitHubEndpoint.ACCESS_TOKEN, GitHubEndpoint.USER)) {
            val clock = GitHubClock(); val wire = GitHubWire(); val flow = GitHubDeviceFlow(wire, clock) { clock.time }
            wire.onRequest = { if (it == cancelAt) flow.cancel() }
            flow.begin("public-client", {}) { _, _ -> fail("Cancelled flow cannot save") }; clock.next(); clock.next()
            assertFalse(flow.authorizing()); assertNull(flow.authorization); assertNull(clock.delay)
        }
        val clock = GitHubClock(); val wire = GitHubWire(); val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        var queued: (() -> Unit)? = null; var saves = 0
        flow.begin("public-client", {}) { ticket, _ -> queued = { flow.commit(ticket) { saves++ } } }
        clock.next(); clock.next(); assertNotNull(queued); flow.cancel(); queued!!()
        assertEquals(0, saves)
        val restarted = GitHubDeviceFlow(wire, clock) { clock.time }; assertFalse(restarted.authorizing())
        assertNull(restarted.authorization)
        flow.begin("public-client", {}) { _, _ -> fail("Cancelled waiting poll cannot save") }; clock.next(); flow.cancel(); clock.next()
        assertNull(clock.delay)
    }

    @Test fun errorsNeverReflectServerBodiesCredentialsOrAccountIntoStatus() {
        val clock = GitHubClock(); val wire = GitHubWire(); val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        wire.onRequest = { if (it == GitHubEndpoint.ACCESS_TOKEN) error("private-github-access private-octocat private-device-code") }
        flow.begin("public-client", {}) { _, _ -> fail("Lost response must not save") }; clock.next(); clock.next()
        assertFalse(flow.authorizing())
        for (secret in listOf("private-github-access", "private-octocat", "private-device-code")) assertFalse(flow.message.contains(secret))
    }

    @Test fun hostSessionInstallsDurablyThenChecksUserAndNeverDisclosesConnectionToInferenceOrTranscript() {
        val store = MemoryVault(); val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock(); val inference = FixtureTransport()
        val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        val session = HabibiSession(store, core::execute, Executor { it.run() }, { it() }, inference, githubTransport = wire, github = flow)
        session.start(); session.create(profile()); session.inspectBundledKits()
        val catalog = core.calls.last(); assertEquals(setOf("operation"), catalog.keys().asSequence().toSet())
        session.beginGitHubAuthorization(); clock.next()
        assertTrue(session.kitAuthorizing); assertFalse(session.busy); assertFalse(session.canSwitchConversation)
        val before = core.calls.size; session.send("Do not send during authorization"); session.syncNow()
        session.tool("save_kit", JSONObject().put("definition", definition()))
        assertNull(session.review); assertFalse(core.calls.drop(before).any { it.getString("operation") in listOf("agent_request", "kit_tool", "sync_prepare") })
        store.beforeSave = { assertNull(session.githubAccount) }
        clock.next(); assertEquals("private-octocat", session.githubAccount!!.login)
        store.beforeSave = {}
        assertFalse(session.kitAuthorizing); assertTrue(store.durable!!.contains("private-github-access")) // Fixture document only, real core encrypts.
        assertFalse(store.durable!!.contains("must-never-store-refresh"))
        session.checkGitHubConnection(); assertTrue(session.githubMessage.contains("private-octocat"))
        assertEquals("connection_request", core.calls.last().getString("operation"))
        session.configure(InferenceEndpoint("http://localhost:8083/inference", "fixture")); session.send("Hello")
        val context = inference.bodies.toString() + session.lines.toString()
        for (secret in listOf("private-github-access", "private-octocat", GITHUB_DEVICE_CODE, "public-client")) assertFalse(context.contains(secret))
        val restored = fixtureSession(store, core); restored.start(); assertEquals("private-octocat", restored.githubAccount!!.login)
        val connected = JSONObject(session.state!!.toString())
        session.disconnectGitHub(); assertNull(session.githubAccount); assertFalse(session.state!!.has("connections"))
        assertTrue(session.githubMessage.contains("old backups"))
        session.send("Hello again")
        assertEquals("[]", core.calls.last { it.getString("operation") == "agent_request" }.getJSONArray("connections").toString())
        core.recoveredState = connected
        store.failSave = true
        session.recover(JSONObject(), "fixture-key")
        assertNull(session.githubAccount); assertTrue(session.githubMessage.contains("old backups"))
        store.failSave = false
        session.recover(JSONObject(), "fixture-key")
        assertEquals("private-octocat", session.githubAccount!!.login)
        assertTrue(session.githubMessage.startsWith("Connected")); assertFalse(session.githubMessage.contains("Disconnected"))
        connected.getJSONArray("connections").getJSONObject(0).put("expiresAt", 1)
        session.recover(JSONObject(), "fixture-key")
        assertTrue(session.githubAccount!!.expired); assertTrue(session.githubMessage.contains("expired"))
        core.recoveredState = JSONObject(connected.toString()).apply { remove("connections") }
        session.recover(JSONObject(), "fixture-key")
        assertNull(session.githubAccount); assertEquals("Not connected", session.githubMessage)
    }

    @Test fun agentGitHubToolsUseFixedNativeRequestsAndOnlySanitizedResultsReachInferenceAndArchive() {
        val store = MemoryVault(); val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock(); val inference = FixtureTransport()
        wire.identity.put("email", "private-profile-response").put("access_token", "private-raw-token-field")
            .put("headers", JSONObject().put("Authorization", "Bearer private-raw-profile-header"))
        wire.repositories.getJSONObject(0).put("access_token", "private-raw-repository-token")
            .put("headers", JSONObject().put("Authorization", "Bearer private-raw-repository-header"))
        val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        val session = HabibiSession(store, core::execute, Executor { it.run() }, { it() }, inference, githubTransport = wire, github = flow)
        session.start(); session.create(profile()); session.beginGitHubAuthorization(); clock.next(); clock.next()
        val connectedRequests = wire.requests.size
        val names = listOf("github_get_profile", "github_list_repositories")
        names.forEach { inference.replies.add(githubToolReply(it)) }
        session.configure(InferenceEndpoint("http://localhost:8083/inference", "fixture")); session.send("Read my GitHub profile and public repositories")
        assertFalse(session.chatting); assertNull(session.review); assertNull(session.error)
        assertEquals(listOf(GitHubEndpoint.USER, GitHubEndpoint.REPOSITORIES), wire.requests.drop(connectedRequests).map { it.endpoint })
        wire.requests.drop(connectedRequests).forEach {
            assertNull(it.body); assertEquals(GitHubDeviceFlow.userHeaders("private-github-access"), it.headers)
        }
        val agentRequests = core.calls.filter { it.getString("operation") == "agent_request" }
        assertEquals(3, agentRequests.size)
        agentRequests.forEach {
            assertEquals(setOf("operation", "history", "today", "connections"), it.keys().asSequence().toSet())
            assertEquals("[\"github\"]", it.getJSONArray("connections").toString())
        }
        assertFalse(inference.bodies.first().toString().contains("private-octocat"))
        val descriptors = core.calls.filter { it.getString("operation") == "connection_request" }
        assertEquals(names, descriptors.map { it.getString("name") })
        descriptors.forEach { assertEquals("{}", it.getJSONObject("arguments").toString()) }
        val sanitizers = core.calls.filter { it.getString("operation") == "connection_result" }
        assertEquals(names, sanitizers.map { it.getString("name") })
        sanitizers.forEach { assertEquals(setOf("operation", "name", "response"), it.keys().asSequence().toSet()) }
        assertTrue(sanitizers[0].get("response") is JSONObject); assertTrue(sanitizers[1].get("response") is JSONArray)
        val lastInput = inference.bodies.last().getJSONArray("input")
        val outputs = (0 until lastInput.length()).map { lastInput.getJSONObject(it) }.filter { it.optString("type") == "function_call_output" }
        assertEquals(2, outputs.size)
        val profileResult = JSONObject(outputs[0].getString("output"))
        assertEquals(setOf("login", "name", "bio", "publicRepositories", "followers"), profileResult.keys().asSequence().toSet())
        assertEquals("private-octocat", profileResult.getString("login")); assertEquals(3, profileResult.getInt("publicRepositories"))
        val repositoryResult = JSONObject(outputs[1].getString("output"))
        assertEquals(setOf("repositories", "limit"), repositoryResult.keys().asSequence().toSet()); assertEquals(10, repositoryResult.getInt("limit"))
        val repository = repositoryResult.getJSONArray("repositories").getJSONObject(0)
        assertEquals(setOf("name", "fullName", "description", "language", "stars"), repository.keys().asSequence().toSet())
        assertEquals("public-project", repository.getString("name")); assertEquals(7, repository.getInt("stars"))
        assertEquals(outputs.map { it.getString("output") }, session.lines.mapNotNull { it.detail })
        val restored = fixtureSession(store, core); restored.start()
        assertEquals(session.lines.mapNotNull { it.detail }, restored.lines.mapNotNull { it.detail })
        val archived = session.state!!.getJSONArray("conversations").toString()
        val disclosed = inference.bodies.toString() + archived
        for (secret in listOf("private-github-access", "private-profile-response", "private-repository-response", "private-raw-token-field",
            "private-raw-profile-header", "private-raw-repository-token", "private-raw-repository-header",
            GITHUB_DEVICE_CODE, "public-client", "Authorization", "Bearer ", "api.github.com", "read:user", "access_token")) assertFalse(secret, disclosed.contains(secret))
        assertTrue(disclosed.contains("private-octocat")); assertTrue(disclosed.contains("public-project"))
    }

    @Test fun cancellationDuringGitHubToolNetworkOrSanitizationNeverPublishesLateResults() {
        for (name in listOf("github_get_profile", "github_list_repositories")) for (duringSanitization in listOf(false, true)) {
            val store = MemoryVault(); val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock(); val inference = FixtureTransport()
            lateinit var session: HabibiSession
            val bridge: (String) -> String = { input ->
                val result = core.execute(input)
                if (duringSanitization && JSONObject(input).getString("operation") == "connection_result") session.stop()
                result
            }
            val flow = GitHubDeviceFlow(wire, clock) { clock.time }
            session = HabibiSession(store, bridge, Executor { it.run() }, { it() }, inference, githubTransport = wire, github = flow)
            session.start(); session.create(profile()); session.beginGitHubAuthorization(); clock.next(); clock.next()
            wire.onRequest = { if (!duringSanitization) session.stop() }
            inference.replies.add(githubToolReply(name))
            session.configure(InferenceEndpoint("http://localhost:8083/inference", "fixture")); session.send("Read GitHub")
            assertEquals(1, inference.bodies.size); assertTrue(inference.cancelled); assertFalse(session.chatting)
            assertEquals(if (duringSanitization) 1 else 0, core.calls.count { it.getString("operation") == "connection_result" })
            assertNull(session.toolResult); assertTrue(session.lines.none { it.detail != null || it.role == "Kit tool" })
            assertFalse(session.state!!.getJSONArray("conversations").toString().contains("private-octocat"))
            assertFalse(session.state!!.getJSONArray("conversations").toString().contains("public-project"))
            session.send("Continue without the cancelled result")
            val resumedInput = inference.bodies.last().getJSONArray("input")
            val cancelled = (0 until resumedInput.length()).map { resumedInput.getJSONObject(it) }.single { it.optString("type") == "function_call_output" }
            assertEquals(name, cancelled.getString("call_id"))
            assertFalse(JSONObject(cancelled.getString("output")).getBoolean("changed"))
            assertFalse(inference.bodies.toString().contains("private-octocat")); assertFalse(inference.bodies.toString().contains("public-project"))
        }
    }

    @Test fun githubToolsRejectNonemptyArgumentsAndExpandedDescriptorsBeforeNetwork() {
        val store = MemoryVault(); val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock(); val inference = FixtureTransport()
        var mutate: (JSONObject) -> Unit = {}
        val bridge: (String) -> String = { input ->
            val result = JSONObject(core.execute(input))
            if (JSONObject(input).getString("operation") == "connection_request") mutate(result.getJSONObject("ok"))
            result.toString()
        }
        val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        val session = HabibiSession(store, bridge, Executor { it.run() }, { it() }, inference, githubTransport = wire, github = flow)
        session.start(); session.create(profile()); session.beginGitHubAuthorization(); clock.next(); clock.next()
        session.configure(InferenceEndpoint("http://localhost:8083/inference", "fixture"))
        val before = wire.requests.size
        val mutations: List<(JSONObject) -> Unit> = listOf(
            { it.put("url", "https://api.github.com/user/repos?visibility=all") },
            { it.put("method", "POST") }, { it.put("body", "unexpected") },
            { it.getJSONObject("headers").put("Authorization", "Bearer secret\r\nInjected: bad") },
            { it.getJSONObject("headers").put("X-Extra", "unexpected") },
        )
        for (name in listOf("github_get_profile", "github_list_repositories")) {
            inference.replies.add(githubToolReply(name, JSONObject().put("url", "https://attacker.invalid")))
            session.send("Try invalid arguments")
            mutations.forEach { change ->
                mutate = change; inference.replies.add(githubToolReply(name)); session.send("Try invalid descriptor")
            }
        }
        assertEquals(before, wire.requests.size)
        assertFalse(core.calls.any { it.getString("operation") == "connection_result" })
        assertFalse(session.lines.toString().contains("secret\r\nInjected"))
    }

    @Test fun diskFailureDoesNotPublishAndCancellationBeforeSerialWorkOrQueuedInstallDoesNotSave() {
        val store = MemoryVault(); val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock()
        val queue = ArrayDeque<Runnable>()
        val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        val session = HabibiSession(store, core::execute, Executor { queue.add(it) }, { it() }, githubTransport = wire, github = flow)
        fun drain() { while (queue.isNotEmpty()) queue.removeFirst().run() }
        session.start(); drain(); session.create(profile()); drain()
        session.beginGitHubAuthorization(); session.cancelGitHubAuthorization(); drain(); clock.next()
        assertTrue(wire.requests.isEmpty())
        session.beginGitHubAuthorization(); drain(); clock.next(); clock.next()
        session.cancelGitHubAuthorization(); drain(); assertNull(session.githubAccount)
        assertFalse(core.calls.any { it.getString("operation") == "connect_kit" })
        session.beginGitHubAuthorization(); drain(); clock.next(); clock.next(); store.failSave = true; drain()
        assertNull(session.githubAccount); assertFalse(session.kitAuthorizing); assertTrue(session.githubMessage.contains("Could not save"))
        store.failSave = false; session.beginGitHubAuthorization(); drain(); clock.next(); clock.next(); drain()
        store.failSave = true; session.disconnectGitHub(); drain(); assertNotNull(session.githubAccount)
        assertTrue(session.githubMessage.contains("unchanged"))
    }

    @Test fun hostRejectsExpandedCapabilitiesExpiredConnectionsAndPendingReviewsOrUnsavedForms() {
        val store = MemoryVault(); val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock()
        var mutate: (JSONObject) -> Unit = {}
        val bridge: (String) -> String = { input ->
            val result = JSONObject(core.execute(input))
            if (JSONObject(input).getString("operation") == "connection_request") mutate(result.getJSONObject("ok"))
            result.toString()
        }
        val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        val session = HabibiSession(store, bridge, Executor { it.run() }, { it() }, githubTransport = wire, github = flow)
        session.start(); session.create(profile())
        session.formDrafts["profile_name"] = "Unsaved"
        session.beginGitHubAuthorization(); clock.next(); assertTrue(wire.requests.isEmpty())
        session.formDrafts.clear()
        session.tool("save_kit", JSONObject().put("definition", definition()))
        session.beginGitHubAuthorization(); clock.next(); assertTrue(wire.requests.isEmpty())
        session.decide(session.review!!.ticket, false)
        session.beginGitHubAuthorization(); clock.next(); clock.next(); assertNotNull(session.githubAccount)
        val mutations: List<(JSONObject) -> Unit> = listOf(
            { it.put("url", "https://api.github.com/repos/private") }, { it.put("method", "POST") },
            { it.getJSONObject("headers").put("Accept", "text/html") },
            { it.getJSONObject("headers").put("X-Extra", "unexpected") },
        )
        val count = wire.requests.size
        mutations.forEach { change -> mutate = change; session.checkGitHubConnection(); assertEquals(count, wire.requests.size) }
        val saved = JSONObject(store.durable!!)
        saved.getJSONObject("document").getJSONObject("state").getJSONArray("connections").getJSONObject(0).put("expiresAt", 1)
        store.durable = saved.toString()
        val expired = HabibiSession(store, bridge, Executor { it.run() }, { it() }, FixtureTransport(), githubTransport = wire)
        expired.start(); assertTrue(expired.githubAccount!!.expired); expired.checkGitHubConnection()
        assertEquals(count, wire.requests.size); assertTrue(expired.githubMessage.contains("Reconnect"))
        expired.configure(InferenceEndpoint("http://localhost:8083/inference", "fixture")); expired.send("Hello")
        assertEquals("[]", core.calls.last { it.getString("operation") == "agent_request" }.getJSONArray("connections").toString())
    }

    @Test fun nativeKitsUsesPublisherConfigAndDisclosesInferenceBeforeConnectingWithoutUserSetupFields() {
        val app = RuntimeEnvironment.getApplication() as HabibiApplication
        val store = MemoryVault(); val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock()
        core.githubClientId = "publisher-client"
        val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        val session = HabibiSession(store, core::execute, Executor { it.run() }, { it() }, githubTransport = wire, github = flow)
        app.injectedSession = session; session.start(); session.create(profile())
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        openCatalog(activity); activity.tagged("bundled_github").performClick()
        val detail = sheet()
        fun tagged(tag: String) = detail.tagged(tag)
        assertTrue(detail.isShowing); assertTrue(wire.requests.isEmpty()) // Catalog action never starts authentication.
        val text = detail.window!!.decorView.walk().filterIsInstance<TextView>().joinToString { it.text }
        assertFalse(text.contains("Slack")); assertFalse(text.contains("Calendar")); assertTrue(text.contains("separate recovery key"))
        assertTrue(activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        assertTrue(detail.window!!.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        assertNull(detail.window!!.decorView.findViewWithTag<View>("github_client_id"))
        assertTrue(detail.window!!.decorView.walk().filterIsInstance<TextInputEditText>().isEmpty())
        assertFalse(text.contains("client ID", ignoreCase = true)); assertFalse(text.contains("client secret", ignoreCase = true))
        assertFalse(text.contains("MCP")); assertTrue(text.contains("No private repositories, file contents or write access."))
        assertEquals(View.GONE, tagged("github_details").visibility)
        tagged("github_details_toggle").performClick(); assertEquals(View.VISIBLE, tagged("github_details").visibility)
        val disclosure = (tagged("github_disclosure") as TextView).text.toString()
        assertTrue(disclosure.contains("Before connecting")); assertTrue(disclosure.contains("inference provider"))
        assertTrue(disclosure.contains("public repositories")); assertTrue(disclosure.contains("Credentials stay private"))
        assertTrue(tagged("github_connect").isEnabled)
        val actions = tagged("github_connect").parent as ViewGroup
        assertSame(tagged("github_disclosure"), actions.getChildAt(actions.indexOfChild(tagged("github_connect")) - 1))
        tagged("github_connect").performClick(); clock.next()
        assertEquals("publisher-client", githubParameters(wire.requests.single().body!!)["client_id"])
        assertEquals("ABCD-EFGH", (tagged("github_device_code") as TextView).text.toString())
        tagged("github_open_browser").performClick()
        val intent = shadowOf(activity).nextStartedActivity
        assertEquals(GitHubDeviceFlow.VERIFICATION_URL, intent.dataString)
        assertFalse(intent.toUri(0).contains("ABCD-EFGH")); assertFalse(intent.toUri(0).contains(GITHUB_DEVICE_CODE))
        val bundle = Bundle(); controller.saveInstanceState(bundle)
        for (secret in listOf("private-github-access", GITHUB_DEVICE_CODE, "ABCD-EFGH", "publisher-client")) assertFalse(bundle.toString().contains(secret))
        tagged("github_cancel").performClick(); clock.next(); assertNull(session.githubAccount)
        controller.pause().stop().destroy()
    }

    @Test fun unconfiguredPublisherBuildDisablesConnectWithoutAskingUserForCredentials() {
        val app = RuntimeEnvironment.getApplication() as HabibiApplication
        val store = MemoryVault(); val core = FixtureCore().apply { githubClientId = "" }; val wire = GitHubWire(); val clock = GitHubClock()
        val flow = GitHubDeviceFlow(wire, clock) { clock.time }
        val session = HabibiSession(store, core::execute, Executor { it.run() }, { it() }, githubTransport = wire, github = flow)
        app.injectedSession = session; session.start(); session.create(profile())
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        openCatalog(activity); activity.tagged("bundled_github").performClick()
        val detail = sheet()
        fun tagged(tag: String) = detail.tagged(tag)
        assertFalse(session.githubConfigured); assertFalse(tagged("github_connect").isEnabled)
        assertTrue((tagged("github_unconfigured") as TextView).text.contains("publisher hasn't configured GitHub for this build"))
        assertTrue(detail.window!!.decorView.walk().filterIsInstance<TextInputEditText>().isEmpty())
        val text = detail.window!!.decorView.walk().filterIsInstance<TextView>().joinToString { it.text }
        assertFalse(text.contains("client ID", ignoreCase = true)); assertFalse(text.contains("client secret", ignoreCase = true))
        // The session also fails closed if a caller bypasses the disabled UI.
        session.beginGitHubAuthorization(); clock.next()
        assertFalse(session.kitAuthorizing); assertTrue(wire.requests.isEmpty()); assertNull(session.githubAccount)
        assertTrue(session.githubMessage.contains("publisher hasn't configured"))
        controller.pause().stop().destroy()
    }

    @Test fun catalogSearchFiltersAndDetailDismissalKeepEditorAndPersonalManagement() {
        val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock()
        val session = HabibiSession(MemoryVault(), core::execute, Executor { it.run() }, { it() },
            githubTransport = wire, github = GitHubDeviceFlow(wire, clock) { clock.time })
        (RuntimeEnvironment.getApplication() as HabibiApplication).injectedSession = session
        session.start(); session.create(profile())
        session.tool("save_kit", JSONObject().put("definition", definition())); session.decide(session.review!!.ticket, true)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        openCatalog(activity)
        val tabs = activity.window.decorView.walk().filterIsInstance<BottomNavigationView>().single()
        assertEquals(View.GONE, tabs.visibility)
        val search = activity.tagged("kits_search") as TextInputEditText
        val results = activity.tagged("kits_results")
        search.requestFocus(); search.setText("gItHuB"); search.setSelection(3)
        val root = (activity.findViewById<ViewGroup>(android.R.id.content)).getChildAt(0)
        for (shown in listOf(true, false, true, false)) {
            val insets = WindowInsetsCompat.Builder().setInsets(WindowInsetsCompat.Type.ime(), Insets.of(0, 0, 0, if (shown) 500 else 0))
                .setVisible(WindowInsetsCompat.Type.ime(), shown).build()
            ViewCompat.dispatchApplyWindowInsets(root, insets)
            assertEquals(View.GONE, tabs.visibility)
        }
        assertSame(search, activity.tagged("kits_search")); assertTrue(search.hasFocus())
        assertSame(results, activity.tagged("kits_results"))
        assertNull(activity.window.decorView.findViewWithTag<View>("kit_energy-kit"))
        activity.tagged("kits_filter_connections").performClick()
        activity.tagged("bundled_github").performClick()
        val detail = sheet(); assertTrue(detail.isShowing); assertTrue(wire.requests.isEmpty())
        detail.tagged("github_close").performClick(); shadowOf(Looper.getMainLooper()).idle()
        assertFalse(detail.isShowing)
        assertEquals(View.GONE, tabs.visibility)
        assertSame(search, activity.tagged("kits_search")); assertEquals("gItHuB", search.text.toString())
        assertEquals(3, search.selectionStart); assertTrue(activity.tagged("kits_filter_connections").isSelected)
        assertEquals(0, activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE)
        search.setText("not a real service")
        assertTrue((activity.tagged("kits_empty") as TextView).text.contains("No kits match"))
        assertTrue(search.hasFocus()); assertSame(search, activity.tagged("kits_search"))
        search.setText(""); activity.tagged("kits_filter_personal").performClick()
        assertNull(activity.window.decorView.findViewWithTag<View>("bundled_github"))
        activity.tagged("kit_energy-kit").performClick(); assertNotNull(activity.tagged("add_entry"))
        activity.onBackPressedDispatcher.onBackPressed()
        assertTrue(activity.tagged("kits_filter_personal").isSelected)
        search.setText("notice your day") // Personal descriptions are searchable too.
        assertNotNull(activity.tagged("kit_energy-kit"))
        activity.tagged("kits_connected").performClick()
        assertTrue((activity.tagged("kits_empty") as TextView).text.contains("No kits match"))
        search.setText("")
        assertTrue((activity.tagged("kits_empty") as TextView).text.contains("No connected services"))
        assertNotNull(activity.tagged("design_kit"))
        activity.onBackPressedDispatcher.onBackPressed()
        assertEquals(View.VISIBLE, tabs.visibility)
        assertNull(activity.window.decorView.findViewWithTag<View>("kits_search"))
        controller.pause().stop().destroy()
    }

    @Test fun failedKitPresentationDoesNotDisableNativeAuthenticationOrExposeCoreErrors() {
        val core = FixtureCore().apply { failOperation = "kit_page" }
        val wire = GitHubWire(); val clock = GitHubClock()
        val session = HabibiSession(MemoryVault(), core::execute, Executor { it.run() }, { it() },
            githubTransport = wire, github = GitHubDeviceFlow(wire, clock) { clock.time })
        (RuntimeEnvironment.getApplication() as HabibiApplication).injectedSession = session
        session.start(); session.create(profile())
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        openCatalog(activity); activity.tagged("bundled_github").performClick()
        val detail = sheet()
        assertNotNull(detail.tagged("kit_page_fallback"))
        assertTrue(detail.tagged("github_connect").isEnabled)
        assertNull(session.error)
        assertFalse(detail.window!!.decorView.walk().filterIsInstance<TextView>().any { it.text.contains("Fixture rejected") })
        detail.tagged("github_connect").performClick(); clock.next()
        assertEquals("ABCD-EFGH", (detail.tagged("github_device_code") as TextView).text.toString())
        detail.dismiss(); controller.pause().stop().destroy()
    }

    @Test fun connectedFilterIncludesOnlyActiveBundledServicesNotPersonalKits() {
        val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock()
        val session = HabibiSession(MemoryVault(), core::execute, Executor { it.run() }, { it() },
            githubTransport = wire, github = GitHubDeviceFlow(wire, clock) { clock.time })
        (RuntimeEnvironment.getApplication() as HabibiApplication).injectedSession = session
        session.start(); session.create(profile())
        session.tool("save_kit", JSONObject().put("definition", definition())); session.decide(session.review!!.ticket, true)
        session.beginGitHubAuthorization(); clock.next(); clock.next()
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        openCatalog(activity)
        assertEquals("1 connected", (activity.tagged("kits_connected") as TextView).text.toString())
        assertNotNull(activity.tagged("kit_energy-kit"))
        activity.tagged("kits_connected").performClick()
        assertTrue(activity.tagged("kits_connected").isSelected)
        assertEquals("Manage", (activity.tagged("bundled_github") as TextView).text.toString())
        assertNull(activity.window.decorView.findViewWithTag<View>("kit_energy-kit"))
        activity.tagged("kits_connected").performClick(); assertTrue(activity.tagged("kits_connected").isSelected)
        activity.tagged("kits_filter_all").performClick(); assertNotNull(activity.tagged("kit_energy-kit"))
        controller.pause().stop().destroy()
    }

    @Test fun detailBackAndOutsideDismissalCancelAuthorizationAndSuppressLateCompletion() {
        val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock()
        val session = HabibiSession(MemoryVault(), core::execute, Executor { it.run() }, { it() },
            githubTransport = wire, github = GitHubDeviceFlow(wire, clock) { clock.time })
        (RuntimeEnvironment.getApplication() as HabibiApplication).injectedSession = session
        session.start(); session.create(profile())
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        openCatalog(activity)
        for (outside in listOf(false, true)) {
            activity.tagged("bundled_github").performClick(); val detail = sheet()
            detail.tagged("github_connect").performClick(); clock.next()
            assertTrue(session.kitAuthorizing); assertNotNull(detail.tagged("github_device_code"))
            if (outside) detail.cancel() else activity.onBackPressedDispatcher.onBackPressed()
            shadowOf(Looper.getMainLooper()).idle(); clock.next()
            assertFalse(detail.isShowing); assertFalse(session.kitAuthorizing); assertNull(session.githubAccount)
            assertNull(clock.delay); assertNotNull(activity.tagged("kits_search"))
        }
        assertFalse(core.calls.any { it.getString("operation") == "connect_kit" })
        controller.pause().stop().destroy()
    }

    @Test fun deviceCodeExpiryUpdatesTheOpenDetailAndEnablesAnotherAttempt() {
        val core = FixtureCore(); val wire = GitHubWire().apply { device.put("expires_in", 3) }; val clock = GitHubClock()
        val session = HabibiSession(MemoryVault(), core::execute, Executor { it.run() }, { it() },
            githubTransport = wire, github = GitHubDeviceFlow(wire, clock) { clock.time })
        (RuntimeEnvironment.getApplication() as HabibiApplication).injectedSession = session
        session.start(); session.create(profile())
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        openCatalog(activity); activity.tagged("bundled_github").performClick(); val detail = sheet()
        detail.tagged("github_connect").performClick(); clock.next()
        assertNotNull(detail.tagged("github_device_code")); clock.next()
        assertSame(detail, sheet()); assertTrue(detail.isShowing)
        assertFalse(session.kitAuthorizing); assertNull(detail.window!!.decorView.findViewWithTag<View>("github_device_code"))
        assertTrue((detail.tagged("github_status") as TextView).text.contains("expired"))
        assertTrue(detail.tagged("github_connect").isEnabled)
        detail.tagged("github_connect").performClick(); clock.next(); assertTrue(session.kitAuthorizing)
        detail.tagged("github_close").performClick()
        assertFalse(session.kitAuthorizing) // Dismissal cancels synchronously, not on the next UI loop.
        controller.pause().stop().destroy()
    }

    @Test fun dismissingDetailBeforeQueuedAuthorizationStartsMakesNoGitHubRequest() {
        val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock(); val queue = ArrayDeque<Runnable>()
        val session = HabibiSession(MemoryVault(), core::execute, Executor { queue.add(it) }, { it() },
            githubTransport = wire, github = GitHubDeviceFlow(wire, clock) { clock.time })
        fun drain() { while (queue.isNotEmpty()) queue.removeFirst().run() }
        (RuntimeEnvironment.getApplication() as HabibiApplication).injectedSession = session
        session.start(); drain(); session.create(profile()); drain()
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        openCatalog(activity); drain()
        activity.tagged("bundled_github").performClick(); val detail = sheet()
        detail.tagged("github_connect").performClick()
        assertTrue(session.busy); assertFalse(session.kitAuthorizing)
        detail.tagged("github_close").performClick(); shadowOf(Looper.getMainLooper()).idle()
        drain(); clock.next()
        assertTrue(wire.requests.isEmpty()); assertNull(session.githubAccount); assertFalse(session.kitAuthorizing)
        controller.pause().stop().destroy()
    }

    @Test fun detailSurvivesBrowserReturnAndRecreationThenUpdatesCheckAndDisconnectInPlace() {
        val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock()
        val session = HabibiSession(MemoryVault(), core::execute, Executor { it.run() }, { it() },
            githubTransport = wire, github = GitHubDeviceFlow(wire, clock) { clock.time })
        (RuntimeEnvironment.getApplication() as HabibiApplication).injectedSession = session
        session.start(); session.create(profile())
        val first = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = first.get()
        openCatalog(activity); activity.tagged("bundled_github").performClick(); val oldDetail = sheet()
        oldDetail.tagged("github_connect").performClick(); clock.next()
        oldDetail.tagged("github_open_browser").performClick()
        first.pause().stop(); assertTrue(session.kitAuthorizing)
        first.start().resume().visible()
        assertSame(oldDetail, sheet()); assertTrue(oldDetail.isShowing); assertTrue(session.kitAuthorizing)
        val saved = Bundle(); first.saveInstanceState(saved).pause().stop().destroy()
        assertFalse(oldDetail.isShowing); assertTrue(session.kitAuthorizing)
        val rotated = Robolectric.buildActivity(MainActivity::class.java).create(saved).start().restoreInstanceState(saved).resume().visible()
        val detail = sheet(); assertNotSame(oldDetail, detail)
        assertTrue(detail.isShowing); assertNotNull(detail.tagged("github_device_code"))
        clock.next() // The same app-owned flow completes without reopening the sheet.
        assertSame(detail, sheet()); assertNotNull(session.githubAccount)
        assertEquals("private-octocat", (detail.tagged("github_account") as TextView).text.toString())
        assertNull(detail.window!!.decorView.findViewWithTag<View>("github_device_code"))
        assertEquals("1 connected", (rotated.get().tagged("kits_connected") as TextView).text.toString())
        assertEquals("Manage", (rotated.get().tagged("bundled_github") as TextView).text.toString())
        detail.tagged("github_check").performClick()
        assertTrue((detail.tagged("github_status") as TextView).text.contains("Connection checked"))
        detail.tagged("github_disconnect").performClick()
        val confirmation = ShadowDialog.getLatestDialog() as AlertDialog
        assertTrue(confirmation.window!!.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        confirmation.getButton(AlertDialog.BUTTON_POSITIVE).performClick(); shadowOf(Looper.getMainLooper()).idle()
        assertTrue(detail.isShowing); assertNull(session.githubAccount)
        assertTrue((detail.tagged("github_status") as TextView).text.contains("Disconnected"))
        assertEquals("0 connected", (rotated.get().tagged("kits_connected") as TextView).text.toString())
        rotated.pause().stop().destroy(); assertFalse(detail.isShowing); assertFalse(confirmation.isShowing)
    }

    @Test fun expiredConnectionsAreExcludedFromCountAndConnectedFilterButOfferReconnectInDetail() {
        val core = FixtureCore(); val wire = GitHubWire(); val clock = GitHubClock()
        val session = HabibiSession(MemoryVault(), core::execute, Executor { it.run() }, { it() },
            githubTransport = wire, github = GitHubDeviceFlow(wire, clock) { clock.time })
        (RuntimeEnvironment.getApplication() as HabibiApplication).injectedSession = session
        session.start(); session.create(profile()); session.beginGitHubAuthorization(); clock.next(); clock.next()
        val expired = JSONObject(session.state!!.toString())
        expired.getJSONArray("connections").getJSONObject(0).put("expiresAt", 1)
        core.recoveredState = expired; session.recover(JSONObject(), "fixture-key")
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        openCatalog(activity)
        assertEquals("0 connected", (activity.tagged("kits_connected") as TextView).text.toString())
        assertEquals("Reconnect", (activity.tagged("bundled_github") as TextView).text.toString())
        activity.tagged("kits_connected").performClick()
        assertNull(activity.window.decorView.findViewWithTag<View>("bundled_github")); assertNotNull(activity.tagged("kits_empty"))
        activity.tagged("kits_filter_connections").performClick(); activity.tagged("bundled_github").performClick()
        val detail = sheet()
        assertEquals("Reconnect GitHub", (detail.tagged("github_connect") as TextView).text.toString())
        assertTrue(detail.tagged("github_connect").isEnabled); assertFalse(detail.tagged("github_check").isEnabled)
        assertTrue(detail.window!!.decorView.walk().filterIsInstance<TextView>().any { it.text.contains("Connection expired") })
        val before = wire.requests.size; detail.tagged("github_connect").performClick(); clock.next()
        assertTrue(session.kitAuthorizing); assertEquals(before + 1, wire.requests.size)
        detail.tagged("github_cancel").performClick(); controller.pause().stop().destroy()
    }

    @Test fun httpTransportUsesFixedEndpointsBoundedBodiesTimeoutsAndNoRedirects() {
        class Connection(private val code: Int = 200, private val bytes: ByteArray = "{}".toByteArray()) : HttpURLConnection(URL("https://not-contacted.invalid")) {
            var disconnected = false
            val output = ByteArrayOutputStream()
            override fun connect() {}
            override fun disconnect() { disconnected = true }
            override fun usingProxy() = false
            override fun getResponseCode() = code
            override fun getInputStream() = ByteArrayInputStream(bytes)
            override fun getErrorStream() = ByteArrayInputStream(bytes)
            override fun getOutputStream() = output
        }
        val connection = Connection(); val urls = mutableListOf<String>()
        val http = HttpGitHubTransport { urls.add(it); connection }
        http.request(GitHubEndpoint.USER, GitHubDeviceFlow.userHeaders("test-only"), null)
        assertEquals(listOf("https://api.github.com/user"), urls)
        assertEquals("GET", connection.requestMethod); assertFalse(connection.instanceFollowRedirects)
        assertEquals(15_000, connection.connectTimeout); assertEquals(20_000, connection.readTimeout); assertTrue(connection.disconnected)
        for (bad in listOf(Connection(302), Connection(bytes = ByteArray(65_537)))) {
            val error = githubFailure { HttpGitHubTransport { bad }.request(GitHubEndpoint.USER, emptyMap(), null) }
            assertTrue(error.contains("safely")); assertTrue(bad.disconnected)
        }
        assertEquals(setOf("https://github.com/login/device/code", "https://github.com/login/oauth/access_token", "https://api.github.com/user",
            "https://api.github.com/user/repos?visibility=public&affiliation=owner&sort=updated&per_page=10"), GitHubEndpoint.entries.map { it.url }.toSet())
        for (endpoint in GitHubEndpoint.entries) {
            val limit = if (endpoint == GitHubEndpoint.REPOSITORIES) 256 * 1024 else 64 * 1024
            assertEquals(limit, endpoint.responseLimit)
            val body = if (endpoint.method == "POST") "client_id=publisher-client".toByteArray() else null
            val bounded = Connection(bytes = ByteArray(limit))
            assertEquals(limit, HttpGitHubTransport { bounded }.request(endpoint, emptyMap(), body).body.size)
            assertEquals(endpoint.method, bounded.requestMethod)
            val oversized = Connection(bytes = ByteArray(limit + 1))
            assertTrue(githubFailure { HttpGitHubTransport { oversized }.request(endpoint, emptyMap(), body) }.contains("safely"))
            assertTrue(oversized.disconnected)
        }
        var opened = false
        githubFailure { HttpGitHubTransport { opened = true; Connection() }.request(GitHubEndpoint.DEVICE_CODE, emptyMap(), ByteArray(16_385)) }
        assertFalse(opened)
    }
}
