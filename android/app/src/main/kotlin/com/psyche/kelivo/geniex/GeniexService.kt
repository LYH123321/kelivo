package com.psyche.kelivo.geniex

import android.content.Context
import android.util.Log
import com.geniex.sdk.LlmWrapper
import com.geniex.sdk.ModelManagerWrapper
import com.geniex.sdk.bean.ChatMessage
import com.geniex.sdk.bean.ComputeUnitValue
import com.geniex.sdk.bean.LlmCreateInput
import com.geniex.sdk.bean.LlmStreamResult
import com.geniex.sdk.bean.ModelConfig
import fi.iki.elonen.NanoHTTPD
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.atomic.AtomicBoolean

// Kelivo built-in local NPU inference service (Qualcomm GenieX, llama_cpp runtime).
// OpenAI-compatible HTTP API on 127.0.0.1:18800.
// Models live in app external files dir under llm_models, gguf files.
class GeniexService private constructor(context: Context) : NanoHTTPD("127.0.0.1", 18800) {

    companion object {
        private const val TAG = "GeniexService"

        @Volatile
        private var instance: GeniexService? = null

        @Volatile
        private var sdkReady = false

        // Qualcomm GenieX SDK must be initialized before any LlmWrapper call:
        // it loads libnpu_jni.so from nativeLibraryDir, creates files/geniex work dir,
        // calls ModelManager.init(workdir) and registers llama_cpp + qairt plugins.
        private fun ensureSdk(context: Context) {
            // Kotlin source cannot access GenieXSdk.instance (private in metadata);
            // SdkBridge.java calls the public Companion.getInstance() at bytecode level.
            val ok = SdkBridge.ensure(context)
            sdkReady = ok
            if (!ok) Log.e(TAG, "ensureSdk: sdk init failed")
        }

        fun modelsDir(context: Context): File =
            File(context.getExternalFilesDir(null) ?: context.filesDir, "llm_models").apply { mkdirs() }

        fun start(context: Context) {
            if (instance != null) return
            synchronized(this) {
                if (instance != null) return
                try {
                    val svc = GeniexService(context.applicationContext)
                    svc.start(SOCKET_READ_TIMEOUT, false)
                    instance = svc
                    Log.w(TAG, "listening on 127.0.0.1:18800")
                    Thread { svc.autoLoad(modelsDir(context)) }.start()
                } catch (e: Exception) {
                    Log.e(TAG, "start failed (port busy?): " + e.message)
                }
            }
        }
    }

    private val appContext = context.applicationContext

    @Volatile private var engineRef: LlmWrapper? = null
    @Volatile private var loadedFile: String? = null
    private val generating = AtomicBoolean(false)

    fun listModels(): List<File> =
        modelsDir(appContext).listFiles { f -> f.extension == "gguf" }
            ?.sortedByDescending { it.length() } ?: emptyList()

    private fun autoLoad(dir: File) {
        ensureSdk(appContext)
        val gguf = dir.listFiles { f -> f.extension == "gguf" }?.maxByOrNull { it.length() }
        if (gguf == null) {
            Log.w(TAG, "no gguf found, idle")
            return
        }
        loadModel(gguf)
    }

    // Returns null on success, error message otherwise.
    private fun loadModel(gguf: File, unit: String = "npu", ctx: Int = 2048): String? {
        if (!gguf.exists()) return "model file missing: " + gguf.absolutePath
        ensureSdk(appContext)
        unload()
        return try {
            // nGpuLayers must be 0 for llama_cpp runtime (official sample): NPU offload is
            // driven by compute_unit, passing -1 segfaults inside geniex_llm_create.
            val conf = ModelConfig(nCtx = ctx, nGpuLayers = 0, enable_thinking = false)
            val input = LlmCreateInput(
                model_name = gguf.nameWithoutExtension,
                model_path = gguf.absolutePath,
                tokenizer_path = gguf.absolutePath,
                config = conf,
                runtime_id = "llama_cpp",
                compute_unit = when (unit) {
                "gpu" -> ComputeUnitValue.GPU.value
                "cpu" -> ComputeUnitValue.CPU.value
                "hybrid" -> ComputeUnitValue.HYBRID.value
                else -> ComputeUnitValue.NPU.value
            }
            )
            Log.w(TAG, "loading " + gguf.name + " (" + gguf.length() / 1048576 + "MB) unit=" + unit + " ctx=" + ctx)
            val w = runBlocking(Dispatchers.IO) {
                LlmWrapper.builder().llmCreateInput(input).build().getOrThrow()
            }
            engineRef = w
            loadedFile = gguf.name
            Log.w(TAG, "loaded OK: " + gguf.name)
            null
        } catch (t: Throwable) {
            Log.e(TAG, "load failed: " + t.message, t)
            engineRef = null
            loadedFile = null
            t.message ?: "load failed"
        }
    }

    private fun unload() {
        try { engineRef?.close() } catch (_: Throwable) {}
        engineRef = null
        loadedFile = null
    }

    override fun serve(session: IHTTPSession): Response {
        val uri = session.uri
        return try {
            when {
                uri == "/health" -> json(
                    JSONObject()
                        .put("loaded", engineRef != null)
                        .put("model", loadedFile ?: JSONObject.NULL)
                        .put("generating", generating.get())
                )
                uri == "/v1/models" -> {
                    val arr = JSONArray()
                    listModels().forEach { arr.put(JSONObject().put("id", it.name).put("object", "model")) }
                    json(JSONObject().put("object", "list").put("data", arr))
                }
                uri == "/registry" -> {
                    val arr = JSONArray()
                    try {
                        val names = runBlocking(Dispatchers.IO) { ModelManagerWrapper.list() }
                        names.forEach { arr.put(it) }
                    } catch (t: Throwable) {
                        Log.e(TAG, "registry list failed: " + t.message)
                    }
                    json(JSONObject().put("registry", arr))
                }
                uri == "/load" && session.method == Method.POST -> {
                    val req = JSONObject(readBody(session))
                    val name = req.optString("file")
                    val f = listModels().firstOrNull { it.name == name }
                        ?: return json(JSONObject().put("ok", false).put("error", "model not found"), 404)
                    val err = loadModel(f, req.optString("unit", "npu"), req.optInt("ctx", 2048))
                    json(JSONObject().put("ok", err == null).put("error", err ?: JSONObject.NULL))
                }
                uri == "/v1/chat/completions" && session.method == Method.POST ->
                    handleChat(JSONObject(readBody(session)))
                else -> newFixedLengthResponse(
                    Response.Status.NOT_FOUND, "application/json", "{\"error\":\"not found\"}"
                )
            }
        } catch (t: Throwable) {
            Log.e(TAG, "serve error on " + uri + ": " + t.message, t)
            json(JSONObject().put("error", t.message ?: "internal error"), 500)
        }
    }

    private fun readBody(session: IHTTPSession): String {
        val map = HashMap<String, String>()
        session.parseBody(map)
        return map["postData"] ?: ""
    }

    private fun json(obj: JSONObject, status: Int = 200): Response =
        newFixedLengthResponse(
            if (status == 200) Response.Status.OK else Response.Status.lookup(status),
            "application/json", obj.toString()
        )

    private fun handleChat(req: JSONObject): Response {
        val w = engineRef
            ?: return json(JSONObject().put("error", "model not loaded; put gguf into llm_models"), 503)
        val stream = req.optBoolean("stream", false)
        if (!generating.compareAndSet(false, true)) {
            return json(JSONObject().put("error", "another generation in progress"), 429)
        }
        if (!stream) {
            try {
                val text = generateBlocking(w, req, null)
                val choice = JSONObject().put("index", 0)
                    .put("message", JSONObject().put("role", "assistant").put("content", text))
                    .put("finish_reason", "stop")
                return json(
                    JSONObject()
                        .put("id", "chatcmpl-local")
                        .put("object", "chat.completion")
                        .put("model", loadedFile ?: "local")
                        .put("choices", JSONArray().put(choice))
                )
            } finally {
                generating.set(false)
            }
        }
        // SSE streaming path
        val chunkBase = JSONObject()
            .put("id", "chatcmpl-local")
            .put("object", "chat.completion.chunk")
            .put("model", loadedFile ?: "local")
        val pipedIn = PipedInputStream(64 * 1024)
        val pipedOut = PipedOutputStream(pipedIn)
        Thread {
            try {
                generateBlocking(w, req) { _, delta ->
                    val chunk = JSONObject(chunkBase.toString())
                        .put(
                            "choices", JSONArray().put(
                                JSONObject().put("index", 0)
                                    .put("delta", JSONObject().put("content", delta))
                            )
                        )
                    pipedOut.write(("data: " + chunk.toString() + "\n\n").toByteArray())
                    pipedOut.flush()
                }
                pipedOut.write("data: [DONE]\n\n".toByteArray())
                pipedOut.flush()
            } catch (t: Throwable) {
                Log.e(TAG, "sse broken (client disconnect is ok): " + t.message)
            } finally {
                generating.set(false)
                try { pipedOut.close() } catch (_: Throwable) {}
            }
        }.start()
        return newChunkedResponse(Response.Status.OK, "text/event-stream", pipedIn)
    }

    // Build messages, apply chat template, run streaming generation.
    // onDelta receives (fullTextSoFar, newDelta). Returns full text.
    private fun generateBlocking(
        w: LlmWrapper,
        req: JSONObject,
        onDelta: ((String, String) -> Unit)?
    ): String {
        val maxTokens = req.optInt("max_tokens", 512)
        val msgs = req.optJSONArray("messages") ?: JSONArray()
        val system = StringBuilder()
        val history = ArrayList<Pair<Boolean, String>>()
        val n = msgs.length()
        for (i in 0 until n) {
            val m = msgs.getJSONObject(i)
            val role = m.optString("role")
            if (i == n - 1) continue
            if (role == "system") {
                system.append(m.optString("content")).append('\n')
            } else {
                history.add((role == "user") to m.optString("content"))
            }
        }
        val userMsg = if (n > 0) msgs.getJSONObject(n - 1).optString("content") else ""
        val sb = StringBuilder()
        runBlocking(Dispatchers.IO) {
            val chatMsgs = ArrayList<ChatMessage>()
            chatMsgs.add(ChatMessage("system", system.toString().trim()))
            for ((isUser, text) in history.takeLast(10)) {
                chatMsgs.add(ChatMessage(if (isUser) "user" else "assistant", text))
            }
            chatMsgs.add(ChatMessage("user", userMsg))
            val template = w.applyChatTemplate(chatMsgs.toTypedArray(), "[]", false)
                .getOrThrow().formattedText
            val genCfg = com.geniex.sdk.bean.GenerationConfig(maxTokens = maxTokens)
            w.generateStreamFlow(template, genCfg).collect { r ->
                when (r) {
                    is LlmStreamResult.Token -> {
                        sb.append(r.text)
                        onDelta?.invoke(sb.toString(), r.text)
                    }
                    is LlmStreamResult.Error ->
                        Log.e(TAG, "stream error: " + r.throwable.message)
                    is LlmStreamResult.Completed ->
                        Log.w(TAG, "stats: ttft=" + r.profile.ttftMs + "ms decode=" + r.profile.decodingSpeed + "tok/s")
                }
            }
        }
        return sb.toString()
    }
}
