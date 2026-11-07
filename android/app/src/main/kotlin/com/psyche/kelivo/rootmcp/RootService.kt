package com.psyche.kelivo.rootmcp

import android.content.Context
import android.util.Log
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

// Kelivo built-in Root MCP server (streamable HTTP on 127.0.0.1:18990/mcp).
// Exposes execute_shell / read_device_file via KernelSU `su -c` so the chat
// model can run privileged commands on the device without any external app.
class RootService private constructor() : NanoHTTPD("127.0.0.1", 18990) {
    companion object {
        private const val TAG = "RootMcpService"
        private const val MAX_OUTPUT = 8000

        @Volatile
        private var instance: RootService? = null

        fun start(context: Context) {
            if (instance != null) return
            synchronized(this) {
                if (instance != null) return
                try {
                    val svc = RootService()
                    svc.start(SOCKET_READ_TIMEOUT, false)
                    instance = svc
                    Log.w(TAG, "listening on 127.0.0.1:18990/mcp")
                } catch (e: Exception) {
                    Log.e(TAG, "start failed (port busy?): " + e.message)
                }
            }
        }
    }

    private fun toolsJson(): JSONArray = JSONArray().put(
        JSONObject().put("name", "execute_shell").put(
            "description",
            "Execute a shell command on the Android device with ROOT privileges (KernelSU su -c). " +
                "Use for system inspection, pm/am commands, file ops anywhere, process management. " +
                "Non-interactive; chain with && or ;. Output capped at 8000 chars."
        ).put("inputSchema", JSONObject()
            .put("type", "object")
            .put("properties", JSONObject()
                .put("command", JSONObject().put("type", "string").put("description", "Shell command to run as root."))
                .put("timeout_seconds", JSONObject().put("type", "integer").put("description", "Timeout in seconds, default 60, max 600.")))
            .put("required", JSONArray().put("command")))
    ).put(
        JSONObject().put("name", "read_device_file").put(
            "description",
            "Read a text file from the Android device filesystem (root access, e.g. /data/..., /system/...). Returns up to 400 lines."
        ).put("inputSchema", JSONObject()
            .put("type", "object")
            .put("properties", JSONObject()
                .put("path", JSONObject().put("type", "string").put("description", "Absolute file path on the Android device."))
                .put("lines", JSONObject().put("type", "integer").put("description", "Max lines to return, default 400.")))
            .put("required", JSONArray().put("path")))
    )

    private fun runSu(command: String, timeoutSec: Int): Pair<Int, String> {
        return try {
            val proc = ProcessBuilder("su", "-c", command)
                .redirectErrorStream(true)
                .start()
            val out = StringBuilder()
            val reader = proc.inputStream.bufferedReader()
            var read: Int
            val buf = CharArray(4096)
            while (reader.read(buf).also { read = it } > 0 && out.length < MAX_OUTPUT + 1024) {
                out.append(buf, 0, read)
            }
            val exited = proc.waitFor()
            Pair(exited, out.toString().take(MAX_OUTPUT).ifEmpty { "(no output)" })
        } catch (e: Exception) {
            Pair(-1, "error: ${e.message}")
        }
    }

    private fun callTool(name: String, args: JSONObject): JSONObject {
        val text: String
        val isError: Boolean
        when (name) {
            "execute_shell" -> {
                val cmd = args.optString("command", "")
                val t = (args.optInt("timeout_seconds", 60)).coerceIn(1, 600)
                val (rc, out) = runSu(cmd, t)
                text = "exit=$rc\n$out"
                isError = rc != 0
            }
            "read_device_file" -> {
                val path = args.optString("path", "")
                val n = args.optInt("lines", 400).coerceIn(1, 2000)
                val (rc, out) = runSu("head -n $n '$path'", 30)
                text = if (rc != 0) "error: $out" else out.ifEmpty { "(empty file)" }
                isError = rc != 0
            }
            else -> {
                text = "unknown tool: $name"
                isError = true
            }
        }
        return JSONObject()
            .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", text)))
            .put("isError", isError)
    }

    private fun json(code: Response.Status, body: String): Response =
        newFixedLengthResponse(code, "application/json", body)

    override fun serve(session: IHTTPSession): Response {
        val method = session.method
        val uri = session.uri ?: "/"
        // CORS preflight
        if (method == Method.OPTIONS) {
            val r = newFixedLengthResponse(Response.Status.NO_CONTENT, "text/plain", "")
            r.addHeader("Access-Control-Allow-Origin", "*")
            r.addHeader("Access-Control-Allow-Headers", "*")
            r.addHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS, DELETE")
            return r
        }
        if (method == Method.GET) {
            return json(Response.Status.OK,
                """{"server":"kelivo-root-mcp","status":"ok","tools":2}""")
        }
        if (method == Method.DELETE) {
            return json(Response.Status.OK, "{}")
        }
        if (method != Method.POST || !uri.trimEnd('/').endsWith("mcp")) {
            return json(Response.Status.NOT_FOUND, """{"error":"not found"}""")
        }
        val body = StringBuilder()
        val files = HashMap<String, String>()
        files["postData"] = ""
        session.parseBody(files)
        body.append(files["postData"] ?: "")
        val req = try { JSONObject(body.toString()) } catch (e: Exception) {
            return json(Response.Status.BAD_REQUEST, """{"error":"bad json"}""")
        }
        val m = req.optString("method", "")
        val rid = req.opt("id")
        val resp = JSONObject().put("jsonrpc", "2.0").put("id", rid)
        when (m) {
            "initialize" -> resp.put("result", JSONObject()
                .put("protocolVersion", req.optJSONObject("params")?.optString("protocolVersion")?.takeIf { it.isNotEmpty() } ?: "2025-03-26")
                .put("capabilities", JSONObject().put("tools", JSONObject()))
                .put("serverInfo", JSONObject().put("name", "kelivo-root-mcp").put("version", "1.0.0")))
            "notifications/initialized" ->
                return newFixedLengthResponse(Response.Status.ACCEPTED, "text/plain", "")
            "tools/list" -> resp.put("result", JSONObject().put("tools", toolsJson()))
            "tools/call" -> {
                val p = req.optJSONObject("params") ?: JSONObject()
                resp.put("result", callTool(p.optString("name", ""), p.optJSONObject("arguments") ?: JSONObject()))
            }
            "ping" -> resp.put("result", JSONObject())
            else -> resp.put("error", JSONObject().put("code", -32601).put("message", "method not found: $m"))
        }
        return json(Response.Status.OK, resp.toString())
    }
}