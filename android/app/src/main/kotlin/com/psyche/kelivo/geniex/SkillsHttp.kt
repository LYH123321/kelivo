package com.psyche.kelivo.geniex

import android.content.Context
import android.util.Log
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.FileInputStream
import java.io.FileReader

/**
 * Bridge: exposes Stardust-style "skills" (markdown playbooks in
 * /sdcard/Download/kelivo_skills) over HTTP so the Dart side can fetch them
 * as context. Read-only, local only.
 *
 * GET /skills            -> {"skills":[{"name":..,"size":..},..]}
 * GET /skills?name=x.md  -> raw markdown body
 */
class SkillsHttp private constructor(context: Context) :
    NanoHTTPD("127.0.0.1", 18801) {

    private val dir = File(
        android.os.Environment.getExternalStoragePublicDirectory(
            android.os.Environment.DIRECTORY_DOWNLOADS
        ),
        "kelivo_skills"
    )

    companion object {
        private const val TAG = "SkillsHttp"
        @Volatile private var instance: SkillsHttp? = null
        fun start(context: Context) {
            if (instance != null) return
            synchronized(this) {
                if (instance == null) {
                    instance = SkillsHttp(context.applicationContext).also {
                        it.start(5000, true)
                        Log.w(TAG, "listening 127.0.0.1:18801")
                    }
                }
            }
        }
    }

    override fun serve(session: IHTTPSession): Response {
        if (session.parameters["name"]?.isNotEmpty() == true) {
            val f = File(dir, session.parameters["name"]!!.single())
            if (!f.exists() || !f.canonicalPath.startsWith(dir.canonicalPath)) {
                return resp("{\"error\":\"not found\"}", 404)
            }
            val text = try { FileInputStream(f).use { it.readBytes().toString(Charsets.UTF_8) } }
                catch (t: Throwable) { return resp("{\"error\":\"" + t.message + "\"}", 500) }
            return newFixedLengthResponse(
                Response.Status.OK, "text/markdown; charset=utf-8", text
            )
        }
        val arr = JSONArray()
        dir.listFiles { it.isFile }?.forEach { f ->
            try {
                FileInputStream(f).use { ins ->
                    val text = ins.readBytes().toString(Charsets.UTF_8)
                    arr.put(JSONObject().put("name", f.name).put("size", f.length()))
                }
            } catch (_: Throwable) { }
        }
        return resp(JSONObject().put("skills", arr).put("dir", dir.absolutePath).toString(), 200)
    }

    private fun resp(s: String, code: Int): Response {
        val st = Response.Status.lookup(code) ?: Response.Status.INTERNAL_ERROR
        return newFixedLengthResponse(st, "application/json", s)
    }
}
