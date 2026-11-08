package com.psyche.kelivo.live2d

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.view.Gravity
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import fi.iki.elonen.NanoHTTPD
import java.io.ByteArrayInputStream
import java.io.InputStream

/**
 * npu18: Live2D floating pet for Kelivo.
 * - Serves bundled assets (js + models) over a local HTTP server (127.0.0.1:18888)
 *   because WebGL in WebView cannot fetch via file:// cross-origin.
 * - Shows a TYPE_APPLICATION_OVERLAY WebView with a transparent pixi-live2d canvas.
 * - JS bridge exposes KelivoL2D.returnMessage() so the assistant's chat reply
 *   can be spoken by the model (lip-sync driven by the web layer).
 */
object Live2dService {

    const val PORT = 18888
    const val PREF = "live2d_prefs"
    const val KEY_ENABLED = "enabled"
    const val KEY_MODEL = "model_path"

    private var server: AssetHttpServer? = null
    private var floating: FloatingWindow? = null

    fun start(context: Context) {
        if (server == null) {
            server = AssetHttpServer(PORT).also { it.start(SOCKET_TIMEOUT, false) }
        }
    }

    fun stop(context: Context) {
        floating?.hide()
        floating = null
        server?.stop()
        server = null
    }

    fun isServerRunning(): Boolean = server != null

    fun show(context: Context, modelPath: String) {
        start(context)
        if (floating == null) floating = FloatingWindow(context.applicationContext)
        floating?.show(modelPath)
    }

    fun hide(context: Context) {
        floating?.hide()
        floating = null
    }

    fun isShowing(): Boolean = floating != null && floating!!.isShowing()

    /** Called from chat layer so the model can lip-sync the assistant reply. */
    fun speak(text: String) {
        floating?.eval("window.kelivoSpeak && window.kelivoSpeak(${jsString(text)})")
    }

    private fun jsString(s: String): String {
        val sb = StringBuilder("\"")
        for (ch in s) {
            when (ch) {
                '\\' -> sb.append("\\\\")
                '"' -> sb.append("\\\"")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '<' -> sb.append("\\u003c")
                else -> if (ch.code < 0x20) sb.append("\\u%04x".format(ch.code)) else sb.append(ch)
            }
        }
        sb.append("\"")
        return sb.toString()
    }

    /** Minimal HTTP server over android assets (assets/live2d/*). */
    class AssetHttpServer(port: Int) : NanoHTTPD("127.0.0.1", port) {
        private val mime = mapOf(
            "html" to "text/html",
            "js" to "application/javascript",
            "json" to "application/json",
            "png" to "image/png",
            "jpg" to "image/jpeg",
            "webp" to "image/webp",
            "moc3" to "application/octet-stream",
            "bin" to "application/octet-stream",
            "physics3" to "application/json",
            "cdi3" to "application/json",
            "exp3" to "application/json",
            "model3" to "application/json",
            "user3" to "application/json",
            "csv" to "text/plain",
            "wav" to "audio/wav",
            "ogg" to "audio/ogg",
        )

        override fun serve(session: IHTTPSession): Response {
            var path = session.uri.trimStart('/')
            // WebView percent-encodes non-ASCII asset names (e.g. 小恶魔); decode back.
            try { path = java.net.URLDecoder.decode(path, "UTF-8") } catch (_: Exception) {}
            if (path.isEmpty()) path = "index.html"
            // Map: /js/* -> assets/live2d/js/*, /models/* -> assets/live2d/models/*,
            // /live2d.html -> embedded page
            if (path == "live2d.html") {
                return newChunkedResponse(Response.Status.OK, "text/html",
                    ByteArrayInputStream(HTML.toByteArray()))
            }
            val assetPath = "live2d/$path"
            return try {
                val ctx = appContext ?: return notFound()
                val stream: InputStream = ctx.assets.open(assetPath)
                val ext = assetPath.substringAfterLast('.', "").lowercase()
                newChunkedResponse(Response.Status.OK, mime[ext] ?: "application/octet-stream", stream)
            } catch (e: Exception) {
                notFound()
            }
        }

        private fun notFound(): Response =
            newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "not found")
    }

    @SuppressLint("SetJavaScriptEnabled")
    class FloatingWindow(private val context: Context) {
        private var webView: WebView? = null
        private var wm: WindowManager? = null
        private var added = false

        @Suppress("DEPRECATION")
        fun show(modelPath: String) {
            if (added) { load(modelPath); return }
            wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        or WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED
                        or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            )
            params.gravity = Gravity.BOTTOM or Gravity.START
            webView = WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.mediaPlaybackRequiresUserGesture = false
                setBackgroundColor(0)
                setLayerType(WebView.LAYER_TYPE_HARDWARE, null)
                addJavascriptInterface(Bridge(), "KelivoL2D")
                webViewClient = object : WebViewClient() {}
                load(modelPath)
            }
            try {
                wm?.addView(webView, params)
                added = true
            } catch (e: Exception) {
                webView = null
            }
        }

        fun load(modelPath: String) {
            webView?.post {
                webView?.loadUrl("http://127.0.0.1:$PORT/live2d.html?model=${java.net.URLEncoder.encode(modelPath, "UTF-8")}")
            }
        }

        fun eval(js: String) {
            webView?.post { webView?.evaluateJavascript(js, null) }
        }

        fun isShowing(): Boolean = added

        fun hide() {
            try {
                if (added) wm?.removeView(webView)
            } catch (_: Exception) {}
            webView?.destroy()
            webView = null
            added = false
        }

        /** JS bridge: chat replies flow here so the web layer can lip-sync. */
        class Bridge {
            @JavascriptInterface
            fun onReady() { /* reserved */ }
            @JavascriptInterface
            fun onError(msg: String) { /* reserved */ }
            @JavascriptInterface
            fun onReturnMessage(msg: String) { /* reserved for future two-way chat */ }
        }
    }

    private var appContext: Context? = null
    fun initContext(context: Context) { appContext = context.applicationContext }

    private const val SOCKET_TIMEOUT = 5000

    /**
     * Embedded page: pixi + pixi-live2d-display + cubism core from /js,
     * GL safety patches ported from Stardust Live2DWebView (mipmap/REPEAT/
     * premultiply alpha), idle motion loop, transparent full-screen canvas.
     */
    private val HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden;height:100%}
canvas{display:block}</style>
<script>
// ==== GL safety patches (ported from Stardust Live2DWebView.kt) ====
(function(){
  try {
    var _origGetContext = HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext = function(type){
      var ctx = _origGetContext.apply(this, arguments);
      if (ctx && (type==='webgl2'||type==='webgl'||type==='experimental-webgl')) {
        try {
          var _origTP = ctx.texParameteri.bind(ctx);
          ctx.texParameteri = function(target,pname,param){
            if (target === ctx.TEXTURE_2D){
              if (pname === ctx.TEXTURE_MIN_FILTER){
                if (param===ctx.LINEAR_MIPMAP_LINEAR||param===ctx.LINEAR_MIPMAP_NEAREST||
                    param===ctx.NEAREST_MIPMAP_LINEAR||param===ctx.NEAREST_MIPMAP_NEAREST){
                  return _origTP(target,pname,ctx.LINEAR);
                }
              }
              if ((pname===ctx.TEXTURE_WRAP_S||pname===ctx.TEXTURE_WRAP_T)&&
                  (param===ctx.REPEAT||param===ctx.MIRRORED_REPEAT)){
                return _origTP(target,pname,ctx.CLAMP_TO_EDGE);
              }
            }
            return _origTP(target,pname,param);
          };
          var _origPS = ctx.pixelStorei.bind(ctx);
          ctx.pixelStorei = function(pname,param){
            if (pname===ctx.UNPACK_PREMULTIPLY_ALPHA_WEBGL) return _origPS(pname,true);
            return _origPS(pname,param);
          };
          ctx.generateMipmap = function(){};
        } catch(e){}
      }
      return ctx;
    };
  } catch(e){}
})();
</script>
<script src="/js/live2dcubismcore.min.js"></script>
<script src="/js/pixi.min.js"></script>
<script src="/js/pixi-live2d-display.min.js"></script>
</head>
<body>
<script>
var app=null, model=null, natW=0, natH=0;
function qs(k){ var m=location.search.match(new RegExp('[?&]'+k+'=([^&]*)')); return m?decodeURIComponent(m[1]):''; }
function boot(){
  try { PIXI.live2d.Live2DModel.registerTicker(PIXI.Ticker); } catch(e){}
  app = new PIXI.Application({ backgroundAlpha: 0, autoDensity: true, resolution: Math.min(window.devicePixelRatio||1, 2),
    width: window.innerWidth, height: window.innerHeight });
  document.body.appendChild(app.view);
  window.addEventListener('resize', function(){
    app.renderer.resize(window.innerWidth, window.innerHeight);
    if (model) fit();
  });
  var rel = qs('model') || 'models/PurpleBird/PurpleBird.model3.json';
  PIXI.live2d.Live2DModel.from('/' + rel).then(function(m){
    model = m;
    natW = m.width; natH = m.height; // natural size at scale 1
    app.stage.addChild(m);
    fit();
    // entrance: bottom, slightly right
    m.x = window.innerWidth * 0.62;
    m.y = window.innerHeight;
    startIdleLoop();
  }).catch(function(e){ document.title='ERR:'+e; });
}
function fit(){
  if (!model || !natW || !natH) return;
  var scale = Math.min((window.innerHeight*0.75)/natH,
                       (window.innerWidth*0.6)/natW);
  if (!isFinite(scale) || scale<=0) scale = 0.5;
  model.scale.set(scale);
}
// idle motion loop (pixi-live2d-display does not auto-loop idle motions)
var _lastMotionAt = 0;
function startIdleLoop(){
  setInterval(function(){
    try {
      if (!model) return;
      if (Date.now() - _lastMotionAt < 6000) return;
      var mm = model.internalModel && model.internalModel.motionManager;
      if (!mm) return;
      var defs = mm.definitions || mm.motionGroups || {};
      var keys = Object.keys(defs);
      if (!keys.length) return;
      var grp = keys[0];
      for (var i=0;i<keys.length;i++){ if (keys[i].toLowerCase()==='idle'){ grp=keys[i]; break; } }
      var arr = defs[grp]||[];
      if (!arr.length) return;
      model.motion(grp, Math.floor(Math.random()*arr.length));
      _lastMotionAt = Date.now();
    } catch(e){}
  }, 9000);
}
// chat layer calls: kelivoSpeak(text) -> simple mouth movement while visible
window.kelivoSpeak = function(text){
  try {
    if (!model) return;
    _lastMotionAt = Date.now();
    var core = model.internalModel.coreModel;
    var dur = Math.min(9000, Math.max(1500, (text||'').length*90));
    var t0 = Date.now();
    clearInterval(window.__mouthTimer);
    window.__mouthTimer = setInterval(function(){
      var p = (Date.now()-t0)/dur;
      if (p >= 1) { clearInterval(window.__mouthTimer); core.setParameterValueById('ParamMouthOpenY', 0); return; }
      core.setParameterValueById('ParamMouthOpenY', Math.abs(Math.sin(Date.now()/90))*0.6);
    }, 50);
  } catch(e){}
};
boot();
</script>
</body></html>"""
}