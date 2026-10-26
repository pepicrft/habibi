package fyi.habibi.app

import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

internal class MemoryVault : VaultStorage {
    var durable: String? = null
    var failSave = false
    var failLoad = false
    var beforeSave: () -> Unit = {}
    var saves = 0
    override fun load(): JSONObject? {
        check(!failLoad) { "Device key unavailable" }
        return durable?.let(::JSONObject)
    }
    override fun save(record: JSONObject) {
        beforeSave()
        check(!failSave) { "Disk full" }
        durable = record.toString(); saves++
    }
}

internal fun profile(name: String = "Alex") = JSONObject().put("name", name).put("goals", JSONArray().put("learning")).put("style", "warm")
internal fun definition() = JSONObject("""{"apiVersion":1,"name":"Energy","description":"Notice your day","fields":[{"key":"energy","label":"Energy","type":"number","unit":"points","min":0,"max":10}],"source":"function summarize(s){return JSON.stringify({metrics:[]})}"}""")

/** Protocol fixture only, not a second crypto/runtime implementation. */
internal class FixtureCore {
    val calls = mutableListOf<JSONObject>()
    var revision = 0
    var failOperation: String? = null
    var recoveredState: JSONObject? = null
    fun execute(input: String): String {
        val request = JSONObject(input); calls.add(request)
        val operation = request.getString("operation")
        if (operation == failOperation) return JSONObject().put("error", JSONObject().put("kind", "invalid").put("message", "Fixture rejected operation")).toString()
        fun candidate(state: JSONObject, identity: Boolean = false): JSONObject {
            val result = JSONObject().put("document", JSONObject().put("revision", ++revision).put("state", state)).put("state", state)
            if (identity) result.put("identity", JSONObject().put("secret", "fixture-content-key"))
            return result
        }
        fun state() = JSONObject(request.getJSONObject("document").getJSONObject("state").toString())
        val result = when (operation) {
            "create" -> candidate(JSONObject().put("version", 1).put("profile", request.getJSONObject("profile")).put("kits", JSONArray()), true)
            "restore" -> JSONObject().put("state", state())
            "recover" -> candidate(recoveredState?.let { JSONObject(it.toString()) }
                ?: JSONObject().put("version", 1).put("profile", profile("Recovered")).put("kits", JSONArray()), true)
            "profile" -> candidate(state().put("profile", request.getJSONObject("profile")))
            "save_conversations" -> candidate(state().put("conversations", JSONArray(request.getJSONArray("conversations").toString())))
            "kit_tool" -> {
                val args = request.getJSONObject("arguments")
                when (val name = request.getString("name")) {
                    "write_kit" -> JSONObject().put("draft", args.getJSONObject("definition")).put("result", JSONObject().put("staged", true))
                    "save_kit", "update_kit", "remove_kit" -> JSONObject().put("result", JSONObject().put("approvalRequired", true))
                        .put("review", JSONObject().put("operation", name).put("definition", args.optJSONObject("definition") ?: definition())
                            .put("entryCount", 0).put("id", args.opt("id") ?: JSONObject.NULL)
                            .put("revision", request.getJSONObject("document").getInt("revision")))
                    else -> JSONObject().put("result", JSONObject().put("metrics", JSONArray()))
                }
            }
            "commit_kit" -> {
                val state = state(); val review = request.getJSONObject("review")
                check(review.getInt("revision") == request.getJSONObject("document").getInt("revision")) { "Stale fixture review" }
                if (review.getString("operation") == "save_kit") state.getJSONArray("kits").put(JSONObject().put("id", "energy-kit")
                    .put("definition", review.getJSONObject("definition")).put("entries", JSONArray()))
                candidate(state).put("result", JSONObject().put("approved", true).put("changed", true))
            }
            "add_entry" -> {
                val state = state()
                state.getJSONArray("kits").getJSONObject(0).getJSONArray("entries").put(JSONObject().put("id", "entry")
                    .put("createdAt", "2026-10-25T10:00:00Z").put("values", request.getJSONObject("values")))
                candidate(state)
            }
            "submit_kit_entry" -> {
                // Boundary fixture: real validation/crypto/idempotency belongs
                // to Rust. Model the atomic document + receipt response here.
                val state = state(); val chats = state.getJSONArray("conversations")
                val chat = (0 until chats.length()).map { chats.getJSONObject(it) }.single { it.getString("id") == request.getString("conversationId") }
                val messages = chat.getJSONArray("messages")
                val message = (0 until messages.length()).map { messages.getJSONObject(it) }.single { it.getString("id") == request.getString("messageId") }
                val entryId = message.optString("entryId").takeIf { it.isNotBlank() } ?: java.util.UUID.randomUUID().toString().also { id ->
                    val kitId = message.getJSONObject("component").getJSONObject("data").getString("kitId")
                    val kits = state.getJSONArray("kits")
                    val kit = (0 until kits.length()).map { kits.getJSONObject(it) }.single { it.getString("id") == kitId }
                    kit.getJSONArray("entries").put(JSONObject().put("id", id).put("createdAt", "2026-10-26T10:00:00Z").put("values", request.getJSONObject("values")))
                    message.put("entryId", id)
                }
                candidate(state).put("result", JSONObject().put("entryId", entryId))
            }
            "summary" -> JSONObject().put("metrics", JSONArray())
            "export_recovery" -> JSONObject().put("backup", JSONObject().put("encrypted", true)).put("recoveryKey", "separate-recovery-key")
            "agent_request" -> JSONObject().put("body", JSONObject().put("input", request.getJSONArray("history")))
            "agent_response" -> request.getJSONObject("response")
            "validate_component" -> JSONObject().put("component", request.getJSONObject("component"))
            else -> error("Unexpected fixture operation: $operation")
        }
        return JSONObject().put("ok", result).toString()
    }
}

internal class FixtureTransport : InferenceTransport {
    val bodies = mutableListOf<JSONObject>()
    val replies = ArrayDeque<JSONObject>()
    var cancelled = false
    override fun send(endpoint: InferenceEndpoint, body: JSONObject, cancelled: AtomicBoolean): JSONObject {
        bodies.add(JSONObject(body.toString()))
        return replies.removeFirstOrNull() ?: JSONObject().put("output", JSONArray()).put("reply", "Ready.")
    }
    override fun cancel() { cancelled = true }
    fun reviewReply() = JSONObject().put("output", JSONArray().put(JSONObject().put("type", "function_call").put("call_id", "call-1")))
        .put("tool", JSONObject().put("callId", "call-1").put("name", "save_kit").put("arguments", JSONObject().put("definition", definition())))
}

internal fun fixtureSession(store: MemoryVault, core: FixtureCore, transport: FixtureTransport = FixtureTransport()) =
    HabibiSession(store, core::execute, Executor { it.run() }, { it() }, transport)

internal fun resultCard() = JSONObject("""{"type":"result_table","version":1,"data":{"title":"Synthetic energy","columns":["Day","Energy"],"rows":[["Monday","7"]]},"actions":[{"id":"show_source","label":"View data"}],"fallback":"Synthetic energy: Monday, 7"}""")
internal fun componentReply(card: JSONObject = resultCard()) = JSONObject().put("output", JSONArray().put(JSONObject().put("type", "function_call").put("call_id", "card-1")))
    .put("component", card).put("tool", JSONObject().put("callId", "card-1").put("name", "present_component").put("arguments", JSONObject().put("component", card)))

internal class FixtureRecognizer(override val available: Boolean = true) : DeviceRecognizer {
    val sessions = mutableListOf<DeviceRecognizer.Events>()
    var stops = 0
    var closes = 0
    override fun start(events: DeviceRecognizer.Events) { sessions.add(events); events.ready() }
    override fun stop() { stops++ }
    override fun close() { closes++ }
}
