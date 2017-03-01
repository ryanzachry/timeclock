package com.company.tcterminal.alarm;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Locale;

/**
 *
 */
public class RebootAlarm extends BroadcastReceiver {
    @SuppressWarnings("unused")
    public RebootAlarm() {}

    /**
     *
     *
     * @param context ...
     */
    public RebootAlarm(Context context) {
        AlarmManager aMgr = (AlarmManager)context.getSystemService(Context.ALARM_SERVICE);

        Calendar time = Calendar.getInstance();
        time.set(Calendar.HOUR_OF_DAY, 3);
        time.set(Calendar.MINUTE, 0);
        time.set(Calendar.SECOND, 0);
        time.set(Calendar.MILLISECOND, 0);

        // don't want to set this to the past, will get a reboot loop
        if (Calendar.getInstance().getTimeInMillis() > time.getTimeInMillis()) {
            time.add(Calendar.HOUR, 24);
        }

        Intent i = new Intent(context, RebootAlarm.class);
        PendingIntent pi = PendingIntent.getBroadcast(context, 0, i, 0);
        aMgr.set(AlarmManager.RTC_WAKEUP, time.getTimeInMillis(), pi);

        SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSSZ", Locale.US);
        Log.d("ALARM", "Reboot alarm set to: " + sdf.format(time.getTime()));
    }


    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            Runtime.getRuntime().exec(new String[] { "su", "-c", "reboot now" }).waitFor();
        } catch (Exception e) {
            // oh well...
        }
    }

}
