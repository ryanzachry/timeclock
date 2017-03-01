package com.company.tcterminal;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;
import android.webkit.JavascriptInterface;
import android.widget.Toast;

/**
 * These methods will be available to the web page loaded in WebView. Suppress warnings
 * since none of these methods are called in our code.
 */
@SuppressWarnings("unused")
public class JSExported {

    private final Activity activity;
    private long lastCheck = 0;
    public boolean hideUI;


    /**
     * @param a Context that Toast messages will be sent to.
     */
    public JSExported(Activity a) {
        activity = a;
        hideUI = true;
        lastCheck = SystemClock.elapsedRealtime();
    }

    /**
     * Gets the number of seconds that have passed since JS has last checked in.
     *
     * @return Time since last check in
     */
    public long timeSinceCheckIn() {
        return (SystemClock.elapsedRealtime() - lastCheck) / 1000;
    }

    /**
     * Bumps the check in time.
     */
    @JavascriptInterface
    public void checkIn() {
        lastCheck = SystemClock.elapsedRealtime();
    }


    /**
     * Reboots the device. Requires the devices to be rooted, also make sure SuperUser
     * knows that this application is allowed to "su".
     */
    @JavascriptInterface
    public void reboot() {
        try {
            Runtime.getRuntime().exec(new String[] { "su", "-c", "reboot now" }).waitFor();
        } catch (Exception e) {
            Toast.makeText(activity, e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    /**
     *
     */
    @JavascriptInterface
    public void openSettings() {
        try {
            Intent i = new Intent(Settings.ACTION_APPLICATION_SETTINGS);
            activity.startActivity(i);
        } catch (Exception e) {
            Toast.makeText(activity, "Unable to open settings...", Toast.LENGTH_SHORT).show();
        }
    }

    /**
     *
     */
    @JavascriptInterface
    public void hideUIBars() { hideUI = true; }

    @JavascriptInterface
    public void showUIBars() { hideUI = false; }

    /**
     *
     */
    @JavascriptInterface
    public void setActive(boolean state) {
        // setting a public bool in the broadcast receiver didn't work
        SharedPreferences states = activity.getSharedPreferences("states", Context.MODE_PRIVATE);
        SharedPreferences.Editor edit = states.edit();
        edit.putBoolean("keepActive", state);
        edit.commit();
    }


    @JavascriptInterface
    public boolean isActive() {
        boolean keepActive = activity.getSharedPreferences("states", Context.MODE_PRIVATE).getBoolean("keepActive", true);
        return keepActive;
    }


}