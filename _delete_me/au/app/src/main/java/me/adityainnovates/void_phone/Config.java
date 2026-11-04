package me.adityainnovates.void_phone;

import android.content.Context;
import android.content.SharedPreferences;

/** Remembers the Mac address, the paired device key, and your toggles. */
public final class Config {
    private static final String FILE = "void";
    private final SharedPreferences prefs;

    public Config(Context context) {
        prefs = context.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    /** Default to the subdomain; you can change it in the app. */
    public String macUrl() {
        return prefs.getString("macUrl", "wss://void.adityainnovates.me");
    }

    public void setMacUrl(String url) {
        prefs.edit().putString("macUrl", url.trim()).apply();
    }

    /** The long random key the Mac gave us when pairing. Null until paired. */
    public String deviceKey() {
        return prefs.getString("deviceKey", null);
    }

    public void setDeviceKey(String key) {
        prefs.edit().putString("deviceKey", key).apply();
    }

    public boolean isPaired() {
        return deviceKey() != null;
    }

    public void unpair() {
        prefs.edit().remove("deviceKey").apply();
    }

    public String macName() {
        return prefs.getString("macName", "your Mac");
    }

    public void setMacName(String name) {
        prefs.edit().putString("macName", name).apply();
    }

    public String deviceName() {
        return prefs.getString("deviceName", android.os.Build.MODEL);
    }

    public void setDeviceName(String name) {
        prefs.edit().putString("deviceName", name).apply();
    }

    /** Phase 0 tuning log. Off until you turn it on. */
    public boolean recordLog() {
        return prefs.getBoolean("recordLog", false);
    }

    public void setRecordLog(boolean on) {
        prefs.edit().putBoolean("recordLog", on).apply();
    }

    public boolean mirrorNotifications() {
        return prefs.getBoolean("mirror", true);
    }

    public void setMirrorNotifications(boolean on) {
        prefs.edit().putBoolean("mirror", on).apply();
    }
}
