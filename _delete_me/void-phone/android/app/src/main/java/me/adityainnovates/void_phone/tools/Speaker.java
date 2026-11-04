package me.adityainnovates.void_phone.tools;

import android.content.Context;
import android.speech.tts.TextToSpeech;

import java.util.Locale;

/** Speaks a line out loud on the phone (e.g. to find it, or relay a message). */
public final class Speaker {
    private static TextToSpeech tts;

    public static void say(Context context, String text) {
        if (text == null || text.isEmpty()) return;
        final String line = text;
        if (tts != null) {
            tts.speak(line, TextToSpeech.QUEUE_FLUSH, null, "void");
            return;
        }
        tts = new TextToSpeech(context.getApplicationContext(), status -> {
            if (status == TextToSpeech.SUCCESS && tts != null) {
                tts.setLanguage(Locale.getDefault());
                tts.speak(line, TextToSpeech.QUEUE_FLUSH, null, "void");
            }
        });
    }
}
