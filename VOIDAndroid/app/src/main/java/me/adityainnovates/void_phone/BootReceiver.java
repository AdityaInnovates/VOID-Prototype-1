package me.adityainnovates.void_phone;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Brings the link back up after a reboot, so VOID stays reachable. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            if (new Config(context).isPaired()) LinkService.start(context);
        }
    }
}
