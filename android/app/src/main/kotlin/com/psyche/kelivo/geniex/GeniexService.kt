package com.psyche.kelivo.geniex

import android.content.Context
import android.util.Log
import com.geniex.sdk.LlmWrapper
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
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Kelivo 内置本地 NPU 推理服务（GenieX / 高通 llama_cpp runtime）。
 *
 * 形态：App 内常驻 NanoHTTPD，暴露 OpenAI 兼容接口（回环 127.0.0.1:18800）。
 * Kelivo 里配置自定义供应商指向 http://127.0.0.1:18800/v1 即可用本地模型。
 * 模型来源：App 外部私有目录 files/llm_models/*.gguf（无需存储权限）。
 * 启动时自动加载目录里最大的 gguf；POST /load {"file":"x.gguf"} 可切换。
 *
 * 参数对齐高通官方 GenieX 仓库建议：
 *  - runtime_id="llama_cpp"（mmap 分层加载：热层驻物理内存、冷权重按需换页）
 *  - nGpuLayers=-1（全部层参与 HTP 调度）
 *  - nCtx=2048
 */
class GeniexService private constructor(context: Context) : NanoHTTPD("127.0.0.1", 18800) {

    companion object {
        private const val TAG = "GeniexService"

        @Volatile
        private var instance: GeniexService? = null

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
                    Log.e(TAG, "start failed (port busy?): ${e.message}")
                }
            }
        }
    }

    private val appContext = context.applicationContext
    @Volatile private var engineRef: LlmWrapper? = null
    @Volatile private var loadedFile: String? = null
    private val generating = AtomicBoolean(false)

    fun listModels(): List<File> =
        modelsDir(appContext).listFiles { f -> f.extension == "gguf" }?.sortedByDescending { it.length() }
            ?: emptyList()

    private fun autoLoad(dir: File) {
        val gguf = dir.listFiles { f -> f.extension == "gguf" }?.maxByOrNull { it.length() }
        if (gguf == null) {
            Log.w(TAG, "no .gguf in ${dir.absolutePath}, idle")
            return
        }
        loadModel(gguf)
    }

    private fun loadModel(gguf: File): String? {
        if (!gguf.exists()) return "模型文件不存在: ${gguf.absolutePath}"
        unload()
        return try {
            val conf = ModelConfig(nCtx = 2048, nGpuLayers = -1, enable_thinking = false)
            val input = LlmCreateInput(
                model_name = gguf.nameWithoutExtension,
                model_path = gguf.absolutePath,
                tokenizer_path = gguf.absolutePath,
                config = conf,
                runtime_id = "llama_cpp",
                compute_unit = ComputeUnitValue.NPU.value,
            )
            Log.w(TAG, "loading ${gguf.name} (${gguf.length() / 1048576}MB) unit=npu ctx=2048")
            val w = LlmWrapper.builder().llmCreateInput(input).build().getOrThrow()
            engineRef = w
            loadedFile = gguf.name
            Log.w(TAG, "loaded OK: ${gguf.name}")
            null
        } catch (t: Throwable) {
            Log.e(TAG, "load failed: ${t.message}", t)
            engineRef = null
            loadedFile = null
            t.message ?: "加载失败"
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
                    listModels().forEach { arr.put(it.name) }
                    json(JSONObject().put("object", "list").put("data", JSONArray().putAll(arr.map { JSONObject().put("id", it).put("object", "model") })))
                }
                uri == "/load" && session.method == Method.POST -> {
                    val name = JSONObject(readBody(session)).optString("file")
                    val f = listModels().firstOrNull { it.name == name }
                        ?: return json(JSONObject().put("ok", false).put("error", "model not found"), 404)
                    val err = loadModel(f)
                    json(JSONObject().put("ok", err == null).put("error", err ?: JSONObject.NULL))
                }
                uri == "/v1/chat/completions" && session.method == Method.POST ->
                    handleChat(JSONObject(readBody(session)))
                else -> newFixedLengthResponse(Response.Status.NOT_FOUND, "application/json", "{\"error\":\"not found\"}")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "serve $uri error: ${t.message}", t)
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
            ?: return json(JSONObject().put("error", "模型未加载，先往 llm_models 放 .gguf"), 503)
        val stream = req.optBoolean("stream", false)
        if (!stream) {
            if (!generating.compareAndSet(false, true))
                return json(JSONObject().put("error", "上一轮还在生成中"), 429)
            try {
                val text = generateBlocking(w, req) { _, _ -> }
                val choice = JSONObject().put("index", 0)
                    .put("message", JSONObject().put("role", "assistant").put("content", text))
                    .put("finish_reason", "stop")
                return json(JSONObject()
                    .put("id", "chatcmpl-local")
                    .put("object", "chat.completion")
                    .put("model", loadedFile ?: "local")
                    .put("choices", JSONArray().put(choice)))
            } finally {
                generating.set(false)
            }
        }
        // SSE 流式
        if (!generating.compareAndSet(false, true))
            return json(JSONObject().put("error", "上一轮还在生成中"), 429)
        val chunkBase = JSONObject()
            .put("id", "chatcmpl-local")
            .put("object", "chat.completion.chunk")
            .put("model", loadedFile ?: "local")
        val pipe = NanoHTTPD.newChunkedResponse(Response.Status.OK, "text/event-stream") { out ->
            try {
                generateBlocking(w, req) { sb, delta ->
                    val c = JSONObject(chunkBase.toString())
                        .put("choices", JSONArray().put(JSONObject().put("index", 0)
                            .put("delta", JSONObject().put("content", delta))))
                    out.write("data: $c\n\n".toByteArray())
                    out.flush()
                }
                out.write("data: [DONE]\n\n".toByteArray())
                out.flush()
            } catch (t: Throwable) {
                Log.e(TAG, "sse broken (client disconnect ok): ${t.message}")
            } finally {
                generating.set(false)
            }
        }
        return pipe
    }

    /** 组消息、套模板、流式生成。onDelta(sb, newDelta) 回调。返回完整文本。 */
    private fun generateBlocking(
        w: LlmWrapper,
        req: JSONObject,
        onDelta: ((StringBuilder, String) -> Unit)?
    ): String {
        val maxTokens = req.optInt("max_tokens", 512)
        val msgs = req.optJSONArray("messages") ?: JSONArray()
        val system = StringBuilder()
        val history = ArrayList<Pair<Boolean, String>>()
        for (i in 0 until msgs.length()) {
            val m = msgs.getJSONObject(i)
            when (val role = m.optString("role")) {
                "system" -> if (i < msgs.length() - 1) system.append(m.optString("content")).append('\n')
                else -> if (i < msgs.length() - 1) history.add((role == "user") to m.optString("content"))
            }
        }
        val userMsg = if (msgs.length() > 0) msgs.getJSONObject(msgs.length() - 1).optString("content") else ""
        val chatMsgs = buildList {
            add(ChatMessage("system", system.toString().trim()))
            history.takeLast(10).forEach { (isUser, text) ->
                add(ChatMessage(if (isUser) "user" else "assistant", text))
            }
            add(ChatMessage("user", userMsg))
        }
        val template = w.applyChatTemplate(chatMsgs.toTypedArray(), "[]", false).getOrThrow().formattedText
        val genCfg = com.geniex.sdk.bean.GenerationConfig(maxTokens = maxTokens)
        val sb = StringBuilder()
        runBlocking(Dispatchers.IO) {
            w.generateStreamFlow(template, genCfg).collect { r ->
                when (r) {
                    is LlmStreamResult.Token -> {
                        sb.append(r.text)
                        onDelta?.invoke(sb, r.text)
                    }
                    is LlmStreamResult.Error -> Log.e(TAG, "stream error: ${r.throwable.message}")
                    is LlmStreamResult.Completed ->
                        Log.w(TAG, "stats: ttft=${r.profile.ttftMs}ms decode=${r.profile.decodingSpeed}tok/s")
                }
            }
        }
        return sb.toString()
    }
}
