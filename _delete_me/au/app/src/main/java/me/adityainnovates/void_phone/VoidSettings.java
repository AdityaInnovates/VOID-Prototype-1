package me.adityainnovates.void_phone;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONObject;

import java.util.Calendar;

/**
 * Settings that must agree between the phone and the Mac (quiet hours for now).
 *
 * Works fully offline. Every field carries the time it was last changed, and when the two
 * sides meet each field keeps whichever change is newer, field by field. So changing quiet
 * hours on the phone while the Mac is off, then changing the timer on the Mac, keeps both.
 */
public final class VoidSettings {
    public static final String QUIET_ENABLED = "quietEnabled";   // 1 or 0
    public static final String QUIET_START = "quietStart";       // minutes after midnight
    public static final String QUIET_END = "quietEnd";           // minutes after midnight
    public static final String QUIET_UNTIL = "quietUntil";       // epoch ms; quiet until then, whatever the schedule says

    private static final String[] KEYS = {QUIET_ENABLED, QUIET_START, QUIET_END, QUIET_UNTIL};

    private static VoidSettings instance;

    private final SharedPreferences prefs;
    private final Handler main = new Handler(Looper.getMainLooper());
    private Runnable onLocalChange;
    private Runnable onRemoteChange;

    public static synchronized VoidSettings get(Context context) {
        if (instance == null) instance = new VoidSettings(context.getApplicationContext());
        return instance;
    }

    private VoidSettings(Context context) {
        prefs = context.getSharedPreferences("void-settings", Context.MODE_PRIVATE);
    }

    private static double defaultFor(String key) {
        switch (key) {
            case QUIET_ENABLED: return 1;
            case QUIET_START: return 8 * 60;
            case QUIET_END: return 18 * 60;
            default: return 0;
        }
    }

    public double value(String key) {
        return Double.longBitsToDouble(prefs.getLong("v." + key, Double.doubleToLongBits(defaultFor(key))));
    }

    private long stamp(String key) {
        return prefs.getLong("t." + key, 0L);
    }

    /** Changes a value on this device and tells the link to sync it. */
    public void set(String key, double value) {
        prefs.edit()
                .putLong("v." + key, Double.doubleToLongBits(value))
                .putLong("t." + key, System.currentTimeMillis())
                .apply();
        if (onLocalChange != null) onLocalChange.run();
    }

    public boolean quietEnabled() { return value(QUIET_ENABLED) > 0; }
    public int quietStart() { return (int) value(QUIET_START); }
    public int quietEnd() { return (int) value(QUIET_END); }
    public long quietUntil() { return (long) value(QUIET_UNTIL); }

    /** True if VOID should stay silent right now: a timer is running, or the schedule says so. */
    public boolean isQuietNow() {
        if (quietUntil() > System.currentTimeMillis()) return true;
        if (!quietEnabled()) return false;
        Calendar now = Calendar.getInstance();
        int minute = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE);
        int start = quietStart(), end = quietEnd();
        if (start == end) return false;
        return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end);
    }

    /** Quiet for a while, whatever the schedule says (a busy day). */
    public void quietFor(long millis) {
        set(QUIET_UNTIL, System.currentTimeMillis() + millis);
    }

    public void quietUntilEndOfDay() {
        Calendar end = Calendar.getInstance();
        end.set(Calendar.HOUR_OF_DAY, 23);
        end.set(Calendar.MINUTE, 59);
        end.set(Calendar.SECOND, 0);
        set(QUIET_UNTIL, end.getTimeInMillis());
    }

    public void clearTimer() {
        set(QUIET_UNTIL, 0);
    }

    // MARK: sync

    /** Everything, with change times, for the other side. */
    public JSONObject export() {
        JSONObject out = new JSONObject();
        try {
            for (String key : KEYS) {
                JSONObject field = new JSONObject();
                field.put("v", value(key));
                field.put("t", stamp(key));
                out.put(key, field);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    /** Takes the other side's newer values. Returns true if anything here changed. */
    public synchronized boolean merge(JSONObject other) {
        if (other == null) return false;
        boolean changed = false;
        SharedPreferences.Editor edit = prefs.edit();
        for (String key : KEYS) {
            JSONObject field = other.optJSONObject(key);
            if (field == null) continue;
            long theirs = (long) field.optDouble("t", 0);
            if (theirs > stamp(key)) {
                edit.putLong("v." + key, Double.doubleToLongBits(field.optDouble("v", defaultFor(key))));
                edit.putLong("t." + key, theirs);
                changed = true;
            }
        }
        edit.apply();
        if (changed && onRemoteChange != null) main.post(onRemoteChange);
        return changed;
    }

    public void setOnLocalChange(Runnable r) { onLocalChange = r; }
    public void setOnRemoteChange(Runnable r) { onRemoteChange = r; }
}
