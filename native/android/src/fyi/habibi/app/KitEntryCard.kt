package fyi.habibi.app

import android.content.Context
import android.text.InputFilter
import android.text.InputType
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate

/** Model data can identify an installed Kit and suggest context, never a form
 * schema. Private edits are ephemeral until the explicit local save action. */
internal class KitEntryCard(
    context: Context,
    private val session: HabibiSession,
    private val conversationId: String,
    private val messageId: String,
    private val component: JSONObject,
) : FrameLayout(context) {
    private data class Input(val field: JSONObject, val box: TextInputLayout, val edit: TextInputEditText)
    private val inputs = linkedMapOf<String, Input>()
    private var save: MaterialButton? = null
    private var status: TextView? = null
    private var receipt: String? = null
    private var rendered: List<String?>? = null

    fun render(line: ChatLine) {
        val data = component.optJSONObject("data")
        val kits = session.state?.optJSONArray("kits") ?: JSONArray()
        val kit = (0 until kits.length()).map { kits.getJSONObject(it) }.firstOrNull { it.optString("id") == data?.optString("kitId") }
        val entries = kit?.optJSONArray("entries") ?: JSONArray()
        val entry = line.entryId?.let { id -> (0 until entries.length()).map { entries.getJSONObject(it) }.firstOrNull { it.optString("id") == id } }
        val key = listOf(kit?.optJSONObject("definition")?.toString(), line.entryId, entry?.toString())
        if (rendered != key) {
            rendered = key; receipt = line.entryId
            removeAllViews(); inputs.clear(); save = null; status = null
            val body = context.card()
            addView(body, LayoutParams(-1, -2))
            try {
                require(component.getString("type") == "kit_entry" && component.getInt("version") == 1)
                val actions = component.getJSONArray("actions")
                require(actions.length() == 1 && actions.getJSONObject(0).getString("id") == "save_entry")
                val definition = requireNotNull(kit).getJSONObject("definition")
                val fields = definition.getJSONArray("fields")
                require(fields.length() in 1..12)
                val declared = (0 until fields.length()).associate { index -> fields.getJSONObject(index).let { it.getString("key") to it } }
                val prefill = requireNotNull(data).getJSONArray("prefill")
                require(prefill.length() <= 12)
                val defaults = linkedMapOf<String, Any>()
                for (index in 0 until prefill.length()) {
                    val item = prefill.getJSONObject(index); val name = item.getString("key")
                    require(item.keys().asSequence().toSet() == setOf("key", "value") && !defaults.containsKey(name))
                    val field = requireNotNull(declared[name]); val value = item.get("value")
                    require(validValue(field, value)); defaults[name] = value
                }
                val stored = if (receipt != null) requireNotNull(entry).getJSONObject("values") else null
                body.addView(context.heading(data.getString("title"), 20f))
                body.addView(context.label(definition.getString("name"), 14f, true))
                body.addView(context.label(if (stored != null) "Saved on this device. These are the stored entry values."
                    else "Edit the context and fill in your entry. Values stay private, never sent to the agent. Unsaved fields reset when this card closes.", 14f, true))
                declared.forEach { (name, field) ->
                    val unit = field.optString("unit").takeIf { it.isNotBlank() }
                    val label = field.getString("label") + unit?.let { " ($it)" }.orEmpty()
                    val value = stored?.get(name) ?: defaults[name] ?: if (field.getString("type") == "date") LocalDate.now().toString() else ""
                    if (stored != null) require(validValue(field, value))
                    val (box, edit) = context.input(label, "kit_entry_${messageId}_$name", value.toString())
                    when (field.getString("type")) {
                        "number" -> {
                            edit.inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED
                            box.helperText = listOfNotNull(field.opt("min")?.takeUnless { it == JSONObject.NULL }?.let { "Minimum $it" },
                                field.opt("max")?.takeUnless { it == JSONObject.NULL }?.let { "Maximum $it" }).joinToString(" · ")
                        }
                        "date" -> { edit.inputType = InputType.TYPE_CLASS_DATETIME or InputType.TYPE_DATETIME_VARIATION_DATE; box.helperText = "YYYY-MM-DD · Local calendar date" }
                        "text" -> edit.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                        else -> error("Unsupported installed field")
                    }
                    edit.filters = arrayOf(InputFilter.LengthFilter(if (field.getString("type") == "text") 500 else 32))
                    inputs[name] = Input(field, box, edit); body.addView(box)
                }
                status = context.label(if (stored != null) "Saved entry · Editing is disabled." else "Not saved yet.", 14f, true).apply {
                    tag = "kit_entry_status_$messageId"; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
                }.also(body::addView)
                save = context.button("Save entry", "kit_entry_save_$messageId", true) {
                    if (receipt == null && session.canSubmitKitEntry) submit()
                }.also(body::addView)
            } catch (_: Exception) {
                inputs.clear(); save = null; status = null; body.removeAllViews()
                body.addView(context.label(component.optString("fallback", "Kit entry")))
                body.addView(context.label(if (receipt != null) "Saved entry unavailable. The original Kit or entry is no longer available on this device."
                    else "Kit entry unavailable. The installed Kit or suggested values cannot be used. Nothing was saved from this card.", 14f, true))
            }
        }
        val enabled = receipt == null && session.canSubmitKitEntry
        inputs.values.forEach { it.edit.isEnabled = enabled }
        save?.isEnabled = enabled
    }

    private fun submit() {
        val values = JSONObject()
        var firstInvalid: TextInputEditText? = null
        inputs.forEach { (key, input) ->
            val text = input.edit.text.toString().trim()
            val value: Any? = if (input.field.getString("type") == "number") text.toDoubleOrNull() else text
            val valid = value != null && validValue(input.field, value)
            input.box.error = if (valid) null else "Check ${input.field.getString("label")} and its allowed values."
            if (valid) values.put(key, value) else if (firstInvalid == null) firstInvalid = input.edit
        }
        if (firstInvalid != null) { firstInvalid?.requestFocus(); status?.text = "Check the highlighted fields. Nothing was saved."; return }
        session.submitKitEntry(conversationId, messageId, values)
    }

    private fun validValue(field: JSONObject, value: Any): Boolean = when (field.getString("type")) {
        "text" -> value is String && value.isNotBlank() && value.codePointCount(0, value.length) <= 500 && value.none { it.isISOControl() && it != '\n' }
        "date" -> value is String && value.matches(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")) &&
            runCatching { LocalDate.parse(value).year in 1..9999 }.getOrDefault(false)
        "number" -> value is Number && value.toDouble().let { number -> number.isFinite() && kotlin.math.abs(number) <= 1e9 &&
            (field.isNull("min") || number >= field.getDouble("min")) && (field.isNull("max") || number <= field.getDouble("max")) }
        else -> false
    }
}
