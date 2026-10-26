package fyi.habibi.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/** No generic recognizer, network fallback, audio files, or audio transport. */
internal interface DeviceRecognizer {
    val available: Boolean
    interface Events {
        fun ready()
        fun level(rms: Float)
        fun partial(text: String)
        fun result(text: String)
        fun error(message: String)
    }
    fun start(events: Events)
    fun stop()
    fun close()
}

internal class AndroidDeviceRecognizer(private val context: Context) : DeviceRecognizer {
    private var recognizer: SpeechRecognizer? = null
    override val available get() = Build.VERSION.SDK_INT >= 31 &&
        runCatching { SpeechRecognizer.isOnDeviceRecognitionAvailable(context) }.getOrDefault(false)

    override fun start(events: DeviceRecognizer.Events) {
        if (Build.VERSION.SDK_INT < 31 || !available) error("On-device speech recognition is unavailable.")
        close()
        val device = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        recognizer = device
        device.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = events.ready()
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = events.level(rmsdB)
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit
            override fun onError(error: Int) = events.error(when (error) {
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is required. You can enable it in Android Settings."
                SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE ->
                    "The on-device language model is unavailable. Install it in Android speech settings, or type your message."
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech recognized. Your typed draft is unchanged."
                else -> "On-device dictation could not finish. Check Android speech settings or type your message. No cloud fallback is used."
            })
            override fun onResults(results: Bundle?) = events.result(transcript(results))
            override fun onPartialResults(partialResults: Bundle?) = events.partial(transcript(partialResults))
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        })
        device.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        })
    }
    private fun transcript(bundle: Bundle?) = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
    override fun stop() { recognizer?.stopListening() }
    override fun close() {
        val old = recognizer; recognizer = null
        try { old?.cancel() } finally { old?.destroy() }
    }
}

/** Main-thread, generation-fenced dictation. The only output is editable text. */
internal class OnDeviceVoiceInput(
    private val recognizer: DeviceRecognizer,
    private val hasPermission: () -> Boolean,
    private val requestPermission: ((Boolean) -> Unit) -> Unit,
    private val append: (String) -> Unit,
    private val changed: () -> Unit,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) {
    enum class Phase { IDLE, REQUESTING, RECORDING, FINISHING }
    var phase = Phase.IDLE; private set
    var message: String? = null; private set
    val available get() = recognizer.available
    val levels = ArrayDeque<Float>()
    private var generation = 0L
    private var closed = false
    private var partial = ""
    private var deadline: Runnable? = null
    val active get() = phase != Phase.IDLE

    fun start() {
        if (closed || active) return
        if (!available) {
            message = "Dictation requires Android 12 or later and an available on-device speech recognizer. This device cannot transcribe locally. Type your message; no cloud fallback or audio upload is used."
            changed(); return
        }
        val token = ++generation
        partial = ""; levels.clear(); message = null
        phase = Phase.REQUESTING; changed()
        if (hasPermission()) begin(token)
        else requestPermission { allowed ->
            if (!valid(token)) return@requestPermission
            if (allowed) begin(token)
            else discard("Microphone access was not granted. Type your message or allow microphone access in Android Settings.")
        }
    }
    private fun valid(token: Long) = !closed && token == generation && active
    private fun begin(token: Long) {
        if (!valid(token)) return
        phase = Phase.RECORDING
        changed()
        later(60_000) { if (valid(token)) stop() }
        try {
            recognizer.start(object : DeviceRecognizer.Events {
                override fun ready() { if (valid(token)) changed() }
                override fun level(rms: Float) {
                    if (!valid(token) || phase != Phase.RECORDING || !rms.isFinite()) return
                    if (levels.size >= 24) levels.removeFirst()
                    levels.addLast(((rms + 2f) / 12f).coerceIn(0f, 1f)); changed()
                }
                override fun partial(text: String) { if (valid(token)) partial = text }
                override fun result(text: String) { if (valid(token)) finish(text.ifBlank { partial }) }
                override fun error(message: String) { if (valid(token)) discard(message) }
            })
        } catch (_: Exception) {
            if (valid(token)) discard("On-device dictation could not start. Check Android speech settings or type your message. No cloud fallback is used.")
        }
    }
    fun stop() {
        when (phase) {
            Phase.REQUESTING -> discard("Dictation stopped before permission was granted. Tap the microphone to try again.")
            Phase.RECORDING -> {
                phase = Phase.FINISHING; changed()
                val token = generation
                later(4_000) { if (valid(token)) finish(partial) }
                try { recognizer.stop() } catch (_: Exception) { if (valid(token)) discard("Dictation could not finish. Your draft is unchanged.") }
            }
            else -> Unit
        }
    }
    private fun later(delay: Long, action: () -> Unit) {
        deadline?.let(handler::removeCallbacks)
        deadline = Runnable(action).also { handler.postDelayed(it, delay) }
    }
    private fun finish(text: String) {
        discard()
        if (text.isNotBlank()) append(text.trim())
        else { message = "No speech recognized. Your typed draft is unchanged."; changed() }
    }
    fun discard(reason: String? = null) {
        ++generation // Invalidate before cancel/destroy, which may call back synchronously.
        deadline?.let(handler::removeCallbacks); deadline = null
        phase = Phase.IDLE; partial = ""; levels.clear(); message = reason
        runCatching { recognizer.close() }
        changed()
    }
    fun close() { closed = true; discard() }
}
