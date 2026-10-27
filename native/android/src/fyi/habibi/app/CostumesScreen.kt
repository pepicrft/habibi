package fyi.habibi.app

import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import org.json.JSONObject

/** Native review surfaces. A costume is text guidance, never a tool or renderer. */
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
        content.addView(activity.heading("Costumes"))
        content.addView(activity.heartling("costumes_heartling"))
        content.addView(activity.heading("Still your Habibi.", 22f))
        content.addView(activity.label("Different ways to help. Try on a costume, then keep the ones that feel like you.", 16f, true))
        content.addView(activity.heading("Your wardrobe", 22f))
        if (session.wardrobe.isEmpty()) content.addView(activity.label("Your wardrobe is ready for its first costume.", 16f, true))
        session.wardrobe.forEach { costume ->
            row(costume.getJSONObject("definition"), "saved_${costume.getString("id")}") { showDetail(costume.getJSONObject("definition"), costume.getString("id")) }
        }
        content.addView(activity.heading("Try something on", 22f))
        try {
            session.bundledCostumes().forEach { definition -> row(definition, "bundled_${definition.getString("name")}") { showDetail(definition) } }
        } catch (cause: Exception) { content.addView(activity.label(cause.message ?: "Could not load costumes.")) }
        content.addView(activity.button("Make a costume", "costumes_create") {
            edit(JSONObject().put("apiVersion", 1).put("name", "").put("description", "").put("author", session.state!!.getJSONObject("profile").getString("name"))
                .put("instructions", "").put("examplePrompt", ""))
        })
        content.addView(activity.button("Import a costume", "costumes_import", action = importFile))
        content.addView(activity.label("Costumes change Habibi’s approach, never its permissions. Your wardrobe is encrypted with your vault.", 14f, true))
    }

    private fun row(definition: JSONObject, id: String, open: () -> Unit) {
        content.addView(activity.card().apply {
            addView(activity.heading(definition.getString("name"), 20f))
            addView(activity.label(definition.getString("description"), 16f, true))
            addView(activity.label("By ${definition.getString("author")} · Author supplied", 13f, true))
            addView(activity.button("Explore costume", "costumes_$id", action = open))
        })
    }

    private fun showDetail(definition: JSONObject, id: String? = null) {
        detail?.dismiss()
        val body = activity.column().apply {
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
                addView(activity.button("Edit costume", "costumes_edit") { detail?.dismiss(); edit(definition, id) })
                addView(activity.button("Export costume", "costumes_export") { exportFile(definition) })
                addView(activity.label("Exports the definition only, not conversations or memories. Review its text for personal information before sharing.", 14f, true))
                addView(activity.button("Remove from wardrobe", "costumes_remove") {
                    MaterialAlertDialogBuilder(activity).setTitle("Remove this costume?")
                        .setMessage("Conversations keep their own copy. No messages or memories are removed.")
                        .setNegativeButton("Cancel", null).setPositiveButton("Remove") { _, _ ->
                            session.removeCostume(id) { detail?.dismiss() }
                        }.show()
                })
            } else {
                addView(activity.button("Add to wardrobe", "costumes_add", true) { detail?.dismiss(); edit(definition) })
            }
            addView(activity.label("Only the selected name and instructions go to your model. Costumes cannot grant tools or data access. Existing conversations keep their own copy after edits or removal.", 14f, true))
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
        body.addView(activity.label("Review every field before adding an imported costume. Author names are not verified. The selected name and instructions go to your chosen model when you send a message. Never put secrets here. No code, tools or permissions.", 14f, true))
        editorStatus = activity.label("", 14f).also { body.addView(it) }
        editor = MaterialAlertDialogBuilder(activity).setTitle(if (id == null) "Add to wardrobe" else "Edit costume")
            .setView(activity.scroll(body)).setNegativeButton("Cancel", null).setPositiveButton(if (id == null) "Add" else "Save", null)
            .create().also { dialog ->
                dialog.setOnDismissListener { editorStatus = null; editor = null }
                dialog.show()
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                    try {
                        val candidate = JSONObject().put("apiVersion", 1)
                        fields.forEach { (key, field) -> candidate.put(key, field.text.toString()) }
                        session.saveCostume(session.validateCostume(candidate), id) { dialog.dismiss() }
                    } catch (cause: Exception) { editorStatus?.text = cause.message ?: "Check the costume fields." }
                }
            }
    }

    fun close() { detail?.dismiss(); editor?.dismiss() }
}
