package fyi.habibi.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import org.json.JSONObject

/** Native review surfaces. Skins contain guidance and optional data-only geometry. */
internal class CostumesScreen(
    private val activity: MainActivity,
    private val session: HabibiSession,
    private val wear: (JSONObject, String) -> Unit,
    private val importFile: () -> Unit,
    private val exportFile: (JSONObject) -> Unit,
) {
    private val content = activity.column()
    val view = activity.scroll(content)
    private var detail: AlertDialog? = null
    private var editor: AlertDialog? = null
    private var editorStatus: TextView? = null

    fun render() {
        editorStatus?.text = session.error.orEmpty()
        editor?.getButton(AlertDialog.BUTTON_POSITIVE)?.isEnabled = session.canChangeCostume
        content.removeAllViews()
        content.addView(activity.heading("Skins"))
        content.addView(activity.heartling("costumes_heartling"))
        content.addView(activity.heading("Still your Habibi.", 22f))
        content.addView(activity.label("Different ways to help. Try on a skin, then keep the ones that feel like you.", 16f, true))
        content.addView(activity.heading("Your wardrobe", 22f))
        if (session.wardrobe.isEmpty()) content.addView(activity.label("Your wardrobe is ready for its first skin.", 16f, true))
        session.wardrobe.forEach { costume ->
            row(costume.getJSONObject("definition"), "saved_${costume.getString("id")}") { showDetail(costume.getJSONObject("definition"), costume.getString("id")) }
        }
        content.addView(activity.heading("Try something on", 22f))
        try {
            session.bundledCostumes().forEach { definition -> row(definition, "bundled_${definition.getString("name")}") { showDetail(definition) } }
        } catch (cause: Exception) { content.addView(activity.label(cause.message ?: "Could not load skins.")) }
        content.addView(activity.button("Make a skin", "costumes_create") {
            edit(JSONObject().put("apiVersion", 1).put("name", "").put("description", "").put("author", session.state!!.getJSONObject("profile").getString("name"))
                .put("instructions", "").put("examplePrompt", ""))
        })
        content.addView(activity.button("Import a skin", "costumes_import", action = importFile))
        content.addView(activity.label("Skins change Habibi’s approach, never its permissions. Your wardrobe is encrypted with your vault.", 14f, true))
    }

    private fun row(definition: JSONObject, id: String, open: () -> Unit) {
        content.addView(activity.card().apply {
            addView(activity.heartling("costumes_${id}_avatar").apply {
                avatar = definition.optJSONObject("avatar")
                layoutParams.width = activity.dp(72); layoutParams.height = activity.dp(72)
            })
            addView(activity.heading(definition.getString("name"), 20f))
            addView(activity.label(definition.getString("description"), 16f, true))
            addView(activity.label("By ${definition.getString("author")} · Author supplied", 13f, true))
            addView(activity.button("Explore skin", "costumes_$id", action = open))
        })
    }

    private fun showDetail(definition: JSONObject, id: String? = null) {
        detail?.dismiss()
        val body = activity.column().apply {
            addView(activity.heartling("costumes_detail_avatar").apply { avatar = definition.optJSONObject("avatar") })
            addView(activity.label(definition.getString("description")))
            addView(activity.label("By ${definition.getString("author")} · Author supplied, not verified", 14f, true))
            addView(activity.heading("How Habibi will help", 20f))
            addView(activity.label(definition.getString("instructions")))
            addView(activity.heading("Give it a try", 20f))
            addView(activity.label(definition.getString("examplePrompt"), 16f, true))
            addView(activity.button("Try on", "costumes_try") {
                if (session.canChangeCostume) { detail?.dismiss(); wear(definition, definition.getString("examplePrompt")) }
            }.apply { isEnabled = session.canChangeCostume })
            addView(activity.label("Opens a separate conversation with an editable example. Nothing is sent until you tap Send; trying on does not add it to your wardrobe.", 14f, true))
            if (id != null) {
                addView(activity.button("Wear", "costumes_wear", true) {
                    if (session.canChangeCostume) { detail?.dismiss(); wear(definition, "") }
                }.apply { isEnabled = session.canChangeCostume })
                addView(activity.button("Edit skin", "costumes_edit") { detail?.dismiss(); edit(definition, id) })
                addView(activity.button("Export skin", "costumes_export") { exportFile(definition) })
                addView(activity.label("Exports the definition only, not conversations or memories. Review its text for personal information before sharing.", 14f, true))
                addView(activity.button("Remove from wardrobe", "costumes_remove") {
                    MaterialAlertDialogBuilder(activity).setTitle("Remove this skin?")
                        .setMessage("Conversations keep their own copy. No messages or memories are removed.")
                        .setNegativeButton("Cancel", null).setPositiveButton("Remove") { _, _ ->
                            session.removeCostume(id) { detail?.dismiss() }
                        }.show()
                })
            } else {
                addView(activity.button("Add to wardrobe", "costumes_add", true) { detail?.dismiss(); edit(definition) })
            }
            addView(activity.label("Only the selected name and instructions go to your model. Skins cannot grant tools or data access. Existing conversations keep their own copy after edits or removal.", 14f, true))
        }
        detail = MaterialAlertDialogBuilder(activity).setTitle(definition.getString("name"))
            .setView(activity.scroll(body)).setNegativeButton("Close", null).create().also { it.show() }
    }

    fun edit(definition: JSONObject, id: String? = null) {
        editor?.dismiss()
        val body = activity.column()
        val fields = listOf(
            "name" to "Name (60 characters)", "description" to "Short description (300 characters)",
            "author" to "Author (not verified)", "instructions" to "How Habibi should help (4,000 characters)",
            "examplePrompt" to "Example to try on (500 characters)",
        ).associate { (key, label) ->
            val (box, field) = activity.input(label, "costumes_$key", definition.getString(key), key in listOf("instructions", "examplePrompt", "description"))
            body.addView(box); key to field
        }
        body.addView(activity.heading("Avatar", 20f))
        val preview = activity.heartling("costumes_preview_avatar").apply { avatar = definition.optJSONObject("avatar") }
        body.addView(preview)
        body.addView(activity.button("Copy avatar prompt", "costumes_avatar_prompt") {
            val prompt = """
                Design an original small object character for my Habibi skin, based on its role below.
                Return only JSON: {"body":{"path":"..."},"eyes":{"x":50,"y":50,"spacing":18,"scale":1}}.
                Draw a soft, chunky silhouette in a 100 × 100 square, with generous padding. No text, eyes, colors, SVG markup or code in the path. Habibi adds theme color, eyes, blinking and motion natively.
                Use ONLY explicit uppercase M, L, Q, C and Z commands. Separate EVERY command and number with spaces. M/L take 2 numbers, Q takes 4, C takes 6, Z takes none. Start every subpath with M and close it with Z. Use ordinary decimal coordinates from 0 to 100, no exponents; keep the path under 4,096 bytes and 768 tokens.
                Place both eyes well inside the silhouette. x/y: 15–85, spacing: 8–36, scale: 0.5–1.5. No URLs, external assets or extra fields.
                Skin role:
                ${fields.getValue("name").text}: ${fields.getValue("description").text}
            """.trimIndent()
            (activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Avatar prompt", prompt))
        })
        body.addView(activity.label("Use the prompt in your chosen chat model, then paste its JSON below. Only the skin’s name and description are copied. Leave blank to keep Heartling.", 14f, true))
        val (avatarBox, avatarField) = activity.input("Avatar geometry (JSON)", "costumes_avatar", definition.optJSONObject("avatar")?.toString(2).orEmpty(), true)
        body.addView(avatarBox)
        fun candidate(): JSONObject {
            val value = JSONObject().put("apiVersion", 1)
            fields.forEach { (key, field) -> value.put(key, field.text.toString()) }
            val raw = avatarField.text.toString().trim()
            if (raw.isNotEmpty()) value.put("avatar", JSONObject(raw))
            return session.validateCostume(value)
        }
        body.addView(activity.button("Preview skin", "costumes_preview") {
            try { preview.avatar = candidate().optJSONObject("avatar"); editorStatus?.text = "" }
            catch (cause: Exception) { editorStatus?.text = cause.message ?: "Check the skin fields." }
        })
        body.addView(activity.label("Complete the skin’s text before previewing. Artwork is geometry only, never code or remote images. Preview or Save validates it; clearing the JSON removes it.", 14f, true))
        body.addView(activity.label("Review every field before adding an imported skin. Author names are not verified. The selected name and instructions go to your chosen model when you send a message. Never put secrets here. No code, tools or permissions.", 14f, true))
        editorStatus = activity.label("", 14f).also { body.addView(it) }
        editor = MaterialAlertDialogBuilder(activity).setTitle(if (id == null) "Add to wardrobe" else "Edit skin")
            .setView(activity.scroll(body)).setNegativeButton("Cancel", null).setPositiveButton(if (id == null) "Add" else "Save", null)
            .create().also { dialog ->
                dialog.setOnDismissListener { editorStatus = null; editor = null }
                dialog.show()
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                    try {
                        session.saveCostume(candidate(), id) { dialog.dismiss() }
                    } catch (cause: Exception) { editorStatus?.text = cause.message ?: "Check the skin fields." }
                }
            }
    }

    fun close() { detail?.dismiss(); editor?.dismiss() }
}
