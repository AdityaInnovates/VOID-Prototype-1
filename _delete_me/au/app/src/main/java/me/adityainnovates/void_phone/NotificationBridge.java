package me.adityainnovates.void_phone;

import android.app.Notification;
import android.app.PendingIntent;
import android.app.RemoteInput;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Watches the phone's notifications. New ones go up to the Mac as events; a notification
 * that supports inline reply (WhatsApp, Messages, Telegram…) is remembered so VOID can
 * answer it with your voice.
 */
public class NotificationBridge extends NotificationListenerService {
    private static NotificationBridge instance;
    /** Remembered reply actions, keyed by notification key. */
    private static final Map<String, Notification.Action> replies = new LinkedHashMap<>();
    /** The latest notifications, keyed so an update replaces its earlier copy. */
    private static final Map<String, JSONObject> latest = new LinkedHashMap<>();

    @Override
    public void onListenerConnected() {
        instance = this;
    }

    @Override
    public void onListenerDisconnected() {
        instance = null;
    }

    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        if (sbn == null || sbn.getNotification() == null) return;
        NotificationLog.record(this, "posted", 0, sbn, getCurrentRanking());
        Notification notification = sbn.getNotification();
        if ((notification.flags & Notification.FLAG_ONGOING_EVENT) != 0 && !hasReply(notification)) return;
        if (getPackageName().equals(sbn.getPackageName())) return;

        Bundle extras = notification.extras;
        String title = text(extras, Notification.EXTRA_TITLE);
        String body = text(extras, Notification.EXTRA_TEXT);
        if (title.isEmpty() && body.isEmpty()) return;

        Notification.Action replyAction = findReplyAction(notification);
        String key = sbn.getKey();
        if (replyAction != null) replies.put(key, replyAction);

        JSONObject data = new JSONObject();
        try {
            data.put("key", key);
            data.put("app", appLabel(sbn.getPackageName()));
            data.put("pkg", sbn.getPackageName());
            data.put("title", title);
            data.put("text", body);
            data.put("canReply", replyAction != null);
            data.put("at", sbn.getPostTime());
            data.put("silent", (notification.flags & Notification.FLAG_ONGOING_EVENT) != 0);
        } catch (Exception ignored) {
        }
        latest.put(key, data);
        trim(latest, 60);
        trim(replies, 40);

        LinkService service = LinkService.get();
        if (service != null) service.sendEvent("notification", data);
    }

    @Override
    public void onNotificationRemoved(StatusBarNotification sbn, RankingMap rankingMap, int reason) {
        NotificationLog.record(this, "removed", reason, sbn, rankingMap);
        super.onNotificationRemoved(sbn, rankingMap, reason);
    }

    @Override
    public void onNotificationRemoved(StatusBarNotification sbn) {
        if (sbn == null) return;
        String key = sbn.getKey();
        replies.remove(key);
        latest.remove(key);
        LinkService service = LinkService.get();
        if (service != null) {
            try {
                JSONObject data = new JSONObject();
                data.put("key", key);
                service.sendEvent("notification.removed", data);
            } catch (Exception ignored) {
            }
        }
    }

    /** The notifications currently on the phone, newest last, for notifications.list. */
    public static JSONArray snapshot() {
        JSONArray out = new JSONArray();
        for (JSONObject value : latest.values()) out.put(value);
        return out;
    }

    /** Sends an inline reply to a remembered notification. Returns false if it's gone. */
    public static boolean reply(String key, String message) {
        Notification.Action action = replies.get(key);
        if (action == null || instance == null) return false;
        RemoteInput[] inputs = action.getRemoteInputs();
        if (inputs == null || inputs.length == 0) return false;
        try {
            android.content.Intent intent = new android.content.Intent();
            Bundle results = new Bundle();
            for (RemoteInput input : inputs) results.putCharSequence(input.getResultKey(), message);
            RemoteInput.addResultsToIntent(inputs, intent, results);
            action.actionIntent.send(instance, 0, intent);
            return true;
        } catch (PendingIntent.CanceledException e) {
            replies.remove(key);
            return false;
        }
    }

    private boolean hasReply(Notification notification) {
        return findReplyAction(notification) != null;
    }

    private Notification.Action findReplyAction(Notification notification) {
        if (notification.actions == null) return null;
        for (Notification.Action action : notification.actions) {
            if (action.getRemoteInputs() != null && action.getRemoteInputs().length > 0) return action;
        }
        return null;
    }

    private String appLabel(String pkg) {
        try {
            PackageManager pm = getPackageManager();
            return pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString();
        } catch (Exception e) {
            return pkg;
        }
    }

    private String text(Bundle extras, String key) {
        CharSequence value = extras == null ? null : extras.getCharSequence(key);
        return value == null ? "" : value.toString();
    }

    private static <T> void trim(Map<String, T> map, int max) {
        while (map.size() > max) {
            String oldest = map.keySet().iterator().next();
            map.remove(oldest);
        }
    }
}
