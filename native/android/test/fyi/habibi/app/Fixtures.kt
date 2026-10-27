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

internal fun costumeDefinition(name: String = "Coach") = JSONObject().put("apiVersion", 1).put("name", name)
    .put("description", "Take one step at a time.").put("author", "Habibi")
    .put("instructions", "Ask one question before suggesting a small next step.").put("examplePrompt", "Help me find a first step.")

/** Protocol fixture only, not a second crypto/runtime implementation. */
internal class FixtureCore {
    val calls = mutableListOf<JSONObject>()
    var revision = 0
    var failOperation: String? = null
    var recoveredState: JSONObject? = null
    var githubClientId = "public-client"
    private val githubTools get() = JSONArray().apply {
        for (name in listOf("github_get_profile", "github_list_repositories")) put(JSONObject().put("type", "function").put("name", name)
            .put("description", "Read authorized GitHub results without returning credentials.").put("strict", true)
            .put("parameters", JSONObject().put("type", "object").put("additionalProperties", false)
                .put("required", JSONArray()).put("properties", JSONObject())))
    }
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
            "bundled_costumes" -> JSONObject().put("costumes", JSONArray().put(costumeDefinition()))
            "validate_costume" -> JSONObject().put("definition", request.getJSONObject("definition"))
            "save_costume" -> {
                val state = state()
                val id = request.optString("id").takeIf { it.isNotBlank() } ?: java.util.UUID.randomUUID().toString()
                val items = state.optJSONArray("costumes") ?: JSONArray()
                state.put("costumes", JSONArray().apply {
                    for (index in 0 until items.length()) if (items.getJSONObject(index).getString("id") != id) put(items.getJSONObject(index))
                    put(JSONObject().put("id", id).put("definition", request.getJSONObject("definition")))
                })
                candidate(state)
            }
            "remove_costume" -> {
                val state = state(); val items = state.getJSONArray("costumes")
                candidate(state.put("costumes", JSONArray().apply {
                    for (index in 0 until items.length()) if (items.getJSONObject(index).getString("id") != request.getString("id")) put(items.getJSONObject(index))
                }))
            }
            "chatgpt_models" -> JSONObject("""{"defaultModel":"gpt-6.1-sol","models":[{"id":"gpt-6.1-sol","name":"GPT-6.1 Sol"},{"id":"gpt-6.1-terra","name":"GPT-6.1 Terra"},{"id":"gpt-6-luna","name":"GPT-6 Luna"}]}""")
            "chatgpt_request" -> JSONObject().put("body", JSONObject(request.getJSONObject("body").toString()).put("model", request.optString("model", "gpt-6.1-sol")))
            "chatgpt_response" -> JSONObject().put("response", JSONObject(request.getString("stream")))
            "kit_page" -> JSONObject().put("version", 1).put("source", "fixture page")
                .put("kit", JSONObject().put("id", request.getString("id")).put("name", "GitHub").put("description", "Read your profile and public repositories."))
                .put("fallback", "GitHub\nRead your GitHub profile and 10 recent public repositories you own. No private repositories, file contents or write access.")
            "bundled_kits" -> JSONObject().put("kits", JSONArray().put(JSONObject().put("id", "github").put("name", "GitHub")
                .put("description", "Read your GitHub profile and public repositories without sharing credentials with the model.")
                .put("permissions", JSONArray().put("read:user")).put("authentication", "device_code").put("clientId", githubClientId)
                .put("tools", githubTools)))
            "create" -> candidate(JSONObject().put("version", 1).put("profile", request.getJSONObject("profile")).put("kits", JSONArray()), true)
            "restore" -> JSONObject().put("state", state())
            "recover" -> candidate(recoveredState?.let { JSONObject(it.toString()) }
                ?: JSONObject().put("version", 1).put("profile", profile("Recovered")).put("kits", JSONArray()), true)
            "profile" -> candidate(state().put("profile", request.getJSONObject("profile")))
            "save_conversations" -> candidate(state().put("conversations", JSONArray(request.getJSONArray("conversations").toString())))
            "connect_kit" -> candidate(state().put("connections", JSONArray().put(request.getJSONObject("connection"))))
            "disconnect_kit" -> candidate(state().apply { remove("connections") })
            "connection_request" -> {
                val connection = state().getJSONArray("connections").getJSONObject(0)
                check(request.getString("id") == "github")
                val endpoint = if (!request.has("name")) GitHubEndpoint.USER else {
                    check(request.getJSONObject("arguments").length() == 0)
                    when (request.getString("name")) {
                        "github_get_profile" -> GitHubEndpoint.USER
                        "github_list_repositories" -> GitHubEndpoint.REPOSITORIES
                        else -> error("Unexpected fixture connection tool")
                    }
                }
                JSONObject().put("url", endpoint.url).put("method", "GET")
                    .put("headers", JSONObject().put("Authorization", "Bearer ${connection.getString("accessToken")}")
                        .put("Accept", "application/vnd.github+json").put("X-GitHub-Api-Version", "2022-11-28"))
            }
            "connection_result" -> {
                // Minimal protocol outputs only. Full allowlisting and input
                // validation are Rust responsibilities, not a second sanitizer.
                val sanitized: Any = when (request.getString("name")) {
                    "github_get_profile" -> request.getJSONObject("response").let { profile ->
                        JSONObject().put("login", profile.getString("login")).put("name", profile.opt("name") ?: JSONObject.NULL)
                            .put("bio", profile.opt("bio") ?: JSONObject.NULL).put("publicRepositories", profile.getLong("public_repos"))
                            .put("followers", profile.getLong("followers"))
                    }
                    "github_list_repositories" -> JSONObject().put("limit", 10).put("repositories", JSONArray().apply {
                        val repositories = request.getJSONArray("response")
                        for (index in 0 until repositories.length()) {
                            val repository = repositories.getJSONObject(index)
                            put(JSONObject().put("name", repository.getString("name")).put("fullName", repository.getString("full_name"))
                                .put("description", repository.opt("description") ?: JSONObject.NULL).put("language", repository.opt("language") ?: JSONObject.NULL)
                                .put("stars", repository.getLong("stargazers_count")))
                        }
                    })
                    else -> error("Unexpected fixture connection result")
                }
                JSONObject().put("result", sanitized)
            }
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
            "agent_request" -> JSONObject().put("body", JSONObject().put("input", request.getJSONArray("history")).apply {
                val connections = request.optJSONArray("connections") ?: JSONArray()
                if ((0 until connections.length()).any { connections.getString(it) == "github" }) put("tools", githubTools)
            })
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
