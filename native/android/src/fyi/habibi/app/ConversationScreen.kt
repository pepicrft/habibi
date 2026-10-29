package fyi.habibi.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.core.content.ContextCompat
import androidx.core.widget.doAfterTextChanged
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.textfield.TextInputEditText
import org.json.JSONObject

/** Atlas's independent transcript/composer and stable-ID prompt navigation,
 * adapted to Habibi's encrypted local archive and isolated inference context. */
internal class ConversationScreen(
    private val activity: MainActivity,
    private val session: HabibiSession,
    private val requestPermission: ((Boolean) -> Unit) -> Unit,
    private val send: (String) -> Unit,
    private val draftActions: (JSONObject) -> View,
) {
    private val chat = session.conversation
    val id = chat.id
    fun represents(conversation: Conversation) = chat === conversation
    private val context get() = activity
    private val transcript = context.column(20)
    private val messages = context.column(0)
    private val tools = context.column(0)
    private val emptyHeartling = context.heartling("conversation_heartling")
    private val welcome = context.label("", 14f, true)
    private val workingHeartling = HeartlingView(context, interactive = false).apply {
        tag = "working_heartling"; working = true
    }
    private val working = LinearLayout(context).apply {
        tag = "conversation_working"; gravity = Gravity.CENTER_VERTICAL
        visibility = View.GONE
        addView(workingHeartling, LinearLayout.LayoutParams(context.dp(40), context.dp(40)).apply { marginEnd = context.dp(8) })
        addView(context.label("Habibi is working…", 14f, true))
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }
    private val scroll = ScrollView(context).apply {
        tag = "conversation_transcript"; isFillViewport = true; isSaveEnabled = false
        // Focusing the pinned editor must never request a transcript scroll.
        descendantFocusability = android.view.ViewGroup.FOCUS_BEFORE_DESCENDANTS
        addView(transcript)
    }
    private val field = TextInputEditText(context).apply {
        tag = "conversation_message"; hint = "Message Habibi"; contentDescription = "Message Habibi"
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        minLines = 1; maxLines = 6; minimumHeight = context.dp(48)
        setPadding(context.dp(12), context.dp(12), context.dp(8), context.dp(12))
        background = null; setTextColor(context.color(R.color.ink)); setHintTextColor(context.color(R.color.secondary))
        isSaveEnabled = false; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        setText(chat.draft)
        setSelection(chat.selectionStart.coerceIn(0, text!!.length), chat.selectionEnd.coerceIn(0, text!!.length))
    }
    private fun control(title: String, tag: String, icon: Int, action: () -> Unit) = MaterialButton(context).apply {
        this.tag = tag; contentDescription = title
        setIconResource(icon); iconTint = ColorStateList.valueOf(context.color(R.color.ink))
        iconSize = context.dp(22); iconPadding = 0
        insetTop = 0; insetBottom = 0; cornerRadius = context.dp(24)
        backgroundTintList = ColorStateList.valueOf(context.color(R.color.accent))
        minWidth = 0; minimumWidth = 0; minHeight = 0; minimumHeight = 0
        setPadding(context.dp(13), 0, context.dp(13), 0)
        layoutParams = LinearLayout.LayoutParams(context.dp(48), context.dp(48)).apply { marginStart = context.dp(4) }
        setOnClickListener { action() }
    }
    private val microphone = control("Transcribe a voice message. Hold and release, or tap to start and stop. Nothing is sent automatically.", "voice_microphone", R.drawable.ic_mic) {
        if (voice.active) voice.stop() else voice.start()
    }
    private val submit = control("Send message", "send_message", R.drawable.ic_send) { send(field.text.toString().trim()) }
    private val discard = control("Discard dictation. Keeps your typed draft unchanged.", "voice_discard", R.drawable.ic_close) { voice.discard() }
    private val prompts = control("Conversation prompts", "conversation_prompts", R.drawable.ic_prompts) { showPrompts() }
    private val latest = context.button("↓ Latest", "conversation_latest") { jumpLatest() }.apply {
        layoutParams = LinearLayout.LayoutParams(-2, context.dp(48)); minimumHeight = context.dp(48); minHeight = context.dp(48)
    }
    private val stop = context.button("Stop reply", "stop_reply") { session.stop() }
    private val connection = context.label("", 13f, true)
    private val draftSyncStatus = context.label("", 13f, true).apply { tag = "draft_sync_status" }
    private val draftVersions = context.button("Other draft versions", "draft_versions") {
        val versions = session.otherDrafts
        if (versions.isNotEmpty()) MaterialAlertDialogBuilder(context)
            .setTitle("Other draft versions · Both stay saved")
            .setItems(versions.map { it.take(80) }.toTypedArray()) { _, index ->
                session.selectDraftVersion(versions[index]); render()
            }.setNegativeButton("Keep writing", null).show()
    }
    private val costume = context.button("Wear a skin", "conversation_costume") {
        if (session.canChangeCostume && costumeDialog == null) {
            val wardrobe = session.wardrobe
            val choices = listOf("Just Habibi · No skin") + wardrobe.map { it.getJSONObject("definition").getString("name") }
            costumeDialog = MaterialAlertDialogBuilder(context).setTitle("Wear a skin")
                .setItems(choices.toTypedArray()) { dialog, index ->
                    dialog.dismiss(); session.setConversationCostume(if (index == 0) null else wardrobe[index - 1].getJSONObject("definition"))
                }
                .setNegativeButton("Cancel", null).create().also { dialog ->
                    dialog.setOnDismissListener { costumeDialog = null }; dialog.show()
                }
        }
    }
    fun showModelPicker() {
        if (!session.canChangeModel || modelDialog != null) return
        val models = session.chatGPTModels.toMutableList()
        chat.modelOverride?.let { id -> if (models.none { it.first == id }) models.add(0, id to session.modelName(id)) }
        val choices = listOf("Use default · ${session.modelName(session.defaultModel)}") + models.map { it.second }
        val selected = chat.modelOverride?.let { id -> models.indexOfFirst { it.first == id } + 1 } ?: 0
        modelDialog = MaterialAlertDialogBuilder(context).setTitle("Conversation model")
            .setSingleChoiceItems(choices.toTypedArray(), selected) { dialog, index ->
                dialog.dismiss(); session.setConversationModel(if (index == 0) null else models[index - 1].first)
            }.setNegativeButton("Cancel", null).create().also { dialog ->
                dialog.setOnDismissListener { modelDialog = null }; dialog.show()
            }
    }
    private val status = context.label("", 13f, true).apply {
        tag = "voice_status"; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        setPadding(context.dp(8), context.dp(4), context.dp(8), context.dp(4))
    }
    private val waveform = VoiceWaveform(context).apply { tag = "voice_waveform"; visibility = View.GONE }
    private val fieldHost = FrameLayout(context).apply {
        addView(field, FrameLayout.LayoutParams(-1, -2))
        addView(waveform, FrameLayout.LayoutParams(-1, context.dp(48), Gravity.CENTER))
    }
    private val composer = LinearLayout(context).apply {
        tag = "conversation_composer"; gravity = Gravity.BOTTOM
        setPadding(context.dp(6), context.dp(6), context.dp(6), context.dp(6))
        background = GradientDrawable().apply {
            setColor(context.color(R.color.surface)); cornerRadius = context.dp(30).toFloat()
            setStroke(context.dp(1), context.color(R.color.outline))
        }
        // One microphone target stays alive and in place throughout a held gesture.
        addView(microphone); addView(fieldHost, LinearLayout.LayoutParams(0, -2, 1f)); addView(discard); addView(submit)
    }
    val view = context.column(0).apply {
        isSaveEnabled = false; isSaveFromParentEnabled = false
        addView(connection, LinearLayout.LayoutParams(-1, -2).apply { marginStart = context.dp(20); marginEnd = context.dp(20) })
        addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
        addView(LinearLayout(context).apply {
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            setPadding(context.dp(16), 0, context.dp(16), 0)
            addView(prompts); addView(latest)
        })
        addView(stop)
        addView(context.column(12).apply { addView(costume); addView(draftSyncStatus); addView(draftVersions); addView(composer); addView(status) })
    }
    private val voice: OnDeviceVoiceInput = OnDeviceVoiceInput(
        (activity.application as HabibiApplication).voiceRecognizerFactory?.invoke() ?: AndroidDeviceRecognizer(context),
        { ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED },
        requestPermission,
        { text ->
            if (!closed && session.conversation.id == id) {
                val value = field.text.toString()
                val joined = value + (if (value.isBlank() || value.last().isWhitespace()) "" else " ") + text
                field.setText(joined); field.setSelection(joined.length)
                status.announceForAccessibility("Dictation added to your draft. Review and send when ready.")
            }
        },
        { if (!closed) renderControls() },
    )
    private var closed = false
    private var inForeground = true
    private var syncing = false
    private var rendered = emptyList<ChatLine>()
    private var toolKey: List<Any?>? = null
    private val messageViews = mutableMapOf<String, View>()
    private val cards = mutableListOf<ThreadCardView>()
    private val entryCards = mutableMapOf<String, KitEntryCard>()
    private var promptDialog: AlertDialog? = null
    private var sourceDialog: AlertDialog? = null
    private var modelDialog: AlertDialog? = null
    private var costumeDialog: AlertDialog? = null
    private var scrollRevision = 0L
    private var restoring = true
    private var holding = false
    private var down = false
    private val touchHandler = Handler(Looper.getMainLooper())
    private val hold = Runnable {
        if (down && microphone.isEnabled) {
            holding = true
            if (voice.active) voice.stop() else voice.start()
        }
    }

    init {
        transcript.addView(emptyHeartling)
        transcript.addView(context.heading("Room to think", 24f))
        transcript.addView(welcome)
        transcript.addView(messages); transcript.addView(tools); transcript.addView(working)
        field.doAfterTextChanged {
            if (!syncing && !closed && session.conversation.id == id) session.conversationDraft = it.toString()
            renderControls()
        }
        scroll.setOnScrollChangeListener { _, _, y, _, old ->
            if (!restoring && y != old) {
                chat.scrollY = y
                chat.following = atBottom()
                scrollRevision++ // A reader gesture wins over any posted follow/jump.
                updateLatest()
            }
        }
        scroll.addOnLayoutChangeListener { _, _, _, _, bottom, _, _, _, oldBottom ->
            if (bottom != oldBottom && chat.following) followAfterLayout()
        }
        transcript.addOnLayoutChangeListener { _, _, _, _, bottom, _, _, _, oldBottom ->
            if (bottom != oldBottom && chat.following) followAfterLayout()
        }
        installMicrophoneGesture()
        render()
        val revision = scrollRevision
        scroll.post {
            if (!closed && revision == scrollRevision) {
                if (chat.following) scroll.scrollTo(0, bottomOffset()) else scroll.scrollTo(0, chat.scrollY)
            }
            restoring = false; updateLatest()
        }
    }
    private fun bottomOffset() = (transcript.height - scroll.height + scroll.paddingBottom).coerceAtLeast(0)
    private fun atBottom() = bottomOffset() - scroll.scrollY <= context.dp(32)
    private fun updateLatest() { latest.visibility = if (chat.following) View.GONE else View.VISIBLE }
    private fun followAfterLayout() {
        val revision = scrollRevision
        scroll.post { if (!closed && chat.following && revision == scrollRevision) scroll.scrollTo(0, bottomOffset()) }
    }
    private fun jumpLatest() { ++scrollRevision; chat.following = true; updateLatest(); followAfterLayout() }
    private fun showPrompts() {
        if (promptDialog != null) return
        val entries = chat.lines.filter { it.role == "You" }.asReversed()
        val builder = MaterialAlertDialogBuilder(context).setTitle("Prompts · newest first").setNegativeButton("Close", null)
        if (entries.isEmpty()) builder.setMessage("No prompts yet. Your messages will appear here.")
        else builder.setItems(entries.map { it.text.replace(Regex("\\s+"), " ").take(160) }.toTypedArray()) { _, position ->
            val targetId = entries[position].id
            chat.following = false; updateLatest()
            val revision = ++scrollRevision
            scroll.post {
                if (!closed && revision == scrollRevision && session.conversation.id == id) {
                    messageViews[targetId]?.let { target ->
                        // Stable message IDs, not list positions or prompt text.
                        scroll.scrollTo(0, messages.top + target.top)
                        scroll.announceForAccessibility("Jumped to prompt")
                    }
                }
            }
        }
        promptDialog = builder.create().also { dialog ->
            dialog.setOnDismissListener { promptDialog = null }; dialog.show()
        }
    }
    fun render() {
        if (closed) return
        emptyHeartling.visibility = if (chat.lines.isEmpty() && !session.chatting) View.VISIBLE else View.GONE
        working.visibility = if (session.chatting) View.VISIBLE else View.GONE
        welcome.text = chat.costume?.getString("description")
            ?: "Design a kit, try synthetic examples, and review every Kit change. Conversations, cards and drafts save locally in your encrypted vault. Unsent edits save after a short pause."
        costume.text = chat.costume?.let { "Wearing ${it.getString("name")}" } ?: "Wear a skin"
        costume.contentDescription = costume.text
        costume.isEnabled = session.canChangeCostume
        connection.text = if (session.connected) "${session.inferenceName} · Messages and requested tool results go to your provider. Keys, profile and saved entries stay here."
        else if (session.usesAppleModel) "Apple’s on-device model is available only on supported Apple devices. Choose a ChatGPT model from the conversation menu."
        else "Not connected · Connect ChatGPT in Profile → AI provider. You can still write a draft or dictate on this device."
        if (field.text.toString() != chat.draft) {
            // Only canonical clears/recovery can differ: state updates never replace the editor.
            syncing = true; field.setText(chat.draft); field.setSelection(field.text!!.length); syncing = false
        }
        if (rendered != chat.lines) {
            val added = chat.lines.drop(rendered.size)
            added.forEach { line ->
                val row = context.column(0).apply {
                    tag = "message_${line.id}"
                    setPadding(0, context.dp(14), 0, context.dp(14))
                    addView(context.heading(line.role, 14f))
                    if (line.component == null) addView(context.label(line.text).apply { setTextIsSelectable(true) })
                    else if (JSONObject(line.component).optString("type") == "kit_entry") {
                        addView(KitEntryCard(context, session, this@ConversationScreen.id, line.id, JSONObject(line.component)).also { entryCards[line.id] = it })
                    }
                    else addView(ThreadCardView(context, JSONObject(line.component)) { action ->
                        session.componentSource(this@ConversationScreen.id, line.id, action) { data ->
                            if (!closed && inForeground && session.conversation.id == this@ConversationScreen.id && view.isAttachedToWindow) {
                                sourceDialog?.dismiss()
                                sourceDialog = MaterialAlertDialogBuilder(context).setTitle("Card data · ${data.optString("title")}")
                                    .setView(context.scroll(context.column().apply {
                                        addView(context.label(data.toString(2), 14f).apply { setTextIsSelectable(true) })
                                    })).setPositiveButton("Done", null).show()
                            }
                        }
                    }.also { cards.add(it) })
                    if (line.role == "You") addView(context.label("", 20f).apply {
                        tag = "reaction_${line.id}"
                        visibility = View.GONE
                        setPadding(context.dp(10), context.dp(4), context.dp(10), context.dp(4))
                        background = GradientDrawable().apply {
                            setColor(context.color(R.color.surface)); cornerRadius = context.dp(20).toFloat()
                            setStroke(context.dp(1), context.color(R.color.outline))
                        }
                        layoutParams = LinearLayout.LayoutParams(-2, -2).apply { topMargin = context.dp(4) }
                        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
                    })
                }
                messageViews[line.id] = row; messages.addView(row)
            }
            rendered = chat.lines
            if (chat.following) followAfterLayout()
        }
        // Receipts update existing messages without appending a line or
        // rebuilding other native editors or NSH result-table renderers.
        chat.lines.forEach { line ->
            entryCards[line.id]?.render(line)
            messageViews[line.id]?.findViewWithTag<TextView>("reaction_${line.id}")?.apply {
                text = line.reaction.orEmpty()
                contentDescription = "Habibi reacted ${line.reaction.orEmpty()}"
                visibility = if (line.reaction == null) View.GONE else View.VISIBLE
            }
        }
        val key = listOf(chat.definition?.toString(), chat.toolResult, session.busy, session.chatting, session.review?.ticket)
        if (key != toolKey) {
            toolKey = key; tools.removeAllViews()
            chat.definition?.let { tools.addView(draftActions(it)) }
            chat.toolResult?.let { tools.addView(context.card().apply {
                addView(context.heading("Latest local tool result", 18f)); addView(context.label(it, 14f).apply { setTextIsSelectable(true) })
            }) }
            if (chat.following) followAfterLayout()
        }
        renderControls()
    }
    private fun renderControls() {
        val active = voice.active
        draftSyncStatus.text = session.draftSyncMessage
        draftVersions.visibility = if (session.otherDrafts.isEmpty()) View.GONE else View.VISIBLE
        draftVersions.text = "Other draft versions (${session.otherDrafts.size})"
        field.isEnabled = !session.syncing
        submit.visibility = if (active) View.GONE else View.VISIBLE
        discard.visibility = if (active) View.VISIBLE else View.GONE
        submit.isEnabled = !session.busy && !session.chatting && session.review == null && session.connected && field.text?.isNotBlank() == true
        stop.visibility = if (session.chatting) View.VISIBLE else View.GONE
        field.visibility = if (active) View.INVISIBLE else View.VISIBLE
        waveform.visibility = if (voice.phase == OnDeviceVoiceInput.Phase.RECORDING) View.VISIBLE else View.GONE
        waveform.samples = voice.levels.toList()
        microphone.setIconResource(if (active) R.drawable.ic_stop else R.drawable.ic_mic)
        microphone.contentDescription = if (active) "Stop dictation. Add editable text, never send." else "Transcribe a voice message. Hold and release, or tap to start and stop. Nothing is sent automatically."
        microphone.isEnabled = !session.busy && !session.chatting && session.review == null || active
        status.text = voice.message ?: when (voice.phase) {
            OnDeviceVoiceInput.Phase.REQUESTING -> "Waiting for microphone permission…"
            OnDeviceVoiceInput.Phase.RECORDING -> "Listening on this device · Release or tap stop to add editable text."
            OnDeviceVoiceInput.Phase.FINISHING -> "Finishing on-device transcription…"
            else -> if (voice.available) "Voice stays on this device. Tap or hold the microphone; review text before sending."
                else "On-device dictation unavailable. Requires Android 12+ and a local recognizer/language model. No cloud fallback."
        }
        updateLatest()
    }
    @SuppressLint("ClickableViewAccessibility") // Every tap goes through performClick; TalkBack uses the same click action.
    private fun installMicrophoneGesture() {
        microphone.setOnTouchListener { _, event ->
            if (!microphone.isEnabled) return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    down = true; holding = false; microphone.isPressed = true
                    touchHandler.postDelayed(hold, ViewConfiguration.getLongPressTimeout().toLong()); true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (event.x < -context.dp(60) || event.x > microphone.width + context.dp(60) || event.y < -context.dp(60) || event.y > microphone.height + context.dp(60)) cancelGesture()
                    true
                }
                MotionEvent.ACTION_UP -> {
                    touchHandler.removeCallbacks(hold); microphone.isPressed = false
                    if (down) { if (holding) voice.stop() else microphone.performClick() }
                    down = false; holding = false; true
                }
                MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_POINTER_DOWN -> { cancelGesture(); true }
                else -> true
            }
        }
    }
    private fun cancelGesture() {
        touchHandler.removeCallbacks(hold); microphone.isPressed = false
        if (holding) voice.discard()
        down = false; holding = false
    }
    fun pause() {
        inForeground = false
        cancelGesture()
        if (voice.active) voice.discard("Dictation discarded when leaving the screen. Your typed draft is unchanged.")
        sourceDialog?.dismiss(); sourceDialog = null
        modelDialog?.dismiss(); modelDialog = null
        costumeDialog?.dismiss(); costumeDialog = null
        rememberEditor()
        cards.forEach { it.pause() }
    }
    fun resume() { inForeground = true; cards.forEach { it.resume() } }
    private fun rememberEditor() {
        chat.selectionStart = field.selectionStart; chat.selectionEnd = field.selectionEnd
        chat.scrollY = scroll.scrollY
    }
    fun close() {
        pause(); closed = true; ++scrollRevision
        voice.close(); promptDialog?.dismiss()
    }
}

/** Bars are derived only from recognizer RMS callbacks, never a simulated timer. */
private class VoiceWaveform(context: android.content.Context) : View(context) {
    var samples: List<Float> = emptyList()
        set(value) { field = value; invalidate() }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.color(R.color.secondary); strokeCap = Paint.Cap.ROUND; strokeWidth = context.dp(3).toFloat() }
    init { contentDescription = "Recording on this device. Release or stop to add editable text." }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val step = width / 24f
        samples.forEachIndexed { index, sample ->
            val half = context.dp(2) + sample * context.dp(14)
            val x = step * (24 - samples.size + index + .5f)
            canvas.drawLine(x, height / 2f - half, x, height / 2f + half, paint)
        }
    }
}
