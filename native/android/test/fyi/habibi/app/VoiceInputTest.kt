package fyi.habibi.app

import android.os.Looper
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class VoiceInputTest {
    @Test fun stopAddsFinalEditableTextOnceAndLevelsAreMeasuredBoundedSamples() {
        val recognizer = FixtureRecognizer(); val drafts = mutableListOf<String>()
        val voice = OnDeviceVoiceInput(recognizer, { true }, { fail("Already permitted") }, drafts::add, {})
        voice.start(); val events = recognizer.sessions.single()
        assertEquals(OnDeviceVoiceInput.Phase.RECORDING, voice.phase); assertTrue(voice.levels.isEmpty())
        events.level(-2f); events.level(10f)
        assertEquals(listOf(0f, 1f), voice.levels.toList())
        repeat(30) { events.level(4f) }; events.level(Float.NaN)
        assertEquals(24, voice.levels.size); assertTrue(voice.levels.all { it == .5f })
        events.partial("unfinished"); assertTrue(drafts.isEmpty())
        voice.stop(); voice.stop(); assertEquals(1, recognizer.stops)
        assertEquals(OnDeviceVoiceInput.Phase.FINISHING, voice.phase)
        events.result("Final editable words"); events.result("duplicate")
        assertEquals(listOf("Final editable words"), drafts); assertEquals(OnDeviceVoiceInput.Phase.IDLE, voice.phase)
        voice.close()
    }
    @Test fun releaseBeforePermissionDoesNotStartLaterAndDenialCanRetry() {
        val recognizer = FixtureRecognizer(); val permission = mutableListOf<(Boolean) -> Unit>(); val drafts = mutableListOf<String>()
        val voice = OnDeviceVoiceInput(recognizer, { false }, { permission.add(it) }, drafts::add, {})
        voice.start(); assertEquals(OnDeviceVoiceInput.Phase.REQUESTING, voice.phase)
        voice.stop(); permission[0](true)
        assertEquals(OnDeviceVoiceInput.Phase.IDLE, voice.phase); assertTrue(recognizer.sessions.isEmpty())
        voice.start(); permission[1](false)
        assertTrue(voice.message!!.contains("not granted")); assertTrue(recognizer.sessions.isEmpty())
        voice.start(); permission[2](true)
        recognizer.sessions.single().result("Try again")
        assertEquals(listOf("Try again"), drafts)
        voice.close()
    }
    @Test fun discardAndCloseFenceLateResultsErrorsLevelsAndPermissionCallbacks() {
        val recognizer = FixtureRecognizer(); val drafts = mutableListOf<String>()
        val voice = OnDeviceVoiceInput(recognizer, { true }, {}, drafts::add, {})
        voice.start(); val old = recognizer.sessions.last(); old.partial("Discard this")
        voice.discard(); voice.start(); val current = recognizer.sessions.last()
        old.result("Stale"); old.error("Stale error"); old.level(10f)
        assertEquals(OnDeviceVoiceInput.Phase.RECORDING, voice.phase); assertNull(voice.message); assertTrue(voice.levels.isEmpty())
        current.partial("Current"); voice.close(); current.result("After departure")
        assertTrue(drafts.isEmpty()); assertEquals(OnDeviceVoiceInput.Phase.IDLE, voice.phase)
        var callback: ((Boolean) -> Unit)? = null
        val pending = OnDeviceVoiceInput(recognizer, { false }, { callback = it }, drafts::add, {})
        pending.start(); pending.close(); callback!!(true)
        assertEquals(2, recognizer.sessions.size); assertTrue(drafts.isEmpty())
    }
    @Test fun finishingHasBoundedWaitAndRecordingHasOneMinuteLimit() {
        val recognizer = FixtureRecognizer(); val drafts = mutableListOf<String>()
        val voice = OnDeviceVoiceInput(recognizer, { true }, {}, drafts::add, {})
        voice.start(); recognizer.sessions.last().partial("Local partial")
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(60))
        assertEquals(OnDeviceVoiceInput.Phase.FINISHING, voice.phase)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(4))
        assertEquals(listOf("Local partial"), drafts); assertEquals(OnDeviceVoiceInput.Phase.IDLE, voice.phase)
        recognizer.sessions.last().result("Late final"); assertEquals(1, drafts.size)
        voice.close()
    }
    @Test fun unavailableAndRecognizerErrorNeverAppendOrRequestPermission() {
        val drafts = mutableListOf<String>(); val recognizer = FixtureRecognizer(false)
        val unavailable = OnDeviceVoiceInput(recognizer, { false }, { fail("Unavailable must not ask for permission") }, drafts::add, {})
        unavailable.start(); assertFalse(unavailable.active); assertTrue(unavailable.message!!.contains("no cloud fallback"))
        assertTrue(recognizer.sessions.isEmpty())
        val local = FixtureRecognizer(); val voice = OnDeviceVoiceInput(local, { true }, {}, drafts::add, {})
        voice.start(); local.sessions.last().partial("Not final"); local.sessions.last().error("Local language model unavailable")
        assertFalse(voice.active); assertTrue(drafts.isEmpty()); assertEquals("Local language model unavailable", voice.message)
        unavailable.close(); voice.close()
    }
    @Test @Config(sdk = [30]) fun platformAdapterNeverOffersPreAndroid12Recognition() {
        assertFalse(AndroidDeviceRecognizer(RuntimeEnvironment.getApplication()).available)
    }
}
