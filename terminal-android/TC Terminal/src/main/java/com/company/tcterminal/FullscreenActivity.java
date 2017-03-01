package com.company.tcterminal;

import com.company.tcterminal.alarm.ActiveAlarm;
import com.company.tcterminal.alarm.RebootAlarm;
import com.company.tcterminal.alarm.UpdateAlarm;
import com.company.tcterminal.util.Helpers;
import com.company.tcterminal.util.SystemUiHider;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.os.AsyncTask;
import android.os.Bundle;
import android.os.PowerManager;
import android.os.StrictMode;
import android.provider.Settings;
import android.util.Log;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.ConsoleMessage;
import android.webkit.WebChromeClient;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import org.json.JSONObject;

import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Timer;
import java.util.TimerTask;

/**
 * Only activity the application has. Loads up HTTP_SERVER and makes sure to keep
 * re-trying when the network or page is down.
 */

public class FullscreenActivity extends Activity {

    // URLs for a few different pages
    private static final String HTTP_SERVER = "http://10.0.0.2:3428";
    private static final String URL_MAIN    = HTTP_SERVER + "/main";
    private static final String URL_PING    = HTTP_SERVER + "/ping";
    private static final String URL_ERROR   = "file:///android_asset/error.html";
//    private static final String URL_ERROR   = HTTP_SERVER + "/error.html";

    private boolean networkDown = false;
    private PowerManager.WakeLock pmWakeLock;
    private SystemUiHider uiHider;
    private JSExported jsExp;
    private Helpers fetcher;
    private Timer checkTimer;

    /**
     *
     * @param savedInstanceState Standard from override.
     */
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        setContentView(R.layout.activity_fullscreen);
        final WebView contentView = (WebView)findViewById(R.id.fullscreen_webview);

        // set up all alarms
        ActiveAlarm activeAlarm = new ActiveAlarm(this);
        RebootAlarm rebootAlarm = new RebootAlarm(this);
        UpdateAlarm updateAlarm = new UpdateAlarm(this);

        // To toggle the top and bottom bars
        uiHider = SystemUiHider.getInstance(this, contentView, SystemUiHider.FLAG_HIDE_NAVIGATION);
        uiHider.setup();

        fetcher = new Helpers(this);
        jsExp = new JSExported(this);

        // the app should start at boot but will be behind the lock screen
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                + WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                + WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                + WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD);

        // keep the screen on
        final PowerManager powerMan = (PowerManager)getSystemService(Context.POWER_SERVICE);
        pmWakeLock = powerMan.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Wake");

        // allow network activity in the main thread
        StrictMode.ThreadPolicy policy = new StrictMode.ThreadPolicy.Builder().permitAll().build();
        StrictMode.setThreadPolicy(policy);

        contentView.getSettings().setJavaScriptEnabled(true);
        contentView.addJavascriptInterface(jsExp, "android");
        contentView.clearCache(true);

        // We want to provide some id for the server, adding a header requires overriding each
        // request which proved to be not worth it. Setting the user agent will work
        try {
            PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            final String appVersion = info.versionName + "." + info.versionCode;
            final String androidID = Settings.Secure.getString(getContentResolver(), Settings.Secure.ANDROID_ID);
            contentView.getSettings().setUserAgentString("Company TC-Terminal: " + "[ id:"+androidID+" version:"+appVersion+" ]");
        } catch (Exception e) {
            //
        }

        contentView.setWebViewClient(new WebViewClient() {
            @Override
            public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {
                super.onReceivedError(view, errorCode, description, failingUrl);
                view.loadUrl(URL_ERROR);
                networkDown = true;
            }
        });


        contentView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(@SuppressWarnings("all") ConsoleMessage cm) {
                Log.d("Web Console", cm.message() + " -- From line " + cm.lineNumber() + " of " + cm.sourceId());
                Toast.makeText(getBaseContext(), cm.message(), Toast.LENGTH_SHORT).show();
                return true;
            }
        });

    } // end of onCreate()


    /**
     *
     *
     */
    @Override
    protected void onPostCreate(Bundle savedInstanceState) {
        super.onPostCreate(savedInstanceState);
        jsExp.hideUIBars();
    }


    /**
     *
     *
     */
    @Override
    public void onResume() {
        super.onResume();
        pmWakeLock.acquire();
        jsExp.hideUIBars();
        jsExp.setActive(true);
        WebView webview = (WebView)findViewById(R.id.fullscreen_webview);
        webview.loadUrl(URL_MAIN + "?_=" + System.currentTimeMillis());
        startCheckTimer();
    }


    /**
     *
     *
     */
    @Override
    public void onPause() {
        super.onPause();
        WebView webview = (WebView)findViewById(R.id.fullscreen_webview);
        webview.loadData("", "UTF8", "text/html");
        stopCheckTimer();
    }


    /**
     *
     *
     */
    @Override
    public void onDestroy() {
        super.onDestroy();
        pmWakeLock.release();
    }


    private void startCheckTimer() {
        final Checker c = new Checker(this);
        checkTimer = new Timer();
        checkTimer.schedule(new TimerTask() {
            @Override
            public void run() {
                c.execute();
//                runOnUiThread(checkTimerTick);
            }
        }, 0, 2000);
    }

    private void stopCheckTimer() {
        checkTimer.cancel();
        checkTimer.purge();
    }

    private Runnable checkTimerTick = new Runnable() {
        @Override
        public void run() {
            // Constantly set hide / show of the UI to catch any missed events and let the
            // javascript change it whenever. Also checking to see if the server is back
            // when it had been offline.
            if (jsExp.hideUI) uiHider.hide();
            else              uiHider.show();

            Log.d("CHECK_IN", "Last checked in: " + jsExp.timeSinceCheckIn() + " second(s) ago.");
            if (jsExp.timeSinceCheckIn() > 4) networkDown = true;
            try {
                // try and hit the server, if it's back reload the webpage to the server
                JSONObject json = fetcher.fetchJSON(URL_PING + "?_=" + System.currentTimeMillis());
                WebView webview = (WebView)findViewById(R.id.fullscreen_webview);
                if (json != null && json.getString("pong").equals("pong")) {
                    if (networkDown) {
                        networkDown = false;
                        webview.loadUrl(URL_MAIN + "?_=" + System.currentTimeMillis());
                    }
                }
                else {
                    networkDown = true;
                    if (!webview.getUrl().equals(URL_ERROR)) {
                        webview.loadUrl(URL_ERROR);
                    }
                }
            } catch (Exception e) {
                networkDown = true;
            }
        }
    };

}

