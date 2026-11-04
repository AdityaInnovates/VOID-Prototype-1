package me.adityainnovates.void_phone;

import android.app.Notification;
import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.os.Parcelable;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;

/**
 * Phase 0: records what Android actually gives us for each notification (category, channel,
 * ranking, people, reply actions...) so the importance scorer can be built on facts, not guesses.
 *
 * Off until you turn it on. Stays on the phone until you tap "Send log to Mac". Number runs of
 * 4-8 digits (OTPs, card digits) are masked, and text is cut to 200 characters.
 */
public final class NotificationLog {
    private static final String FILE = "notif_log.jsonl";
    private static final long MAX_BYTES = 2_000_000;

    private static String mask(CharSequence text) {
        if (text == null) return "";
        String s = text.toString().replaceAll("\\d{4,8}", "####");
        return s.length() > 200 ? s.substring(0, 200) : s;
    }

    public static synchronized void record(Context context, String event, int reason,
                                           StatusBarNotification sbn, NotificationListenerService.RankingMap map) {
        if (sbn == null || !new Config(context).recordLog()) return;
        try {
            JSONObject o = new JSONObject();
            o.put("at", System.currentTimeMillis());
            o.put("event", event);
            o.put("pkg", sbn.getPackageName());
            o.put("key", sbn.getKey());
            o.put("postTime", sbn.getPostTime());
            if ("removed".equals(event)) o.put("reason", reason);

            Notification n = sbn.getNotification();
            if (n != null) {
                o.put("category", n.category);
                o.put("channelId", n.getChannelId());
                o.put("flags", n.flags);
                o.put("group", n.getGroup());
                o.put("shortcutId", n.getShortcutId());
                o.put("fullScreenIntent", n.fullScreenIntent != null);
                Bundle x = n.extras;
                if (x != null) {
                    o.put("template", x.getString(Notification.EXTRA_TEMPLATE));
                    o.put("title", mask(x.getCharSequence(Notification.EXTRA_TITLE)));
                    o.put("text", mask(x.getCharSequence(Notification.EXTRA_TEXT)));
                    o.put("subText", mask(x.getCharSequence(Notification.EXTRA_SUB_TEXT)));
                    o.put("isGroupConversation", x.getBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION, false));
                    o.put("extraKeys", new JSONArray(new ArrayList<>(x.keySet())));
                    ArrayList<?> people = x.getParcelableArrayList(Notification.EXTRA_PEOPLE_LIST);
                    o.put("peopleCount", people == null ? 0 : people.size());
                    Parcelable[] messages = x.getParcelableArray(Notification.EXTRA_MESSAGES);
                    if (messages != null && messages.length > 0) {
                        o.put("messageCount", messages.length);
                        if (messages[messages.length - 1] instanceof Bundle) {
                            Bundle last = (Bundle) messages[messages.length - 1];
                            Object who = last.get("sender_person");
                            if (who instanceof android.app.Person) {
                                android.app.Person p = (android.app.Person) who;
                                JSONObject person = new JSONObject();
                                person.put("key", p.getKey());
                                person.put("important", p.isImportant());
                                person.put("bot", p.isBot());
                                person.put("hasUri", p.getUri() != null);
                                o.put("lastSender", person);
                            }
                        }
                    }
                }
                boolean reply = false;
                JSONArray actions = new JSONArray();
                if (n.actions != null) {
                    for (Notification.Action a : n.actions) {
                        actions.put(mask(a.title));
                        if (a.getRemoteInputs() != null && a.getRemoteInputs().length > 0) reply = true;
                    }
                }
                o.put("actions", actions);
                o.put("replyable", reply);
            }

            if (map != null) {
                NotificationListenerService.Ranking r = new NotificationListenerService.Ranking();
                if (map.getRanking(sbn.getKey(), r)) {
                    JSONObject rank = new JSONObject();
                    rank.put("importance", r.getImportance());
                    rank.put("ambient", r.isAmbient());
                    rank.put("suspended", r.isSuspended());
                    rank.put("matchesInterruptionFilter", r.matchesInterruptionFilter());
                    rank.put("userSentiment", r.getUserSentiment());
                    rank.put("lastAudiblyAlerted", r.getLastAudiblyAlertedMillis());
                    rank.put("canBubble", r.canBubble());
                    if (Build.VERSION.SDK_INT >= 30) {
                        rank.put("isConversation", r.isConversation());
                        rank.put("hasShortcut", r.getConversationShortcutInfo() != null);
                    }
                    android.app.NotificationChannel ch = r.getChannel();
                    if (ch != null) {
                        JSONObject c = new JSONObject();
                        c.put("id", ch.getId());
                        c.put("name", String.valueOf(ch.getName()));
                        c.put("importance", ch.getImportance());
                        c.put("canBypassDnd", ch.canBypassDnd());
                        if (Build.VERSION.SDK_INT >= 30) {
                            c.put("importantConversation", ch.isImportantConversation());
                            c.put("conversationId", ch.getConversationId());
                            c.put("userSetImportance", ch.hasUserSetImportance());
                        }
                        rank.put("channel", c);
                    }
                    o.put("ranking", rank);
                }
            }
            append(context, o.toString() + "\n");
        } catch (Throwable ignored) {
            // The log must never break notification mirroring.
        }
    }

    private static void append(Context context, String line) throws Exception {
        File file = new File(context.getFilesDir(), FILE);
        if (file.length() > MAX_BYTES) {
            File old = new File(context.getFilesDir(), FILE + ".old");
            if (old.exists()) old.delete();
            file.renameTo(old);
            file = new File(context.getFilesDir(), FILE);
        }
        try (OutputStreamWriter w = new OutputStreamWriter(new FileOutputStream(file, true), StandardCharsets.UTF_8)) {
            w.write(line);
        }
    }

    public static synchronized byte[] readAll(Context context) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (String name : new String[]{FILE + ".old", FILE}) {
            File f = new File(context.getFilesDir(), name);
            if (!f.exists()) continue;
            try (FileInputStream in = new FileInputStream(f)) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            } catch (Exception ignored) {
            }
        }
        return out.toByteArray();
    }

    public static synchronized void clear(Context context) {
        new File(context.getFilesDir(), FILE).delete();
        new File(context.getFilesDir(), FILE + ".old").delete();
    }

    public static int lineCount(Context context) {
        byte[] all = readAll(context);
        int n = 0;
        for (byte b : all) if (b == '\n') n++;
        return n;
    }
}
