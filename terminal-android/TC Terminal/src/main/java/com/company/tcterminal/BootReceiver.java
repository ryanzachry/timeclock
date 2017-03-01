package com.company.tcterminal;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 *
 */
public class BootReceiver extends BroadcastReceiver {

    /**
     *
     */
    @Override
    public void onReceive(Context context, Intent intent) {
        Intent fullscreenIntent = new Intent(context, FullscreenActivity.class);
        fullscreenIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        context.startActivity(fullscreenIntent);
    }

}
