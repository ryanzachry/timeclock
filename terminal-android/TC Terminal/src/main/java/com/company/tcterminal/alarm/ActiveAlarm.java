package com.company.tcterminal.alarm;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.Log;

import com.company.tcterminal.FullscreenActivity;

import java.util.List;

public class ActiveAlarm extends BroadcastReceiver {

    // Period between checks in seconds
    private static final int INTERVAL = 1;

//    public boolean keepActive;

    @SuppressWarnings("unused")
    public ActiveAlarm() { }
    public ActiveAlarm(Context context) {

        AlarmManager aMgr = (AlarmManager)context.getSystemService(Context.ALARM_SERVICE);
        Intent i = new Intent(context, ActiveAlarm.class);
        PendingIntent pi = PendingIntent.getBroadcast(context, 0, i, 0);
        aMgr.setRepeating(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime(), INTERVAL * 1000, pi);
    }



    @Override
    public void onReceive(Context context, Intent intent) {
        boolean keepActive = context.getSharedPreferences("states", Context.MODE_PRIVATE).getBoolean("keepActive", true);
        if (!keepActive) return;

        Log.d("ACTIVE_ALARM", "Tick");

        String appRunning = null;
        ActivityManager am = (ActivityManager)context.getSystemService(Activity.ACTIVITY_SERVICE);
        List<ActivityManager.RunningTaskInfo> ti = am.getRunningTasks(1);
        if (ti != null) {
            ComponentName cn = ti.get(0).topActivity;
            if (cn != null) {
                appRunning = cn.getPackageName();
            }
        }

        PowerManager pm = (PowerManager)context.getSystemService(Context.POWER_SERVICE);

        if (!pm.isScreenOn() || appRunning == null || !appRunning.equals("com.company.tcterminal")) {
            Log.i("ALARM", "TC Terminal is not active, starting activity!");

            Intent i = new Intent(context, FullscreenActivity.class);
            // CLEAR_TOP will do enough to cause the screen to wake
            i.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(i);
        }
    }
}
