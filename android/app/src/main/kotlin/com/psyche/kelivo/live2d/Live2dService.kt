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
import java.net.URLDecoder
import java.net.URLEncoder

object Live2dService {
    const val PORT = 18888
    private const val SOCKET_TIMEOUT = 5000

    private var appContext: Context? = null
    private var server: AssetHttpServer? = null
    private var floating: FloatingWindow? = null

    fun initContext(context: Context) {
        appContext = context.applicationContext
    }

    fun start(context: Context) {
        initContext(context)
        if (server == null) {
            val s = AssetHttpServer(PORT)
            s.start(SOCKET_TIMEOUT, false)
            server = s
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
        if (floating == null) {
            floating = FloatingWindow(context.applicationContext)
        }
        floating?.show(modelPath)
    }

    fun hide(context: Context) {
        floating?.hide()
        floating = null
    }

    fun isShowing(): Boolean {
        val f = floating
        return f != null && f.isShowing()
    }

    fun speak(text: String) {
        floating?.eval("window.kelivoSpeak && window.kelivoSpeak(" + jsString(text) + ")")
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
                else -> {
                    if (ch.code < 0x20) {
                        sb.append("\\u%04x".format(ch.code))
                    } else {
                        sb.append(ch)
                    }
                }
            }
        }
        sb.append("\"")
        return sb.toString()
    }

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
            "ogg" to "audio/ogg"
        )

        override fun serve(session: IHTTPSession): Response {
            var path = session.uri.trimStart('/')
            try {
                path = URLDecoder.decode(path, "UTF-8")
            } catch (e: Exception) {}

            if (path.isEmpty()) path = "index.html"
            if (path == "live2d.html") {
                return newChunkedResponse(
                    Response.Status.OK,
                    "text/html",
                    ByteArrayInputStream(HTML.toByteArray(Charsets.UTF_8))
                )
            }

            val assetPath = "live2d/" + path
            return try {
                val ctx = appContext ?: return notFound()
                val stream: InputStream = ctx.assets.open(assetPath)
                val ext = assetPath.substringAfterLast('.', "").lowercase()
                newChunkedResponse(
                    Response.Status.OK,
                    mime[ext] ?: "application/octet-stream",
                    stream
                )
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
            if (added) {
                load(modelPath)
                return
            }
            wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                WindowManager.LayoutParams.TYPE_PHONE
            }
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                        WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
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
                try {
                    val encoded = URLEncoder.encode(modelPath, "UTF-8")
                    webView?.loadUrl("http://127.0.0.1:" + PORT + "/live2d.html?model=" + encoded)
                } catch (e: Exception) {}
            }
        }

        fun eval(js: String) {
            webView?.post {
                webView?.evaluateJavascript(js, null)
            }
        }

        fun isShowing(): Boolean = added

        fun hide() {
            if (!added) return
            try {
                if (webView != null) {
                    wm?.removeView(webView)
                }
            } catch (e: Exception) {}
            webView?.destroy()
            webView = null
            added = false
        }

        class Bridge {
            @JavascriptInterface
            fun onReady() {}

            @JavascriptInterface
            fun onError(msg: String) {}

            @JavascriptInterface
            fun onReturnMessage(msg: String) {}
        }
    }

    private val HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden;height:100%}
canvas{display:block}</style>
<script>
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
          var _origPB = ctx.pixelStorei.bind(ctx);
          ctx.pixelStorei = function(pname,param){
            if (pname === ctx.UNPACK_PREMULTIPLY_ALPHA_WEBGL && param === true) {
              return;
            }
            return _origPB(pname,param);
          };
        } catch(e){}
      }
      return ctx;
    };
  } catch(e){}
})();
</script>
<script src="http://127.0.0.1:18888/js/live2dcubismcore.min.js"></script>
<script src="http://127.0.0.1:18888/js/live2d.min.js"></script>
<script src="http://127.0.0.1:18888/js/pixi.min.js"></script>
<script src="http://127.0.0.1:18888/js/pixi-live2d-display.min.js"></script>
</head>
<body>
<canvas id="c"></canvas>
<script>
var app=null, model=null, natW=0, natH=0;
function qs(k){ var m=location.search.match(new RegExp('[?&]'+k+'=([^&]*)')); return m?decodeURIComponent(m[1]):''; }

function initPixi(){
  PIXI.live2d.Live2DModel.registerTicker(PIXI.Ticker);
  app = new PIXI.Application({
    view: document.getElementById('c'),
    transparent: true,
    autoDensity: true,
    resizeTo: window
  });
  window.addEventListener('resize', function(){
    if (app) app.renderer.resize(window.innerWidth, window.innerHeight);
    if (model) fit();
  });
  var rel = qs('model') || 'models/PurpleBird/PurpleBird.model3.json';
  var url = 'http://127.0.0.1:18888/' + rel.replace(/^\/+/,'');
  PIXI.live2d.Live2DModel.from(url).then(function(m){
    model = m;
    app.stage.addChild(m);
    m.anchor.set(0.5, 1.0);
    natW = m.width;
    natH = m.height;
    fit();
    startIdle();
  }).catch(function(e){});
}

function fit(){
  if (!model || !natW || !natH) return;
  var sw = window.innerWidth, sh = window.innerHeight;
  var targetH = sh * 0.75;
  var targetW = sw * 0.60;
  var scale = Math.min(targetH / natH, targetW / natW);
  model.scale.set(scale);
  model.x = sw * 0.62;
  model.y = sh;
}

function startIdle(){
  setInterval(function(){
    try {
      if (!model) return;
      var mm = model.internalModel && model.internalModel.motionManager;
      if (!mm) return;
      var def = mm.definitions;
      if (!def) return;
      var grp = 'Idle' in def ? 'Idle' : ('idle' in def ? 'idle' : Object.keys(def)[0]);
      if (!grp) return;
      var arr = def[grp];
      if (!arr || !arr.length) return;
      model.motion(grp, Math.floor(Math.random()*arr.length));
    } catch(e){}
  }, 9000);
}

window.kelivoSpeak = function(text){
  try {
    if (!model) return;
    var core = model.internalModel && model.internalModel.coreModel;
    if (!core || !core.setParameterValueById) return;
    var dur = Math.max(1200, Math.min(6000, (text ? text.length : 10) * 120));
    var t0 = Date.now();
    clearInterval(window.__mouthTimer);
    window.__mouthTimer = setInterval(function(){
      var p = (Date.now()-t0)/dur;
      if (p >= 1) {
        clearInterval(window.__mouthTimer);
        core.setParameterValueById('ParamMouthOpenY', 0);
        return;
      }
      core.setParameterValueById('ParamMouthOpenY', Math.abs(Math.sin(Date.now()/90))*0.6);
    }, 50);
  } catch(e){}
};

function boot(){
  if (window.PIXI && window.PIXI.live2d) initPixi();
  else setTimeout(boot, 100);
}
boot();
</script>
</body></html>"""
}