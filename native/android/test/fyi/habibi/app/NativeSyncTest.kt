package fyi.habibi.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.bottomnavigation.BottomNavigationView
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
import java.net.URI
import java.net.URL
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.concurrent.Executor
import javax.crypto.KeyGenerator

private fun jsonResponse(value: JSONObject, code: Int = 200) = SyncResponse(code, value.toString().toByteArray())
private fun parameters(query: String) = query.split('&').associate { pair ->
    URLDecoder.decode(pair.substringBefore('='), "UTF-8") to URLDecoder.decode(pair.substringAfter('='), "UTF-8")
}
private fun expectFailure(action: () -> Unit): String {
    try { action() } catch (cause: Exception) { return cause.message.orEmpty() }
    throw AssertionError("Expected failure")
}

/** No real network, including production, is used by any test in this file. */
private class OAuthWire : SyncTransport {
    val requests = mutableListOf<Pair<String, ByteArray?>>()
    var changeDiscovery: (JSONObject) -> Unit = {}
    var onToken: () -> Unit = {}
    var failToken = false
    var failRevoke = false
    var suffix = "one"
    override fun request(origin: SyncOrigin, method: String, path: String, headers: Map<String, String>, body: ByteArray?): SyncResponse {
        requests.add(path to body)
        return when (path) {
            "/.well-known/oauth-authorization-server" -> jsonResponse(JSONObject().put("issuer", origin.issuer)
                .put("authorization_endpoint", origin.issuer + "/oauth/authorize").put("token_endpoint", origin.issuer + "/oauth/token")
                .put("registration_endpoint", origin.issuer + "/oauth/register").put("revocation_endpoint", origin.issuer + "/oauth/revoke")
                .put("authorization_response_iss_parameter_supported", true).put("code_challenge_methods_supported", JSONArray().put("S256")).also(changeDiscovery))
            "/oauth/register" -> {
                val value = JSONObject(String(body!!))
                assertEquals("native", value.getString("application_type")); assertEquals("none", value.getString("token_endpoint_auth_method"))
                assertEquals("vaults:sync", value.getString("scope")); assertFalse(value.has("client_secret"))
                jsonResponse(JSONObject().put("client_id", "public-client").put("token_endpoint_auth_method", "none").put("redirect_uris", value.getJSONArray("redirect_uris")), 201)
            }
            "/oauth/token" -> {
                onToken(); check(!failToken) { "Simulated lost token response" }
                assertFalse(headers.containsKey("Authorization"))
                jsonResponse(JSONObject().put("token_type", "Bearer").put("scope", "vaults:sync").put("expires_in", 900)
                    .put("access_token", "access-$suffix").put("refresh_token", "refresh-$suffix"))
            }
            "/oauth/revoke" -> { check(!failRevoke); SyncResponse(200, ByteArray(0)) }
            else -> error("Unexpected OAuth path")
        }
    }
    val exchanges get() = requests.count { it.first == "/oauth/token" }
}
private fun callback(url: String, issuer: String = SyncOrigin.production.issuer): String = NativeOAuth.REDIRECT + "?" + String(form(mapOf(
    "code" to "one-use-code", "state" to parameters(URI(url).rawQuery).getValue("state"), "iss" to issuer)))

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class)
class NativeOAuthTest {
    private val origin = SyncOrigin.production // Only passed to OAuthWire, never a real connection.
    @Test fun publicRegistrationRandomS256AndCredentialsAreDurableBeforePublication() {
        val wire = OAuthWire(); val store = MemoryVault(); val auth = NativeOAuth(store, wire)
        val first = auth.begin(origin); val query = parameters(URI(first).rawQuery)
        assertEquals(origin.issuer, first.substringBefore("/oauth/")); assertEquals(NativeOAuth.REDIRECT, query["redirect_uri"])
        assertEquals("S256", query["code_challenge_method"]); assertTrue(query.getValue("state").length >= 43)
        expectFailure { auth.begin(origin) }
        assertEquals(1, wire.requests.count { it.first == "/oauth/register" })
        store.beforeSave = { assertFalse(auth.connected(origin)) }
        auth.callback(callback(first), origin)
        assertTrue(auth.connected(origin)); assertEquals("access-one", auth.access(origin))
        val exchange = parameters(String(wire.requests.last().second!!))
        assertEquals(query["code_challenge"], base64url(MessageDigest.getInstance("SHA-256").digest(exchange.getValue("code_verifier").toByteArray())))
        assertEquals(NativeOAuth.REDIRECT, exchange["redirect_uri"]); assertEquals("authorization_code", exchange["grant_type"])
        expectFailure { auth.callback(callback(first), origin) }; assertEquals(1, wire.exchanges)
        store.beforeSave = {}
        val second = auth.begin(origin); assertNotEquals(query["state"], parameters(URI(second).rawQuery)["state"])
        assertNotEquals(query["code_challenge"], parameters(URI(second).rawQuery)["code_challenge"])
    }
    @Test fun everyDiscoveryEndpointAndIssuerMustExactlyMatchOrigin() {
        for (key in listOf("issuer", "authorization_endpoint", "token_endpoint", "registration_endpoint", "revocation_endpoint")) {
            val wire = OAuthWire().apply { changeDiscovery = { it.put(key, "https://other.invalid/oauth/token") } }
            val auth = NativeOAuth(MemoryVault(), wire)
            expectFailure { auth.begin(origin) }
            assertEquals(1, wire.requests.size); assertFalse(auth.authorizing())
        }
    }
    @Test fun callbacksFailClosedForConfusionDuplicateParametersAndErrors() {
        val mutations: List<(String) -> String> = listOf(
            { it.replace("state=", "state=wrong") }, { it.replace("iss=", "iss=wrong") },
            { it.replace("android:/", "android://") }, { it.replace("/callback?", "/other?") },
            { "$it#fragment" }, { "$it&code=again" }, { "$it&%73tate=again" }, { "$it&iss=again" },
            { "$it&error=access_denied" }, { "$it&error_description=surprise" }, { "$it&unknown=surprise" },
            { it.replace("code=one-use-code&", "") }, { it.replace("code=one-use-code", "error=access_denied") },
        )
        mutations.forEach { mutate ->
            val wire = OAuthWire(); val store = MemoryVault(); val auth = NativeOAuth(store, wire)
            val valid = callback(auth.begin(origin))
            expectFailure { auth.callback(mutate(valid), origin) }
            expectFailure { auth.callback(valid, origin) }
            assertEquals(0, wire.exchanges); assertNull(store.durable); assertFalse(auth.authorizing())
        }
    }
    @Test fun cancellationExpiryAndProcessDeathCannotResumeAuthorization() {
        var time = 0L
        val store = MemoryVault(); val wire = OAuthWire(); val auth = NativeOAuth(store, wire) { time }
        val cancelled = callback(auth.begin(origin)); auth.cancel()
        expectFailure { auth.callback(cancelled, origin) }
        val expired = callback(auth.begin(origin)); time = 600_001
        expectFailure { auth.callback(expired, origin) }
        val lost = callback(auth.begin(origin)); val restarted = NativeOAuth(store, wire) { time }
        expectFailure { restarted.callback(lost, origin) }; assertEquals(0, wire.exchanges)
    }
    @Test fun responseLossLeavesRotatingRefreshDurablyUnusableAcrossRestart() {
        var time = 0L
        val store = MemoryVault(); val wire = OAuthWire(); val auth = NativeOAuth(store, wire) { time }
        auth.callback(callback(auth.begin(origin)), origin); time = 900_000
        wire.onToken = { assertFalse(JSONObject(store.durable!!).getJSONObject(origin.issuer).getBoolean("usable")) }
        wire.failToken = true
        expectFailure { auth.access(origin) }
        assertFalse(auth.connected(origin)); assertFalse(store.durable!!.contains("refresh-one"))
        val restarted = NativeOAuth(store, wire) { time }
        expectFailure { restarted.access(origin) }; expectFailure { auth.access(origin) }
        assertEquals(2, wire.exchanges) // One code exchange and exactly one refresh attempt.
    }
    @Test fun cancellationDuringCodeExchangeCannotPublishReturnedCredentials() {
        val store = MemoryVault(); val wire = OAuthWire(); val auth = NativeOAuth(store, wire)
        val valid = callback(auth.begin(origin)); wire.onToken = { auth.cancel() }
        expectFailure { auth.callback(valid, origin) }
        assertNull(store.durable); assertFalse(auth.connected(origin)); assertFalse(auth.authorizing())
        expectFailure { auth.callback(valid, origin) }; assertEquals(1, wire.exchanges)
    }
    @Test fun refreshInvalidationDiskFailurePreventsNetworkAndReplacementSaveFailurePreventsPublication() {
        var time = 0L
        val store = MemoryVault(); val wire = OAuthWire(); val auth = NativeOAuth(store, wire) { time }
        auth.callback(callback(auth.begin(origin)), origin); time = 900_000; store.failSave = true
        expectFailure { auth.access(origin) }; assertEquals(1, wire.exchanges)
        store.failSave = false
        val restarted = NativeOAuth(store, wire) { time }
        wire.onToken = { store.failSave = true }
        expectFailure { restarted.access(origin) }
        assertFalse(restarted.connected(origin)); assertEquals(2, wire.exchanges)
        store.failSave = false
        assertFalse(NativeOAuth(store, wire).connected(origin))
    }
    @Test fun replacementRefreshIsSavedAndUsedWithoutReplayingOldToken() {
        var time = 0L
        val store = MemoryVault(); val wire = OAuthWire(); val auth = NativeOAuth(store, wire) { time }
        auth.callback(callback(auth.begin(origin)), origin); time = 900_000; wire.suffix = "two"
        wire.onToken = { assertFalse(auth.connected(origin)) }
        assertEquals("access-two", auth.access(origin)); assertTrue(store.durable!!.contains("refresh-two"))
        assertEquals("access-two", auth.access(origin)); assertEquals(2, wire.exchanges)
    }
    @Test fun failedInitialCredentialSaveDoesNotConnectAndDisconnectReportsRevokeFailure() {
        val store = MemoryVault(); val wire = OAuthWire(); val auth = NativeOAuth(store, wire)
        val valid = callback(auth.begin(origin)); store.failSave = true
        expectFailure { auth.callback(valid, origin) }; assertFalse(auth.connected(origin))
        store.failSave = false; auth.callback(callback(auth.begin(origin)), origin)
        wire.failRevoke = true
        assertFalse(auth.disconnect(origin)); assertFalse(auth.connected(origin)); assertEquals("{}", store.durable)
    }
    @Test fun debugOriginsAreExactRemovedFromIntentsAndNeverReadFromCallbacks() {
        val valid = Intent().putExtra("sync_url", "http://localhost:4000")
        val local = SyncOrigin.fromDebugIntent(valid)
        assertEquals(BuildConfig.DEBUG, local != null); assertFalse(valid.hasExtra("sync_url"))
        for (url in listOf("http://10.0.2.2:4000", "http://localhost:4000/", "http://localhost:4000@evil.invalid", "http://example.com", "https://other.invalid")) {
            assertNull(SyncOrigin.fromDebugIntent(Intent().putExtra("sync_url", url)))
        }
        assertNull(SyncOrigin.fromDebugIntent(Intent(Intent.ACTION_VIEW).putExtra("sync_url", "http://localhost:4000")))
        if (local != null) {
            val store = MemoryVault(); val wire = OAuthWire(); val auth = NativeOAuth(store, wire)
            auth.callback(callback(auth.begin(local), local.issuer), local)
            assertTrue(auth.connected(local)); assertFalse(auth.connected(origin))
            assertEquals("http://localhost:4000/oauth/token", local.url("/oauth/token"))
        }
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class)
class SyncStorageTransportTest {
    @Test fun credentialsAndMultiMegabyteRecordsAreEncryptedAndAuthenticatedAtRest() {
        val context = RuntimeEnvironment.getApplication()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val storage = SecureVaultStorage(context, "oauth-test") { key }
        val record = JSONObject().put("access", "do-not-store-readable-access").put("refresh", "do-not-store-readable-refresh")
            .put("document", "x".repeat(3 * 1024 * 1024))
        storage.save(record)
        val prefs = context.getSharedPreferences("habibi.sealed-oauth-test", Context.MODE_PRIVATE)
        val sealed = prefs.getString("oauth-test", null)!!
        assertFalse(sealed.contains("do-not-store-readable")); assertFalse(sealed.contains("document"))
        assertEquals(record.toString(), storage.load().toString())
        val bad = JSONObject(sealed); val data = bad.getString("data")
        bad.put("data", (if (data[0] == 'A') "B" else "A") + data.drop(1))
        prefs.edit().putString("oauth-test", bad.toString()).commit()
        expectFailure { storage.load() }
        assertEquals(bad.toString(), prefs.getString("oauth-test", null)) // Never reset unreadable secrets.
    }
    private class Connection(val code: Int, val bytes: ByteArray = ByteArray(0)) : HttpURLConnection(URL("https://test.invalid")) {
        var disconnected = false
        val sent = ByteArrayOutputStream()
        override fun connect() {}
        override fun disconnect() { disconnected = true }
        override fun usingProxy() = false
        override fun getResponseCode() = code
        override fun getInputStream() = ByteArrayInputStream(bytes)
        override fun getOutputStream() = sent
    }
    @Test fun redirectResponsesNeverFollowAndTransportIsBoundedWithTimeouts() {
        val redirect = Connection(302); var opened = 0
        val transport = HttpSyncTransport { opened++; redirect }
        expectFailure { transport.request(SyncOrigin.production, "POST", "/oauth/token", mapOf("Content-Type" to "application/x-www-form-urlencoded"), "secret".toByteArray()) }
        assertEquals(1, opened); assertFalse(redirect.instanceFollowRedirects); assertTrue(redirect.disconnected)
        assertEquals(15_000, redirect.connectTimeout); assertEquals(20_000, redirect.readTimeout)
        val oversized = Connection(200, ByteArray(1_048_577))
        expectFailure { HttpSyncTransport { oversized }.request(SyncOrigin.production, "GET", "/v1/me", emptyMap(), null) }
        assertTrue(oversized.disconnected)
        expectFailure { transport.request(SyncOrigin.production, "GET", "//evil.invalid", emptyMap(), null) }
        assertEquals(1, opened)
    }
}

private const val VAULT = "00000000-0000-4000-8000-000000000001"
private const val RECORD = "00000000-0000-4000-8000-000000000002"
private const val OTHER = "00000000-0000-4000-8000-000000000003"
private val SNAPSHOT = "HAB1".toByteArray() + ByteArray(60) { 7 }
private fun head(id: String = RECORD, sequence: Int = 1) = JSONObject().put("id", id).put("sequence", sequence).put("sha256", digest(SNAPSHOT)).put("bytes", SNAPSHOT.size)
private fun syncStatus(dirty: Boolean = false, cursor: Int = 0, conflict: Boolean = false, heads: JSONArray = JSONArray(), pending: Boolean = false) =
    JSONObject().put("vaultId", VAULT).put("token", "s".repeat(43)).put("cursor", cursor).put("heads", heads).put("dirty", dirty).put("conflict", conflict).apply {
        if (pending) put("pending", head().put("envelope", base64url(SNAPSHOT)))
    }
private fun page(vararg records: JSONObject, cursor: Int = records.lastOrNull()?.getInt("sequence") ?: 0) =
    jsonResponse(JSONObject().put("records", JSONArray(records.toList())).put("cursor", cursor))

/** Fixed protocol transcripts, not another implementation of Rust encryption,
 * lineage, dirty detection, outbox or resolution logic. */
private class SyncScript(initial: JSONObject) {
    var durable = initial
    val outputs = ArrayDeque<Pair<String, JSONObject>>()
    val calls = mutableListOf<Pair<String, JSONObject>>()
    fun core(operation: String, arguments: JSONObject): JSONObject {
        calls.add(operation to JSONObject(arguments.toString()))
        if (operation == "sync_status") return JSONObject(durable.toString())
        val (expected, output) = outputs.removeFirst()
        assertEquals(expected, operation)
        return JSONObject(output.toString())
    }
    fun persist(candidate: JSONObject) { durable = JSONObject(candidate.toString()) }
    fun coordinator(http: SyncTransport, persist: (JSONObject) -> Unit = ::persist) =
        EncryptedSync(http, { "oauth-access" }, SyncOrigin.production, ::core, persist)
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class)
class EncryptedSyncTest {
    @Test fun prepareIsDurableBeforeUploadCompleteDoesNotSkipScanAndIngestIsDurableBeforeAdopt() {
        val script = SyncScript(syncStatus(dirty = true))
        script.outputs.add("sync_prepare" to syncStatus(dirty = true, pending = true))
        script.outputs.add("sync_complete" to syncStatus(heads = JSONArray().put(head())))
        script.outputs.add("sync_ingest" to syncStatus(cursor = 1, heads = JSONArray().put(head())))
        script.outputs.add("sync_adopt" to syncStatus(cursor = 1, heads = JSONArray().put(head())))
        val paths = mutableListOf<String>(); var lists = 0
        val http = SyncTransport { _, method, path, headers, body ->
            paths.add("$method $path")
            assertEquals("Bearer oauth-access", headers["Authorization"]); assertEquals("s".repeat(43), headers["X-Habibi-Vault-Token"])
            when {
                method == "PUT" -> {
                    assertNotNull(script.durable.optJSONObject("pending")); assertArrayEquals(SNAPSHOT, body)
                    jsonResponse(head(), 201)
                }
                path.contains('?') -> { lists++; assertTrue(path.endsWith("after=0")); if (lists == 1) page() else page(head()) }
                else -> { if (script.calls.last().first == "sync_ingest") assertEquals(1, script.durable.getInt("cursor")); SyncResponse(200, SNAPSHOT) }
            }
        }
        val result = script.coordinator(http).run()
        assertEquals(1, result.getInt("cursor")); assertFalse(result.getBoolean("dirty")); assertFalse(result.has("pending"))
        assertEquals(listOf("sync_status", "sync_prepare", "sync_complete", "sync_ingest", "sync_adopt"), script.calls.map { it.first })
        assertEquals(1, paths.count { it.startsWith("PUT") }); assertEquals(2, lists)
    }
    @Test fun durableOutboxSurvivesLostAcknowledgementAndRetryUsesExactIdAndEnvelope() {
        val script = SyncScript(syncStatus(dirty = true, pending = true))
        val writes = mutableListOf<Pair<String, ByteArray>>()
        val http = SyncTransport { _, method, path, _, body ->
            if (method == "PUT") { writes.add(path to body!!); error("Lost acknowledgement") }
            else page()
        }
        repeat(2) { expectFailure { script.coordinator(http).run() } }
        assertEquals(2, writes.size); assertEquals(writes[0].first, writes[1].first); assertArrayEquals(writes[0].second, writes[1].second)
        assertTrue(writes[0].first.endsWith(RECORD)); assertTrue(script.durable.has("pending"))
        assertFalse(script.calls.any { it.first == "sync_prepare" || it.first == "sync_complete" })
    }
    @Test fun failedPrepareAndIngestStorageNeverContinueToUploadOrAdopt() {
        val script = SyncScript(syncStatus(dirty = true)); script.outputs.add("sync_prepare" to syncStatus(dirty = true, pending = true))
        var writes = 0
        val http = SyncTransport { _, method, _, _, _ -> if (method == "PUT") writes++; page() }
        expectFailure { script.coordinator(http) { error("Disk full") }.run() }
        assertEquals(0, writes); assertFalse(script.durable.has("pending"))
        val incoming = SyncScript(syncStatus()); incoming.outputs.add("sync_ingest" to syncStatus(cursor = 1, heads = JSONArray().put(head())))
        var reads = 0
        val remote = SyncTransport { _, _, path, _, _ -> reads++; if (path.contains('?')) page(head()) else SyncResponse(200, SNAPSHOT) }
        expectFailure { incoming.coordinator(remote) { error("Disk full") }.run() }
        assertEquals(2, reads); assertEquals(0, incoming.durable.getInt("cursor")); assertFalse(incoming.calls.any { it.first == "sync_adopt" })
    }
    @Test fun unknownVaultRequiresAuthenticatedMeAndConflictCreateOnlyProbesExistingToken() {
        val script = SyncScript(syncStatus()); val requests = mutableListOf<String>()
        val http = SyncTransport { _, method, path, headers, body ->
            requests.add("$method $path")
            when {
                path == "/v1/me" -> jsonResponse(JSONObject().put("sub", "pseudonym"))
                method == "POST" -> { assertEquals(VAULT, JSONObject(String(body!!)).getString("id")); assertFalse(headers.containsKey("X-Habibi-Vault-Token")); SyncResponse(409, ByteArray(0)) }
                else -> if (requests.size == 1) SyncResponse(401, ByteArray(0)) else page()
            }
        }
        script.coordinator(http).run()
        assertEquals(listOf("GET /v1/vaults/$VAULT/records?after=0", "GET /v1/me", "POST /v1/vaults", "GET /v1/vaults/$VAULT/records?after=0"), requests)
        var creates = 0
        expectFailure { SyncScript(syncStatus()).coordinator(SyncTransport { _, method, _, _, _ -> if (method == "POST") creates++; SyncResponse(401, ByteArray(0)) }).run() }
        assertEquals(0, creates)
    }
    @Test fun malformedPagesDigestsAndSequencesNeverIngestOrSpin() {
        val responses = listOf(page(head(sequence = 2)), page(head(), cursor = 2), page(head().put("bytes", 2)), page(head().put("id", "../../other")),
            page(head().put("sha256", "invalid")), page(head().put("sequence", 1.5)), page(*Array(101) { head() }))
        responses.forEach { response ->
            val script = SyncScript(syncStatus()); var requests = 0
            expectFailure { script.coordinator(SyncTransport { _, _, _, _, _ -> requests++; response }).run() }
            assertEquals(1, requests); assertEquals(listOf("sync_status"), script.calls.map { it.first })
        }
        val script = SyncScript(syncStatus())
        expectFailure { script.coordinator(SyncTransport { _, _, path, _, _ -> if (path.contains('?')) page(head()) else SyncResponse(200, SNAPSHOT.copyOf().also { it[10] = 1 }) }).run() }
        assertEquals(listOf("sync_status"), script.calls.map { it.first })
    }
    @Test fun conflictsDoNotUploadOrAdoptAndStaleDisplayedHeadsRequireNewConfirmation() {
        val script = SyncScript(syncStatus(conflict = true, heads = JSONArray().put(head())))
        assertTrue(script.coordinator(SyncTransport { _, _, _, _, _ -> page() }).run().getBoolean("conflict"))
        assertEquals(listOf("sync_status"), script.calls.map { it.first })
        val next = syncStatus(cursor = 1, conflict = true, heads = JSONArray().put(head()).put(head(OTHER)))
        script.outputs.add("sync_ingest" to next)
        val http = SyncTransport { _, _, path, _, _ -> if (path.contains('?')) page(head(OTHER)) else SyncResponse(200, SNAPSHOT) }
        val reason = expectFailure { script.coordinator(http).resolve("local", null, listOf(RECORD)) }
        assertTrue(reason.contains("choose again")); assertFalse(script.calls.any { it.first == "sync_resolve" }); assertEquals(2, script.durable.getJSONArray("heads").length())
    }
    @Test fun pendingResolutionCannotBeReplacedByAnotherDecisionOrScan() {
        val script = SyncScript(syncStatus(conflict = true, pending = true, heads = JSONArray().put(head()).put(head(OTHER))))
        var requests = 0
        expectFailure { script.coordinator(SyncTransport { _, _, _, _, _ -> requests++; page() }).resolve("local", null, listOf(RECORD, OTHER)) }
        assertEquals(0, requests); assertTrue(script.durable.has("pending")); assertEquals(listOf("sync_status"), script.calls.map { it.first })
    }
    @Test fun explicitRemoteChoiceBindsSelectedKnownHeadAndPersistsResolutionBeforeUpload() {
        val heads = JSONArray().put(head()).put(head(OTHER))
        val script = SyncScript(syncStatus(conflict = true, heads = heads))
        script.outputs.add("sync_resolve" to syncStatus(pending = true))
        val http = SyncTransport { _, method, path, _, _ ->
            when {
                method == "PUT" -> { assertTrue(script.durable.has("pending")); error("Offline after resolution") }
                path.contains('?') -> page()
                else -> { assertTrue(path.endsWith(OTHER)); SyncResponse(200, SNAPSHOT) }
            }
        }
        expectFailure { script.coordinator(http).resolve("remote", OTHER, listOf(RECORD, OTHER)) }
        val resolution = script.calls.single { it.first == "sync_resolve" }.second
        assertEquals(OTHER, resolution.getString("recordId")); assertEquals(base64url(SNAPSHOT), resolution.getString("envelope"))
        assertTrue(script.durable.has("pending"))
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class)
class SyncSessionTest {
    private fun session(store: MemoryVault, fixture: FixtureCore, wire: OAuthWire = OAuthWire(), oauthStore: MemoryVault = MemoryVault(), sync: (JSONObject) -> JSONObject,
        http: SyncTransport = SyncTransport { _, _, _, _, _ -> error("Unexpected HTTP") }): HabibiSession =
        HabibiSession(store, { input -> val request = JSONObject(input)
            if (request.getString("operation").startsWith("sync_")) JSONObject().put("ok", sync(request)).toString() else fixture.execute(input)
        }, Executor { it.run() }, { it() }, oauth = NativeOAuth(oauthStore, wire), syncTransport = http)
    @Test fun failedCredentialRemovalIsHonestRetryableAndDoesNotTouchVaultOrRevokeBeforeDeletion() {
        val vault = MemoryVault(); val credentials = MemoryVault(); val wire = OAuthWire()
        val session = session(vault, FixtureCore(), wire, credentials, sync = { syncStatus() })
        session.start(); session.create(profile()); session.beginSyncAuthorization { session.syncCallback(callback(it)) }
        val original = vault.durable; credentials.failSave = true
        session.disconnectSync()
        assertTrue(session.syncRemovalFailed); assertFalse(session.syncConnected); assertTrue(session.syncMessage.contains("restart may restore"))
        assertFalse(wire.requests.any { it.first == "/oauth/revoke" }); assertTrue(credentials.durable!!.contains("access-one"))
        credentials.failSave = false; session.disconnectSync()
        assertFalse(session.syncRemovalFailed); assertEquals("{}", credentials.durable); assertEquals(original, vault.durable)
        assertEquals(1, wire.requests.count { it.first == "/oauth/revoke" })
    }
    @Test fun metadataOnlyInstallRetainsStateAndDiskFailureKeepsPriorDocument() {
        val store = MemoryVault(); val fixture = FixtureCore(); var ingests = 0
        val session = session(store, fixture, sync = { request ->
            when (request.getString("operation")) {
                "sync_status" -> syncStatus()
                "sync_ingest" -> { ingests++; syncStatus(cursor = 1, conflict = true, heads = JSONArray().put(head()))
                    .put("document", JSONObject(request.getJSONObject("document").toString()).put("syncMarker", "ingested")) }
                else -> error("Unexpected core call")
            }
        }, http = SyncTransport { _, _, path, _, _ -> if (path.contains('?')) page(head()) else SyncResponse(200, SNAPSHOT) })
        session.start(); session.create(profile()); session.beginSyncAuthorization { session.syncCallback(callback(it)) }
        val state = session.state
        store.failSave = true; val original = store.durable; session.syncNow()
        assertEquals(original, store.durable); assertSame(state, session.state); assertEquals(1, ingests)
        store.failSave = false; session.syncNow()
        assertSame(state, session.state); assertTrue(JSONObject(store.durable!!).getJSONObject("document").has("syncMarker")); assertTrue(session.syncConflict)
    }
    @Test fun syncFlushesDraftsRefusesReviewsAndFormsAndFreezesEditsWhileApplyingRemote() {
        val store = MemoryVault(); val fixture = FixtureCore(); var calls = 0
        val session = session(store, fixture, sync = { calls++; syncStatus() }, http = SyncTransport { _, _, _, _, _ -> page() })
        session.start(); session.create(profile()); session.conversationDraft = "Unsent private draft"
        session.beginSyncAuthorization { session.syncCallback(callback(it)) }
        session.syncNow()
        assertEquals("Unsent private draft", JSONObject(store.durable!!).getJSONObject("document").getJSONObject("state").getJSONArray("conversations").getJSONObject(0).getString("composer"))
        session.formDrafts["entry_unsaved"] = "Unsaved"; session.syncNow(); assertTrue(session.error!!.contains("entry form")); session.formDrafts.clear()
        session.tool("save_kit", JSONObject().put("definition", definition())); val ticket = session.review!!.ticket
        session.syncNow(); assertNotNull(session.review); assertTrue(session.error!!.contains("Kit review")); session.decide(ticket, false)
        store.failSave = true; session.conversationDraft = "Dirty after failure"; session.syncNow()
        assertEquals("Dirty after failure", session.conversationDraft); assertTrue(session.error!!.contains("Save conversation"))
        assertTrue(calls > 0)
    }
    @Test fun remoteApplyWaitsForDiskFreezesEditsPreservesSelectionAndNeverReplaysProtocolOrConsent() {
        val store = MemoryVault(); val fixture = FixtureCore()
        val session = session(store, fixture, sync = { request ->
            val status = syncStatus(cursor = 1, heads = JSONArray().put(head()))
            if (request.getString("operation") == "sync_adopt") {
                val next = JSONObject(request.getJSONObject("document").getJSONObject("state").toString())
                next.put("profile", profile("Remote"))
                status.put("state", next).put("document", JSONObject(request.getJSONObject("document").toString()).put("state", next))
            } else { assertEquals("sync_status", request.getString("operation")); status }
        }, http = SyncTransport { _, _, path, _, _ -> if (path.contains('?')) page(cursor = 1) else SyncResponse(200, SNAPSHOT) })
        session.start(); session.create(profile()); val selected = session.conversation
        session.conversationDraft = "Saved draft"; session.flushConversations()
        assertTrue(session.newConversation()); session.flushConversations(); assertTrue(session.selectConversation(selected.id))
        session.conversation.history.put(JSONObject().put("type", "function_call").put("name", "never_replay"))
        session.inferenceConsent = true
        session.beginSyncAuthorization { session.syncCallback(callback(it)) }
        store.beforeSave = {
            assertTrue(session.syncing)
            session.conversationDraft = "Typing cannot race remote install"
            assertEquals("Saved draft", session.conversationDraft)
        }
        store.failSave = true; session.syncNow()
        assertSame(selected, session.conversation); assertTrue(session.inferenceConsent)
        assertEquals("Alex", session.state!!.getJSONObject("profile").getString("name"))
        store.failSave = false; session.syncNow()
        assertNotSame(selected, session.conversation); assertEquals(selected.id, session.conversation.id)
        assertEquals("Saved draft", session.conversationDraft); assertFalse(session.inferenceConsent)
        assertFalse(session.conversation.history.toString().contains("never_replay"))
        assertEquals("Remote", session.state!!.getJSONObject("profile").getString("name"))
    }
    @Test fun multiMegabyteRecoveryStreamsAvoidIntentLimitsAndNeverInstallUntilExplicitRecovery() {
        val store = MemoryVault(); val fixture = FixtureCore(); val session = fixtureSession(store, fixture)
        session.start(); session.create(profile()); val original = store.durable
        val backup = JSONObject().put("document", "encrypted".repeat(400_000)).toString()
        val output = ByteArrayOutputStream()
        session.writeRecoveryFile(backup) { output }
        assertNull(session.error); assertEquals(backup, output.toString("UTF-8"))
        var selected: JSONObject? = null
        session.readRecoveryFile({ ByteArrayInputStream(output.toByteArray()) }) { selected = it }
        assertEquals(backup, selected.toString()); assertEquals(original, store.durable)
        var published = false
        session.readRecoveryFile({ ByteArrayInputStream(ByteArray(8 * 1024 * 1024 + 1)) }) { published = true }
        assertFalse(published); assertEquals(original, store.durable); assertTrue(session.error!!.contains("maximum 8 MiB"))
        session.writeRecoveryFile(backup) { throw java.io.IOException("Sensitive provider path") }
        assertFalse(session.error!!.contains("Sensitive")); assertEquals(original, store.durable)
    }
    @Test fun bridgeAcceptsFullLocalDocumentLargerThanOldTwoMiBCeiling() {
        val fixture = FixtureCore(); val store = MemoryVault()
        val session = HabibiSession(store, { input ->
            val response = JSONObject(fixture.execute(input))
            if (JSONObject(input).getString("operation") == "create") response.getJSONObject("ok").getJSONObject("document").put("opaquePending", "x".repeat(3 * 1024 * 1024))
            response.toString()
        }, Executor { it.run() }, { it() })
        session.start(); session.create(profile()); session.updateProfile(profile("Updated"))
        assertNull(session.error); assertEquals("Updated", session.state!!.getJSONObject("profile").getString("name"))
    }
    @Test fun nativeSettingsOpenSystemBrowserCancelCallbackAndDisconnectNeverDeleteVault() {
        val store = MemoryVault(); val wire = OAuthWire(); val fixture = FixtureCore()
        val session = session(store, fixture, wire, sync = { syncStatus(conflict = true, heads = JSONArray().put(head()).put(head(OTHER))) })
        session.start(); session.create(profile()); val original = store.durable
        (RuntimeEnvironment.getApplication() as HabibiApplication).injectedSession = session
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup(); val activity = controller.get()
        fun walk(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { walk(view.getChildAt(it)) } else emptyList()
        fun tagged(tag: String) = activity.window.decorView.findViewWithTag<View>(tag) ?: error("Missing view $tag")
        walk(activity.window.decorView).filterIsInstance<BottomNavigationView>().single().selectedItemId = R.id.profile
        tagged("profile_sync").performClick(); assertTrue(wire.requests.isEmpty())
        tagged("sync_sign_in").performClick()
        val browser = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, browser.action); assertTrue(browser.hasCategory(Intent.CATEGORY_BROWSABLE))
        tagged("sync_cancel").performClick()
        val confused = Intent(Intent.ACTION_VIEW, Uri.parse(callback(browser.dataString!!))).putExtra("sync_url", "http://localhost:4000")
        controller.newIntent(confused)
        assertNull(confused.data); assertNull(confused.extras); assertFalse(session.syncConnected); assertEquals(0, wire.exchanges)
        tagged("sync_sign_in").performClick(); val next = shadowOf(activity).nextStartedActivity
        controller.newIntent(Intent(Intent.ACTION_VIEW, Uri.parse(callback(next.dataString!!))))
        assertTrue(session.syncConnected)
        val texts = walk(activity.window.decorView).filterIsInstance<TextView>().joinToString { it.text }
        assertFalse(texts.contains("access-one")); assertFalse(texts.contains("refresh-one")); assertFalse(texts.contains("s".repeat(43)))
        tagged("sync_keep_local").performClick()
        val confirmation = ShadowDialog.getLatestDialog() as AlertDialog
        assertTrue(confirmation.findViewById<TextView>(android.R.id.message)!!.text.contains(RECORD)); assertTrue(confirmation.findViewById<TextView>(android.R.id.message)!!.text.contains(OTHER))
        confirmation.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
        val saved = Bundle(); controller.saveInstanceState(saved)
        assertFalse(saved.toString().contains("access-one")); assertFalse(saved.toString().contains("code_verifier"))
        session.disconnectSync(); assertEquals(original, store.durable); assertFalse(session.syncConnected)
        controller.pause().stop().destroy()
    }
}
