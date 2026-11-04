package me.adityainnovates.void_phone.tools;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.database.Cursor;
import android.hardware.camera2.CameraManager;
import android.location.Location;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.provider.AlarmClock;
import android.provider.ContactsContract;
import android.provider.Settings;
import android.provider.Telephony;
import android.telephony.SmsManager;

import androidx.core.content.ContextCompat;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

import me.adityainnovates.void_phone.LinkService;
import me.adityainnovates.void_phone.NotificationBridge;
import me.adityainnovates.void_phone.net.LinkClient;

/**
 * Everything the Mac can ask this phone to do. One method per tool; each returns its
 * JSON answer through the callback, or fails with a short reason VOID can read aloud.
 *
 * Anything that needs a runtime permission the app doesn't hold yet fails with a clear
 * message, so VOID can tell you to open the app and grant it, rather than crashing.
 */
public class PhoneTools {
    private final Context app;

    public PhoneTools(Context context) {
        this.app = context.getApplicationContext();
    }

    public void run(String tool, JSONObject args, LinkClient.Result done) {
        try {
            switch (tool) {
                case "device.status": deviceStatus(done); break;
                case "ring":          Ringer.find(app, args.optInt("seconds", 45)); ok(done); break;
                case "ring.stop":     Ringer.stop(); ok(done); break;
                case "location.get":  location(done); break;
                case "sms.read":      readSms(args.optInt("limit", 3), done); break;
                case "sms.send":      sendSms(args.optString("to"), args.optString("body"), done); break;
                case "contacts.find": findContacts(args.optString("name"), done); break;
                case "call.start":    startCall(args.optString("number"), done); break;
                case "apps.open":     openApp(args.optString("name"), done); break;
                case "apps.list":     listApps(done); break;
                case "torch":         torch(args.optBoolean("on", true), done); break;
                case "ringer":        setRinger(args.optString("mode", "normal"), done); break;
                case "dnd":           setDnd(args.optBoolean("on", true), done); break;
                case "alarm.set":     setAlarm(args.optInt("hour"), args.optInt("minute"), args.optString("label", "VOID"), done); break;
                case "timer.set":     setTimer(args.optInt("seconds"), args.optString("label", "VOID"), done); break;
                case "clipboard.set": Clip.set(app, args.optString("text")); ok(done); break;
                case "clipboard.get": ok(done, "text", Clip.get(app)); break;
                case "notifications.list": ok(done, "notifications", NotificationBridge.snapshot()); break;
                case "notifications.reply":
                    if (NotificationBridge.reply(args.optString("key"), args.optString("text"))) ok(done);
                    else done.fail("I couldn't reply to that notification. It may have gone away.");
                    break;
                case "media":         media(args.optString("action", "toggle"), done); break;
                case "speak":         Speaker.say(app, args.optString("text")); ok(done); break;
                case "vibrate":       vibrate(args.optInt("ms", 500)); ok(done); break;
                case "lock":          lock(done); break;
                case "settings.sync": {
                    me.adityainnovates.void_phone.VoidSettings settings = me.adityainnovates.void_phone.VoidSettings.get(app);
                    settings.merge(args);
                    done.ok(settings.export());
                    break;
                }
                case "open.url":      openUrl(args.optString("url"), done); break;
                case "open.settings": openSettings(args.optString("screen", ""), done); break;
                case "tap":           Tapper.tap(args.optString("text"), done); break;
                default:              done.fail("This phone doesn't know the tool \"" + tool + "\".");
            }
        } catch (SecurityException e) {
            done.fail("I don't have permission for that yet. Open the VOID app on the phone and grant it.");
        } catch (Exception e) {
            done.fail(e.getMessage() == null ? "That didn't work on the phone." : e.getMessage());
        }
    }

    // MARK: battery / status

    private void deviceStatus(LinkClient.Result done) throws Exception {
        android.os.BatteryManager bm = (android.os.BatteryManager) app.getSystemService(Context.BATTERY_SERVICE);
        int level = bm != null ? bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY) : -1;
        boolean charging = bm != null && bm.isCharging();
        JSONObject data = new JSONObject();
        data.put("battery", level);
        data.put("charging", charging);
        data.put("model", Build.MANUFACTURER + " " + Build.MODEL);
        data.put("android", Build.VERSION.RELEASE);
        done.ok(data);
    }

    // MARK: location

    private void location(LinkClient.Result done) {
        if (missing(Manifest.permission.ACCESS_FINE_LOCATION) && missing(Manifest.permission.ACCESS_COARSE_LOCATION)) {
            done.fail("Location permission isn't granted. Open the VOID app and allow location.");
            return;
        }
        Locator.current(app, new Locator.Callback() {
            @Override public void onLocation(Location l) {
                try {
                    JSONObject data = new JSONObject();
                    data.put("lat", l.getLatitude());
                    data.put("lon", l.getLongitude());
                    data.put("accuracy", l.getAccuracy());
                    done.ok(data);
                } catch (Exception e) {
                    done.fail("Location came back malformed.");
                }
            }
            @Override public void onFailed(String why) { done.fail(why); }
        });
    }

    // MARK: SMS

    private void readSms(int limit, LinkClient.Result done) throws Exception {
        if (missing(Manifest.permission.READ_SMS)) { done.fail("SMS permission isn't granted on the phone."); return; }
        Uri uri = Telephony.Sms.Inbox.CONTENT_URI;
        String[] cols = {Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE};
        JSONArray out = new JSONArray();
        try (Cursor c = app.getContentResolver().query(uri, cols, null, null, Telephony.Sms.DATE + " DESC")) {
            int n = 0;
            while (c != null && c.moveToNext() && n < Math.max(1, Math.min(limit, 10))) {
                String address = c.getString(0);
                JSONObject m = new JSONObject();
                m.put("from", contactNameFor(address, address));
                m.put("body", c.getString(1));
                m.put("at", c.getLong(2));
                out.put(m);
                n++;
            }
        }
        JSONObject data = new JSONObject();
        data.put("messages", out);
        done.ok(data);
    }

    private void sendSms(String to, String body, LinkClient.Result done) {
        if (missing(Manifest.permission.SEND_SMS)) { done.fail("SMS-send permission isn't granted on the phone."); return; }
        if (to == null || to.isEmpty() || body == null || body.isEmpty()) { done.fail("Need a number and a message."); return; }
        SmsManager sms = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
                ? app.getSystemService(SmsManager.class) : SmsManager.getDefault();
        ArrayList<String> parts = sms.divideMessage(body);
        sms.sendMultipartTextMessage(to, null, parts, null, null);
        ok(done);
    }

    // MARK: contacts

    private void findContacts(String name, LinkClient.Result done) throws Exception {
        if (missing(Manifest.permission.READ_CONTACTS)) { done.fail("Contacts permission isn't granted on the phone."); return; }
        JSONArray out = new JSONArray();
        Uri uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI;
        String[] cols = {ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER};
        String selection = ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " LIKE ?";
        try (Cursor c = app.getContentResolver().query(uri, cols, selection, new String[]{"%" + name + "%"}, null)) {
            int n = 0;
            while (c != null && c.moveToNext() && n < 8) {
                JSONObject m = new JSONObject();
                m.put("name", c.getString(0));
                m.put("number", c.getString(1));
                out.put(m);
                n++;
            }
        }
        JSONObject data = new JSONObject();
        data.put("contacts", out);
        done.ok(data);
    }

    private String contactNameFor(String number, String fallback) {
        if (missing(Manifest.permission.READ_CONTACTS) || number == null) return fallback;
        Uri uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number));
        try (Cursor c = app.getContentResolver().query(uri, new String[]{ContactsContract.PhoneLookup.DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst()) return c.getString(0);
        } catch (Exception ignored) {
        }
        return fallback;
    }

    // MARK: calling

    private void startCall(String number, LinkClient.Result done) {
        if (number == null || number.isEmpty()) { done.fail("No number to call."); return; }
        Intent intent = new Intent(missing(Manifest.permission.CALL_PHONE) ? Intent.ACTION_DIAL : Intent.ACTION_CALL);
        intent.setData(Uri.parse("tel:" + number));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        app.startActivity(intent);
        ok(done);
    }

    // MARK: apps

    private void openApp(String name, LinkClient.Result done) {
        PackageManager pm = app.getPackageManager();
        String target = null, label = name;
        String lower = name == null ? "" : name.toLowerCase();
        Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        for (ResolveInfo info : pm.queryIntentActivities(launcher, 0)) {
            String appLabel = info.loadLabel(pm).toString();
            if (appLabel.toLowerCase().contains(lower)) {
                target = info.activityInfo.packageName;
                label = appLabel;
                if (appLabel.equalsIgnoreCase(name)) break;
            }
        }
        if (target == null) { done.fail("I couldn't find an app called " + name + "."); return; }
        Intent launch = pm.getLaunchIntentForPackage(target);
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        app.startActivity(launch);
        ok(done, "label", label);
    }

    private void listApps(LinkClient.Result done) throws Exception {
        PackageManager pm = app.getPackageManager();
        JSONArray out = new JSONArray();
        Intent main = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        for (ResolveInfo info : pm.queryIntentActivities(main, 0)) {
            out.put(info.loadLabel(pm).toString());
        }
        JSONObject data = new JSONObject();
        data.put("apps", out);
        done.ok(data);
    }

    // MARK: torch / ringer / dnd / media / vibrate

    private void torch(boolean on, LinkClient.Result done) throws Exception {
        CameraManager cm = (CameraManager) app.getSystemService(Context.CAMERA_SERVICE);
        String id = null;
        for (String candidate : cm.getCameraIdList()) {
            Boolean has = cm.getCameraCharacteristics(candidate)
                    .get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE);
            if (Boolean.TRUE.equals(has)) { id = candidate; break; }
        }
        if (id == null) { done.fail("This phone has no flashlight."); return; }
        cm.setTorchMode(id, on);
        ok(done);
    }

    private void setRinger(String mode, LinkClient.Result done) {
        AudioManager am = (AudioManager) app.getSystemService(Context.AUDIO_SERVICE);
        switch (mode) {
            case "silent":  am.setRingerMode(AudioManager.RINGER_MODE_SILENT); break;
            case "vibrate": am.setRingerMode(AudioManager.RINGER_MODE_VIBRATE); break;
            default:        am.setRingerMode(AudioManager.RINGER_MODE_NORMAL); break;
        }
        ok(done);
    }

    private void setDnd(boolean on, LinkClient.Result done) {
        android.app.NotificationManager nm =
                (android.app.NotificationManager) app.getSystemService(Context.NOTIFICATION_SERVICE);
        if (!nm.isNotificationPolicyAccessGranted()) {
            done.fail("VOID needs Do-Not-Disturb access. Open the app and grant it.");
            return;
        }
        nm.setInterruptionFilter(on ? android.app.NotificationManager.INTERRUPTION_FILTER_PRIORITY
                : android.app.NotificationManager.INTERRUPTION_FILTER_ALL);
        ok(done);
    }

    private void media(String action, LinkClient.Result done) {
        int key;
        switch (action) {
            case "next":     key = android.view.KeyEvent.KEYCODE_MEDIA_NEXT; break;
            case "previous": key = android.view.KeyEvent.KEYCODE_MEDIA_PREVIOUS; break;
            default:         key = android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE; break;
        }
        AudioManager am = (AudioManager) app.getSystemService(Context.AUDIO_SERVICE);
        am.dispatchMediaKeyEvent(new android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, key));
        am.dispatchMediaKeyEvent(new android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, key));
        ok(done);
    }

    private void lock(LinkClient.Result done) {
        android.app.admin.DevicePolicyManager dpm =
                (android.app.admin.DevicePolicyManager) app.getSystemService(Context.DEVICE_POLICY_SERVICE);
        android.content.ComponentName admin =
                new android.content.ComponentName(app, me.adityainnovates.void_phone.VoidAdminReceiver.class);
        if (dpm == null || !dpm.isAdminActive(admin)) {
            done.fail("VOID isn't a device admin yet. Turn that on in the app to lock the phone.");
            return;
        }
        dpm.lockNow();
        ok(done);
    }

    private void vibrate(int ms) {
        Vibrator v = (Vibrator) app.getSystemService(Context.VIBRATOR_SERVICE);
        if (v == null) return;
        v.vibrate(VibrationEffect.createOneShot(Math.max(50, Math.min(ms, 3000)), VibrationEffect.DEFAULT_AMPLITUDE));
    }

    // MARK: alarms / timers

    private void setAlarm(int hour, int minute, String label, LinkClient.Result done) {
        Intent intent = new Intent(AlarmClock.ACTION_SET_ALARM)
                .putExtra(AlarmClock.EXTRA_HOUR, hour)
                .putExtra(AlarmClock.EXTRA_MINUTES, minute)
                .putExtra(AlarmClock.EXTRA_MESSAGE, label)
                .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (intent.resolveActivity(app.getPackageManager()) == null) { done.fail("No clock app to set an alarm."); return; }
        app.startActivity(intent);
        ok(done);
    }

    private void setTimer(int seconds, String label, LinkClient.Result done) {
        Intent intent = new Intent(AlarmClock.ACTION_SET_TIMER)
                .putExtra(AlarmClock.EXTRA_LENGTH, Math.max(1, seconds))
                .putExtra(AlarmClock.EXTRA_MESSAGE, label)
                .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (intent.resolveActivity(app.getPackageManager()) == null) { done.fail("No clock app to set a timer."); return; }
        app.startActivity(intent);
        ok(done);
    }

    // MARK: open things

    private void openUrl(String url, LinkClient.Result done) {
        if (url == null || url.isEmpty()) { done.fail("No link to open."); return; }
        Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        app.startActivity(intent);
        ok(done);
    }

    private void openSettings(String screen, LinkClient.Result done) {
        String action;
        switch (screen) {
            case "wifi":       action = Settings.ACTION_WIFI_SETTINGS; break;
            case "bluetooth":  action = Settings.ACTION_BLUETOOTH_SETTINGS; break;
            case "location":   action = Settings.ACTION_LOCATION_SOURCE_SETTINGS; break;
            case "battery":    action = Settings.ACTION_BATTERY_SAVER_SETTINGS; break;
            default:           action = Settings.ACTION_SETTINGS; break;
        }
        app.startActivity(new Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        ok(done);
    }

    // MARK: helpers

    private boolean missing(String permission) {
        return ContextCompat.checkSelfPermission(app, permission) != PackageManager.PERMISSION_GRANTED;
    }

    private void ok(LinkClient.Result done) {
        done.ok(new JSONObject());
    }

    private void ok(LinkClient.Result done, String key, Object value) {
        try {
            JSONObject data = new JSONObject();
            data.put(key, value);
            done.ok(data);
        } catch (Exception e) {
            done.ok(new JSONObject());
        }
    }
}
