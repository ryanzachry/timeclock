package com.company.tcterminal.alarm;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.os.Environment;
import android.os.SystemClock;
import android.util.Log;

import com.company.tcterminal.util.Helpers;

import org.json.JSONObject;


/**
 *
 */
public class UpdateAlarm extends BroadcastReceiver {
    private static final String HTTP_SERVER = "http://10.0.0.2:3428";
    private static final String UPDATE_URL = HTTP_SERVER + "/apk/tct-update.apk";

    @SuppressWarnings("unused")
    public UpdateAlarm() {}


    public UpdateAlarm(Context context) {
        AlarmManager aMgr = (AlarmManager)context.getSystemService(Context.ALARM_SERVICE);
        Intent i = new Intent(context, UpdateAlarm.class);
        PendingIntent pi = PendingIntent.getBroadcast(context, 0, i, 0);

        aMgr.setInexactRepeating(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime(), 10000, pi);
    }



    @Override
    public void onReceive(Context context, Intent intent) {
        Helpers fetcher = new Helpers(context);
        Log.d("UPDATE_ALARM", Environment.getExternalStorageDirectory().getAbsolutePath());

        if (updateAvailable(context)) {
            String apkFile = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).getAbsolutePath() + "/tct-update.apk";
            if (fetcher.mirrorFile(UPDATE_URL, apkFile)) {
                // Uninstalling gets passed certificate errors. The new application must be run once before it will auto start at boot.
                try {
                    Runtime.getRuntime().exec(new String[] { "su", "-c", "pm uninstall com.company.tcterminal && pm install " + apkFile + " && am start com.company.tcterminal && sleep 5 && reboot"}).waitFor();
                } catch (Exception e) {
                    //
                }
            }
        }
    }



    public boolean updateAvailable(Context context) {
        try {
            Helpers fetcher = new Helpers(context);
            JSONObject json = fetcher.fetchJSON(HTTP_SERVER + "/apk/version.json");
            PackageInfo info = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
            Log.d("UPDATE_ALARM", "Our build: " + info.versionCode + ", available build: " + json.getString("versionCode"));
            if (info.versionCode < json.getInt("versionCode")) return true;
        }
        catch (NullPointerException e) { e.printStackTrace(); }
        catch (Exception e) { e.printStackTrace(); }

        return false;
    }



}
