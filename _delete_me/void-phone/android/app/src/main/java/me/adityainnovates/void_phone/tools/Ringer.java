package me.adityainnovates.void_phone.tools;

import android.content.Context;
import android.media.AudioManager;
import android.media.Ringtone;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

/** "Find my phone": plays the ringtone at full volume even on silent, for a while. */
public final class Ringer {
    private static Ringtone ringtone;
    private static int savedVolume = -1;
    private static final Handler handler = new Handler(Looper.getMainLooper());
    private static Runnable stopper;

    public static void find(Context context, int seconds) {
        stop();
        AudioManager am = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        savedVolume = am.getStreamVolume(AudioManager.STREAM_ALARM);
        am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0);

        Uri uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE);
        if (uri == null) uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
        ringtone = RingtoneManager.getRingtone(context, uri);
        if (ringtone != null) {
            ringtone.setStreamType(AudioManager.STREAM_ALARM);
            ringtone.play();
        }
        stopper = () -> stop(context);
        handler.postDelayed(stopper, Math.max(5, Math.min(seconds, 120)) * 1000L);
    }

    public static void stop() {
        if (ringtone != null && ringtone.isPlaying()) ringtone.stop();
        ringtone = null;
        if (stopper != null) handler.removeCallbacks(stopper);
    }

    public static void stop(Context context) {
        stop();
        if (savedVolume >= 0) {
            AudioManager am = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
            am.setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0);
            savedVolume = -1;
        }
    }
}
