package com.psyche.kelivo.geniex;

import com.geniex.sdk.GenieXSdk;
import android.content.Context;
import android.util.Log;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Java bridge: Kotlin metadata marks instance as private, bytecode getInstance() is public. */
public final class SdkBridge {
    private static final String TAG = "GeniexService";
    private static volatile boolean ready = false;

    public static boolean isReady() { return ready; }

    public static boolean ensure(Context context) {
        if (ready) return true;
        synchronized (SdkBridge.class) {
            if (ready) return true;
            final CountDownLatch latch = new CountDownLatch(1);
            final String[] err = new String[]{null};
            try {
                Log.w(TAG, "SdkBridge: calling getInstance()");
                GenieXSdk sdk = GenieXSdk.Companion.getInstance();
                if (sdk == null) {
                    Log.e(TAG, "SdkBridge: sdk instance null");
                    return false;
                }
                sdk.init(context, new GenieXSdk.InitCallback() {
                    @Override public void onSuccess() {
                        Log.w(TAG, "GenieXSdk init OK");
                        latch.countDown();
                    }
                    @Override public void onFailure(String message) {
                        err[0] = message;
                        Log.e(TAG, "GenieXSdk init failed: " + message);
                        latch.countDown();
                    }
                });
            } catch (Throwable t) {
                Log.e(TAG, "SdkBridge exception: " + t);
                return false;
            }
            try { latch.await(90, TimeUnit.SECONDS); } catch (InterruptedException ie) { }
            if (err[0] == null) { ready = true; return true; }
            Log.e(TAG, "sdk init error: " + err[0]);
            return false;
        }
    }
}
