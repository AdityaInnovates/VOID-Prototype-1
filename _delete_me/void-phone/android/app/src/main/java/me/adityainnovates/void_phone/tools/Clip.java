package me.adityainnovates.void_phone.tools;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;

/** The phone clipboard, for "send this to my phone" and back. */
public final class Clip {
    public static void set(Context context, String text) {
        ClipboardManager cm = (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("VOID", text == null ? "" : text));
    }

    public static String get(Context context) {
        ClipboardManager cm = (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm == null || !cm.hasPrimaryClip() || cm.getPrimaryClip().getItemCount() == 0) return "";
        CharSequence text = cm.getPrimaryClip().getItemAt(0).getText();
        return text == null ? "" : text.toString();
    }
}
