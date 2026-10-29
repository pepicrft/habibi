package fyi.habibi.app

import org.json.JSONObject

/** HTTP orchestration only. Rust authenticates ciphertext, tracks lineage and
 * owns the durable outbox. No conflict policy or encryption is duplicated here. */
internal class EncryptedSync(
    private val http: SyncTransport,
    private val access: () -> String,
    private val origin: SyncOrigin,
    private val core: (String, JSONObject) -> JSONObject,
    private val persist: (JSONObject) -> Unit,
) {
    fun status(): JSONObject = core("sync_status", JSONObject())
    private fun change(operation: String, arguments: JSONObject = JSONObject()): JSONObject {
        val candidate = core(operation, arguments)
        // Every metadata mutation uses the SAME install gate as local edits.
        // A failed save stops the scan/upload before the next network operation.
        persist(candidate)
        return candidate
    }
    private fun request(status: JSONObject, method: String, path: String, body: ByteArray? = null, json: Boolean = false): SyncResponse {
        val token = status.getString("token")
        check(token.matches(Regex("[A-Za-z0-9_-]{43}"))) { "Invalid vault sync capability." }
        val headers = mutableMapOf("Authorization" to "Bearer ${access()}", "X-Habibi-Vault-Token" to token)
        if (body != null) headers["Content-Type"] = if (json) "application/json" else "application/octet-stream"
        return http.request(origin, method, path, headers, body)
    }
    private fun root(status: JSONObject) = "/v1/vaults/${id(status.getString("vaultId"))}"
    private fun id(value: String): String {
        check(value.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))) { "Invalid sync record ID." }; return value
    }
    private fun number(value: JSONObject, key: String, min: Long, max: Long): Long {
        val raw = value.get(key)
        check(raw is Number && raw !is Float && raw !is Double) { "Invalid sync sequence or size." }
        return raw.toLong().also { check(it in min..max) { "Invalid sync sequence or size." } }
    }
    private fun metadata(value: JSONObject): JSONObject {
        id(value.getString("id"))
        check(value.getString("sha256").matches(Regex("[0-9a-f]{64}"))) { "Invalid sync digest." }
        number(value, "bytes", 64, 1_048_576); number(value, "sequence", 1, Long.MAX_VALUE)
        return value
    }
    private fun envelope(status: JSONObject, head: JSONObject): String {
        val bytes = request(status, "GET", root(status) + "/records/" + id(head.getString("id"))).success().body
        check(bytes.size.toLong() == number(head, "bytes", 64, 1_048_576) && digest(bytes) == head.getString("sha256")) { "Encrypted snapshot does not match its metadata." }
        return base64url(bytes).also { decodeEnvelope(it) }
    }
    private fun upload(status: JSONObject): JSONObject {
        val pending = status.optJSONObject("pending") ?: return status
        val recordId = id(pending.getString("id"))
        val bytes = decodeEnvelope(pending.getString("envelope"))
        check(bytes.size.toLong() == number(pending, "bytes", 64, 1_048_576) && digest(bytes) == pending.getString("sha256")) { "Pending snapshot does not match its metadata." }
        var response = request(status, "PUT", root(status) + "/records/$recordId", bytes)
        if (response.code == 401) {
            ensureVault(status)
            response = request(status, "PUT", root(status) + "/records/$recordId", bytes)
        }
        val ack = metadata(response.success().json())
        check(ack.getString("id") == recordId && ack.getString("sha256") == pending.getString("sha256") && ack.getLong("bytes") == pending.getLong("bytes")) { "Upload acknowledgement does not match the pending snapshot." }
        return change("sync_complete", JSONObject().put("recordId", recordId).put("sequence", ack.getLong("sequence"))
            .put("sha256", ack.getString("sha256")).put("bytes", ack.getLong("bytes")))
    }
    private fun scan(initial: JSONObject): JSONObject {
        var status = initial
        var count = 0
        var mayCreate = true
        while (true) {
            val cursor = number(status, "cursor", 0, Long.MAX_VALUE)
            var response = request(status, "GET", root(status) + "/records?after=$cursor")
            if (response.code == 401 && mayCreate) {
                // A 401 could be OAuth failure OR an unknown/wrong-capability
                // vault. Prove account authentication before attempting creation.
                val me = http.request(origin, "GET", "/v1/me", mapOf("Authorization" to "Bearer ${access()}"), null).success().json()
                check(me.optString("sub").isNotBlank()) { "Sign in to sync again." }
                val body = JSONObject().put("id", id(status.getString("vaultId"))).put("token", status.getString("token"))
                val created = http.request(origin, "POST", "/v1/vaults", mapOf("Authorization" to "Bearer ${access()}", "Content-Type" to "application/json"), body.toString().toByteArray())
                if (created.code == 402) created.success()
                check(created.code == 201 || created.code == 409) { "The vault could not be registered (${created.code}). No remote vault was replaced." }
                // 409 is never permission to change the existing capability.
                response = request(status, "GET", root(status) + "/records?after=$cursor")
            }
            mayCreate = false
            val page = response.success().json()
            val records = page.getJSONArray("records")
            check(records.length() <= 100 && count + records.length() <= 10_000) { "Sync scan limit reached. Progress is retained; retry Sync now." }
            var expected = cursor
            // Validate the entire page/cursor before committing any of it.
            val entries = (0 until records.length()).map { metadata(records.getJSONObject(it)) }
            entries.forEach { entry ->
                check(expected < Long.MAX_VALUE && entry.getLong("sequence") == expected + 1) { "Noncontiguous sync history. No versions were selected." }
                expected++
            }
            check(number(page, "cursor", 0, Long.MAX_VALUE) == expected) { "Inconsistent sync cursor." }
            entries.forEach { entry ->
                status = change("sync_ingest", JSONObject().put("recordId", entry.getString("id")).put("envelope", envelope(status, entry))
                    .put("sequence", entry.getLong("sequence")).put("sha256", entry.getString("sha256")).put("bytes", entry.getLong("bytes")))
                check(status.getLong("cursor") == entry.getLong("sequence")) { "The core did not commit sync progress." }
            }
            count += entries.size
            if (entries.size < 100) return status
            check(count < 10_000) { "Sync scan limit reached. Progress is retained; retry Sync now." }
        }
    }
    fun run(): JSONObject {
        var current = status()
        // Existing pending uploads have priority, including after process death.
        // Only a 401 triggers a registration probe; never scan/ingest over an
        // unacknowledged outbox, including a saved conflict resolution.
        if (current.optJSONObject("pending") != null) {
            current = upload(current)
        }
        repeat(3) {
            current = scan(current)
            if (current.getBoolean("conflict")) return current
            val heads = current.getJSONArray("heads")
            if (!current.getBoolean("dirty") && current.optJSONObject("pending") == null) {
                if (heads.length() == 1) {
                    val head = heads.getJSONObject(0)
                    current = change("sync_adopt", JSONObject().put("recordId", id(head.getString("id"))).put("envelope", envelope(current, head)))
                }
                return current
            }
            current = change("sync_prepare") // Persist exact immutable envelope BEFORE HTTP.
            current = upload(current)
            // Scan again: upload completion deliberately does not advance cursor.
        }
        error("Sync paused after concurrent changes. Progress is retained; tap Sync now again.")
    }
    private fun ensureVault(status: JSONObject) {
        // Probe only; do not consume/advance scan metadata ahead of pending upload.
        val response = request(status, "GET", root(status) + "/records?after=${status.getLong("cursor")}")
        if (response.code != 401) { response.success(); return }
        val me = http.request(origin, "GET", "/v1/me", mapOf("Authorization" to "Bearer ${access()}"), null).success().json()
        check(me.optString("sub").isNotBlank()) { "Sign in to sync again." }
        val body = JSONObject().put("id", id(status.getString("vaultId"))).put("token", status.getString("token"))
        val created = http.request(origin, "POST", "/v1/vaults", mapOf("Authorization" to "Bearer ${access()}", "Content-Type" to "application/json"), body.toString().toByteArray())
        if (created.code == 402) created.success()
        check(created.code == 201 || created.code == 409) { "The vault could not be registered (${created.code})." }
        request(status, "GET", root(status) + "/records?after=${status.getLong("cursor")}").success()
    }
    fun resolve(choice: String, selected: String?, displayedHeads: List<String>): JSONObject {
        val initial = status()
        check(initial.optJSONObject("pending") == null) { "Retry the pending resolution with Sync now before choosing another version." }
        val current = scan(initial)
        val currentHeads = current.getJSONArray("heads").let { array -> (0 until array.length()).map { array.getJSONObject(it).getString("id") }.sorted() }
        check(currentHeads == displayedHeads.sorted()) { "Other encrypted versions arrived. Review the updated version IDs and choose again." }
        check(current.getBoolean("conflict")) { "The conflict changed. Sync again before choosing a version." }
        val arguments = JSONObject().put("choice", choice)
        if (choice == "remote") {
            val heads = current.getJSONArray("heads")
            val head = (0 until heads.length()).map { heads.getJSONObject(it) }.firstOrNull { it.getString("id") == selected }
                ?: error("Select a known encrypted version.")
            arguments.put("recordId", id(head.getString("id"))).put("envelope", envelope(current, head))
        } else check(choice == "local") { "Invalid sync choice." }
        change("sync_resolve", arguments) // Resolution outbox is durable even if subsequent HTTP fails.
        return run()
    }
}
