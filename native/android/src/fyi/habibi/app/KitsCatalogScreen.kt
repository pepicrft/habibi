package fyi.habibi.app

import android.content.Context
import android.content.res.ColorStateList
import android.text.InputType
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.widget.doAfterTextChanged
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import com.google.android.material.shape.MaterialShapeDrawable
import com.google.android.material.shape.ShapeAppearanceModel
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout

/** Keep the search view attached while typing and during session/polling updates. */
internal class KitsCatalogScreen(
    private val context: Context,
    private val session: HabibiSession,
    initialQuery: String,
    initialFilter: String,
    private val selection: (String, String) -> Unit,
    private val openGitHub: () -> Unit,
    private val openPersonal: (String) -> Unit,
    private val design: () -> Unit,
) {
    private var query = initialQuery
    private var filter = initialFilter
    private val chips = ChipGroup(context).apply { isSingleLine = true; isSingleSelection = true; isSelectionRequired = true }
    private val results = context.column(0).apply { tag = "kits_results" }
    private val connected = filterChip("0 connected", "kits_connected", "connected")
    private val create = context.kitTextButton("Design a kit with Habibi", "design_kit", design)
    private val content = context.column().apply {
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            addView(context.heading("Your kits"), LinearLayout.LayoutParams(0, -2, 1f))
            addView(connected)
        })
        addView(context.label("Connect a service or make a personal Kit. Saved local entries stay private.", 15f, true))
        addView(TextInputLayout(context).apply {
            isHintEnabled = false
            boxBackgroundMode = TextInputLayout.BOX_BACKGROUND_NONE
            background = MaterialShapeDrawable(ShapeAppearanceModel.builder().setAllCornerSizes(context.dp(28).toFloat()).build()).apply {
                fillColor = ColorStateList.valueOf(ColorUtils.blendARGB(context.color(R.color.paper), context.color(R.color.ink), .08f))
            }
            setStartIconDrawable(com.google.android.material.R.drawable.ic_search_black_24)
            setStartIconTintList(ColorStateList.valueOf(context.color(R.color.secondary)))
            endIconMode = TextInputLayout.END_ICON_CLEAR_TEXT
            setEndIconTintList(ColorStateList.valueOf(context.color(R.color.secondary)))
            addView(TextInputEditText(context).apply {
                tag = "kits_search"; hint = "Search kits"; contentDescription = "Search kits"; setText(query)
                setTextColor(context.color(R.color.ink)); setHintTextColor(context.color(R.color.secondary))
                background = null; minimumHeight = context.dp(56); isSingleLine = true
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
                isSaveEnabled = false
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                imeOptions = EditorInfo.IME_ACTION_SEARCH or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
                setOnEditorActionListener { _, action, _ ->
                    if (action == EditorInfo.IME_ACTION_SEARCH) {
                        (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(windowToken, 0)
                        clearFocus(); true
                    } else false
                }
                doAfterTextChanged {
                    query = it.toString(); selection(query, filter)
                    renderResults() // Never replace the focused editor.
                }
            }, LinearLayout.LayoutParams(-1, -2))
            layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = context.dp(16); bottomMargin = context.dp(12) }
        })
        addView(HorizontalScrollView(context).apply {
            isHorizontalScrollBarEnabled = false
            addView(chips)
        })
        addView(results)
        addView(create)
    }
    val view = context.scroll(content)
    private var signature: List<Any?>? = null

    private fun select(value: String) {
        filter = value
        selection(query, filter); renderFilters(); renderResults()
    }

    private fun filterChip(title: String, identifier: String, value: String) = Chip(context).apply {
        id = View.generateViewId(); text = title; tag = identifier
        isCheckable = true; isCheckedIconVisible = true
        setCheckedIconResource(com.google.android.material.R.drawable.ic_m3_chip_check)
        setEnsureMinTouchTargetSize(true)
        chipBackgroundColor = ColorStateList(arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
            intArrayOf(context.color(R.color.accent), android.graphics.Color.TRANSPARENT))
        chipStrokeColor = ColorStateList.valueOf(context.color(R.color.outline))
        setTextColor(context.color(R.color.ink)); checkedIconTint = ColorStateList.valueOf(context.color(R.color.ink))
        setOnClickListener { select(value) }
    }

    private fun renderFilters() {
        chips.removeAllViews()
        for ((value, title) in listOf("all" to "All", "connections" to "Connections", "personal" to "Personal")) {
            chips.addView(filterChip(title, "kits_filter_$value", value).apply {
                isChecked = filter == value; isSelected = filter == value
                ViewCompat.setStateDescription(this, if (filter == value) "Selected" else "Not selected")
            })
        }
        connected.isChecked = filter == "connected"; connected.isSelected = filter == "connected"
        ViewCompat.setStateDescription(connected, if (connected.isSelected) "Showing connected services" else "Show connected services")
    }

    fun render() {
        val next = listOf(session.bundledKits.toString(), session.state?.optJSONArray("kits")?.toString(),
            session.githubAccount, session.busy, session.loaded, session.canSwitchConversation, session.syncing)
        if (next == signature) return
        signature = next
        connected.text = "${if (hasGitHub() && session.githubAccount?.expired == false) 1 else 0} connected"
        create.isEnabled = session.loaded && session.canSwitchConversation && !session.syncing
        renderFilters(); renderResults()
    }

    private fun hasGitHub() = (0 until session.bundledKits.length()).any { session.bundledKits.getJSONObject(it).optString("id") == "github" }
    private fun matches(name: String, description: String) = query.trim().let { it.isEmpty() || "$name $description".contains(it, ignoreCase = true) }

    private fun renderResults() {
        results.removeAllViews()
        var count = 0
        val description = "Read your profile and up to 10 recently updated public repositories."
        if (filter != "personal" && hasGitHub() && matches("GitHub", description) &&
            (filter != "connected" || session.githubAccount?.expired == false)) {
            val account = session.githubAccount
            results.addView(context.heading(if (filter == "connected") "Connected services" else "Connections", 18f))
            results.addView(row("GitHub", description, when {
                account == null -> "Connect"
                account.expired -> "Reconnect"
                else -> "Manage"
            }, "bundled_github", true, openGitHub))
            count++
        }
        val kits = session.state?.optJSONArray("kits")
        if (filter in setOf("all", "personal") && kits != null) {
            if (kits.length() == 0 && query.isBlank() && count > 0) {
                results.addView(context.heading("Personal", 18f))
                results.addView(context.label("No kits yet. Design a personal Kit with Habibi, test it with synthetic entries, then review it before saving.", 15f, true))
            }
            var personalHeading = false
            for (index in 0 until kits.length()) {
                val item = kits.getJSONObject(index); val definition = item.getJSONObject("definition")
                val name = definition.getString("name"); val detail = definition.optString("description")
                if (!matches(name, detail)) continue
                if (!personalHeading) { results.addView(context.heading("Personal", 18f)); personalHeading = true }
                results.addView(row(name, detail.ifBlank { "A personal Kit with ${item.getJSONArray("entries").length()} saved entries." },
                    "Manage", "kit_${item.getString("id")}", false) { openPersonal(item.getString("id")) })
                count++
            }
        }
        if (count == 0) results.addView(context.label(when {
            query.isNotBlank() -> "No kits match your search. Try a different name or description."
            filter == "connected" -> "No connected services. Connect GitHub to see it here; expired connections need reconnecting."
            filter == "connections" -> "No bundled connections available in this build."
            else -> "No kits yet. Design a personal Kit with Habibi, test it with synthetic entries, then review it before saving."
        }, 15f, true).apply { tag = "kits_empty"; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE })
    }

    private fun row(name: String, description: String, action: String, identifier: String, github: Boolean, open: () -> Unit): View =
        LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, context.dp(14), 0, context.dp(14))
            addView(context.kitIcon(github))
            addView(context.column(0).apply {
                setPadding(context.dp(12), 0, context.dp(8), 0)
                addView(context.heading(name, 16f))
                addView(context.label(description, 14f, true).apply {
                    if (resources.configuration.fontScale < 1.3f) { maxLines = 3; ellipsize = TextUtils.TruncateAt.END }
                })
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(context.kitTextButton(action, identifier, open).apply {
                contentDescription = "$action $name"
                isEnabled = session.loaded && !session.busy
            })
        }
}
