package live.snapy.app

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
import kotlin.math.sqrt

/**
 * Meeting audio inside the mic foreground service (docs/ANDROID_NEXT_PLAN.md §5).
 *
 * ONE AudioRecord (VOICE_RECOGNITION, 16 kHz mono PCM) feeds BOTH
 *   - an AAC-LC encoder (MediaCodec) -> MediaMuxer -> <path>.part, renamed to <path> (.m4a)
 *     when finished, and
 *   - an offline Vosk recognizer (free-form, the same small model as the wake word) for the
 *     live captions and the transcript lines.
 * Why not MediaRecorder + SpeechRecognizer: both would open the microphone; on Android 9 and
 * older the second client gets silence or an error, and on 10+ concurrent capture silences one
 * of them (the system recognizer usually wins), so the recording would have gaps. Sharing one
 * AudioRecord avoids the conflict on every version.
 * Limits: during a phone/VoIP call Android 10+ silences other capture (the file has silence);
 * without the Vosk model (never downloaded) there is audio but no live transcript; Vosk's small
 * model is less accurate than cloud recognition — with the user's key the audio summary
 * (Gemini, opt-in) corrects that.
 * Nothing here logs audio or text.
 */
class MeetingAudioRecorder(
    private val path: String,
    private val model: () -> Model?,
    private val onText: (text: String, final: Boolean) -> Unit,
    private val onLevel: (Float) -> Unit,
) {
    @Volatile private var running = false
    private var thread: Thread? = null
    @Volatile var bytesWritten = 0L; private set
    @Volatile var failed: String? = null; private set
    val startedAt = System.currentTimeMillis()

    fun start(): Boolean {
        if (running) return true
        running = true
        thread = Thread({ loop() }, "snapy-meeting-audio").also { it.start() }
        return true
    }

    /** Stops and finalizes the file (blocking, call off the main thread). Returns the file or null. */
    fun stop(): File? {
        running = false
        thread?.join(8000)
        val f = File(path)
        return if (f.exists() && f.length() > 0) f else null
    }

    @SuppressLint("MissingPermission")    // checked by WakeWordService before starting
    private fun loop() {
        val rate = SAMPLE_RATE
        val minBuf = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val chunk = rate / 10 * 2                                              // 100 ms of 16-bit mono
        var rec: AudioRecord? = null
        var codec: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var vosk: Recognizer? = null
        val part = File("$path.part")
        try {
            File(path).parentFile?.mkdirs()
            rec = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, rate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, chunk * 4))
            if (rec.state != AudioRecord.STATE_INITIALIZED) throw IllegalStateException("mic unavailable")
            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 32000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, chunk * 2)
            }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
                configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); start()
            }
            muxer = MediaMuxer(part.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            var track = -1
            var muxing = false
            val info = MediaCodec.BufferInfo()
            val buf = ByteArray(chunk)
            var samples = 0L
            rec.startRecording()
            var eos = false
            var eosAt = 0L
            var lastPartial = ""
            var modelTried = false
            while (true) {
                if (!eos) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n > 0) {
                        onLevel(rms(buf, n))
                        // ask for the model ONCE: model() may block (config lookup, loading the model);
                        // retrying every 100 ms chunk would stall the read loop and overrun AudioRecord
                        if (vosk == null && !modelTried) {
                            modelTried = true
                            vosk = try { model()?.let { Recognizer(it, rate.toFloat()) } } catch (_: Throwable) { null }
                        }
                        vosk?.let { r ->
                            if (r.acceptWaveForm(buf, n)) {
                                val t = JSONObject(r.result).optString("text").trim()
                                if (t.isNotEmpty()) onText(t, true)
                                lastPartial = ""
                            } else {
                                val p = JSONObject(r.partialResult).optString("partial").trim()
                                if (p.isNotEmpty() && p != lastPartial) { lastPartial = p; onText(p, false) }
                            }
                        }
                    }
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val pts = samples * 1_000_000L / rate
                        if (!running) {
                            codec.queueInputBuffer(inIdx, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            eos = true
                            eosAt = System.currentTimeMillis()
                        } else if (n > 0) {
                            val ib = codec.getInputBuffer(inIdx)!!
                            ib.clear(); ib.put(buf, 0, n)
                            codec.queueInputBuffer(inIdx, 0, n, pts, 0)
                            samples += n / 2
                        } else codec.queueInputBuffer(inIdx, 0, 0, pts, 0)
                    }
                }
                // drain
                var out = codec.dequeueOutputBuffer(info, if (eos) 10_000 else 0)
                var done = false
                while (out != MediaCodec.INFO_TRY_AGAIN_LATER) {
                    if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        track = muxer.addTrack(codec.outputFormat); muxer.start(); muxing = true
                    } else if (out >= 0) {
                        val ob = codec.getOutputBuffer(out)!!
                        if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) info.size = 0
                        if (info.size > 0 && muxing) {
                            ob.position(info.offset); ob.limit(info.offset + info.size)
                            muxer.writeSampleData(track, ob, info)
                            bytesWritten += info.size
                        }
                        codec.releaseOutputBuffer(out, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) { done = true; break }
                    }
                    out = codec.dequeueOutputBuffer(info, if (eos) 10_000 else 0)
                }
                if (done) break
                // an encoder that never reports end-of-stream must not spin this thread forever
                if (eos && System.currentTimeMillis() - eosAt > 3000) break
            }
            vosk?.let { r -> JSONObject(r.finalResult).optString("text").trim().takeIf { it.isNotEmpty() }?.let { onText(it, true) } }
            rec.stop()
            if (muxing) muxer.stop()
            muxer.release(); muxer = null
            if (bytesWritten > 0) {
                val f = File(path); f.delete()
                if (!part.renameTo(f)) failed = "rename"
            } else { part.delete(); failed = "empty" }
        } catch (e: Exception) {
            failed = e.javaClass.simpleName
            try { muxer?.release() } catch (_: Exception) { }
            muxer = null
            if (bytesWritten > 0) part.renameTo(File(path)) else part.delete()
        } finally {
            try { rec?.release() } catch (_: Exception) { }
            try { codec?.stop() } catch (_: Exception) { }
            try { codec?.release() } catch (_: Exception) { }
            try { muxer?.release() } catch (_: Exception) { }
            try { vosk?.close() } catch (_: Exception) { }
            running = false
        }
    }

    private fun rms(b: ByteArray, n: Int): Float {
        var sum = 0.0
        var i = 0
        while (i + 1 < n) { val s = ((b[i + 1].toInt() shl 8) or (b[i].toInt() and 0xFF)).toShort().toDouble(); sum += s * s; i += 2 }
        val r = sqrt(sum / maxOf(1, n / 2)) / 32768.0
        return (r * 6).coerceIn(0.0, 1.0).toFloat()
    }

    companion object { const val SAMPLE_RATE = 16000 }
}
