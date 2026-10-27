package fyi.habibi.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = HabibiApplication::class)
class ChatGPTTest {
    private fun access(number: Int) = "header.${base64url("""{"https://api.openai.com/auth":{"chatgpt_account_id":"account-$number"}}""".toByteArray())}.signature"
    @Test fun modelDefaultOverrideAndResetSurviveRestartAndReachChatGPT() {
        val store = MemoryVault(); val core = FixtureCore(); val secrets = MemoryVault()
        secrets.save(JSONObject().put("access_token", access(2)).put("refresh_token", "fixture-refresh")
            .put("accountId", "account-2").put("expiresAt", System.currentTimeMillis() + 3_600_000))
        val models = mutableListOf<String>()
        lateinit var session: HabibiSession
        val server = object : ChatGPTTransport {
            override fun request(endpoint: ChatGPTEndpoint, headers: Map<String, String>, body: ByteArray, cancelled: AtomicBoolean): SyncResponse {
                assertEquals(ChatGPTEndpoint.INFERENCE, endpoint)
                models.add(JSONObject(String(body)).getString("model"))
                session.setConversationModel("gpt-6.1-terra"); session.setDefaultModel("gpt-6.1-terra")
                // Protocol fixture; Rust tests cover real SSE parsing.
                return SyncResponse(200, """{"output":[],"reply":"Ready."}""".toByteArray())
            }
        }
        fun restored() = HabibiSession(store, core::execute, java.util.concurrent.Executor { it.run() }, { it() },
            chatGPT = ChatGPT(secrets, server))
        session = restored(); session.start(); session.create(profile())
        val first = session.conversation.id
        assertEquals("gpt-6.1-sol", session.conversationModel); assertNull(session.conversation.modelOverride)
        session.setDefaultModel("gpt-6.1-terra"); assertEquals("gpt-6.1-terra", session.conversationModel)
        session.setConversationModel("gpt-6-luna"); session.setDefaultModel("gpt-6.1-sol")
        assertEquals("gpt-6-luna", session.conversationModel)
        session.newConversation(); assertEquals("gpt-6.1-sol", session.conversationModel); assertNull(session.conversation.modelOverride)
        session.flushConversations(); session = restored(); session.start(); session.selectConversation(first)
        assertEquals("gpt-6-luna", session.conversation.modelOverride); assertEquals("gpt-6.1-sol", session.defaultModel)
        session.inferenceConsent = true
        session.send("Hello"); assertEquals("Ready.", session.lines.last().text)
        session.setConversationModel(null); session.send("Use the default")
        assertEquals(listOf("gpt-6-luna", "gpt-6.1-sol"), models)
        assertEquals("gpt-6.1-sol", session.defaultModel); assertNull(session.conversation.modelOverride)
        session.flushConversations(); val final = restored(); final.start(); final.selectConversation(first)
        assertEquals("gpt-6.1-sol", final.conversationModel); assertNull(final.conversation.modelOverride)
        store.failSave = true; final.setDefaultModel("gpt-6.1-terra")
        assertEquals("gpt-6.1-sol", final.defaultModel); assertNotNull(final.error)
    }

    @Test fun syncedApplePreferenceNeverFallsBackToTheHostOrChatGPTOnAndroid() {
        val store = MemoryVault(); val core = FixtureCore(); val secrets = MemoryVault()
        secrets.save(JSONObject().put("access_token", access(2)).put("refresh_token", "fixture-refresh")
            .put("accountId", "account-2").put("expiresAt", System.currentTimeMillis() + 3_600_000))
        val server = Server(); val host = FixtureTransport()
        val session = HabibiSession(store, core::execute, java.util.concurrent.Executor { it.run() }, { it() }, host,
            chatGPT = ChatGPT(secrets, server))
        session.start(); session.create(profile())
        session.configure(InferenceEndpoint("http://127.0.0.1:8083/inference", "fixture-token"))
        assertTrue(session.chatGPTConnected)
        session.setDefaultModel("apple-foundation-models")
        session.inferenceConsent = true
        session.conversationDraft = "Keep this local"
        assertFalse(session.connected)
        session.send("Keep this local")
        assertTrue(session.error!!.contains("isn’t available on Android"))
        assertEquals("Keep this local", session.conversationDraft)
        assertTrue(session.lines.isEmpty())
        assertTrue(server.requests.isEmpty()); assertTrue(host.bodies.isEmpty())
        session.setConversationModel("gpt-6-luna")
        assertTrue(session.connected)
        assertEquals("apple-foundation-models", session.defaultModel)
        session.setConversationModel(null)
        assertFalse(session.connected)
    }

    private inner class Server : ChatGPTTransport {
        val requests = mutableListOf<Triple<ChatGPTEndpoint, Map<String, String>, String>>()
        var loseRefresh = false
        var beforeExchange: () -> Unit = {}
        private var polls = 0
        override fun request(endpoint: ChatGPTEndpoint, headers: Map<String, String>, body: ByteArray, cancelled: AtomicBoolean): SyncResponse {
            val text = String(body, Charsets.UTF_8); requests.add(Triple(endpoint, headers, text))
            fun response(value: String, code: Int = 200) = SyncResponse(code, value.toByteArray())
            return when (endpoint) {
                ChatGPTEndpoint.DEVICE -> response("""{"device_auth_id":"device-id","user_code":"ABCD-1234","interval":"5"}""")
                ChatGPTEndpoint.POLL -> when (++polls) {
                    1 -> response("""{"error":"slow_down"}""", 400)
                    2 -> response("""{"error":"deviceauth_authorization_pending"}""", 400)
                    else -> response("""{"authorization_code":"authorization-code","code_verifier":"device-verifier"}""")
                }
                ChatGPTEndpoint.TOKEN -> {
                    val refresh = text.contains("grant_type=refresh_token")
                    if (refresh && loseRefresh) error("Lost rotation response")
                    assertTrue(text.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
                    if (!refresh) { assertTrue(text.contains("code_verifier=device-verifier")); beforeExchange() }
                    response(JSONObject().put("access_token", access(if (refresh) 2 else 1))
                        .put("refresh_token", if (refresh) "replacement-refresh" else "first-refresh").put("expires_in", 3600).toString())
                }
                ChatGPTEndpoint.INFERENCE -> {
                    assertEquals("Bearer ${access(2)}", headers["Authorization"])
                    assertEquals("account-2", headers["ChatGPT-Account-Id"])
                    response("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n")
                }
            }
        }
    }
    @Test fun deviceLoginRefreshAndDisconnectKeepCredentialsSeparateFromVault() {
        val secrets = MemoryVault(); val server = Server(); var now = 1_000_000L
        val provider = ChatGPT(secrets, server, { now }, { now += it })
        var code = ""; provider.authorize(AtomicBoolean(false)) { code = it }
        assertEquals("ABCD-1234", code); assertTrue(provider.connected)
        now += 3_600_000
        val response = provider.send(JSONObject().put("input", "Hello"), AtomicBoolean(false))
        assertTrue(response.contains("response.completed"))
        assertEquals("replacement-refresh", secrets.load()!!.getString("refresh_token"))
        assertFalse(server.requests.last().third.contains("refresh"))
        val restarted = ChatGPT(secrets, server); restarted.inspect(); assertTrue(restarted.connected)
        restarted.disconnect(); assertFalse(restarted.connected); assertEquals(0, secrets.load()!!.length())
    }
    @Test fun cancellationAndLostOrUnsavedRotationCannotInstallOrReplayCredentials() {
        val cancelled = AtomicBoolean(false); val cancelledSecrets = MemoryVault(); val cancelling = Server()
        cancelling.beforeExchange = { cancelled.set(true) }
        val provider = ChatGPT(cancelledSecrets, cancelling, sleep = {})
        assertTrue(runCatching { provider.authorize(cancelled) {} }.isFailure)
        assertNull(cancelledSecrets.durable); assertFalse(provider.connected)
        for (loseResponse in listOf(true, false)) {
            val secrets = MemoryVault(); val server = Server(); var now = 1_000_000L
            val rotating = ChatGPT(secrets, server, { now }, { now += it })
            rotating.authorize(AtomicBoolean(false)) {}
            now += 3_600_000
            if (loseResponse) server.loseRefresh = true
            else secrets.beforeSave = { if (secrets.load()?.optBoolean("refreshing") == true) secrets.failSave = true }
            assertTrue(runCatching { rotating.send(JSONObject(), AtomicBoolean(false)) }.isFailure)
            val restarted = ChatGPT(secrets, server); restarted.inspect(); assertFalse(restarted.connected)
            assertTrue(runCatching { restarted.send(JSONObject(), AtomicBoolean(false)) }.isFailure)
            assertEquals(1, server.requests.count { it.third.contains("grant_type=refresh_token") })
        }
    }
}
