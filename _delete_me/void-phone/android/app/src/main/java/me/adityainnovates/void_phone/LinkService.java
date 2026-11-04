package me.adityainnovates.void_phone;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.BroadcastReceiver;
import android.os.BatteryManager;
import android.os.Build;
import android.os.IBinder;

import androidx.annotation.Nullable;

import org.json.JSONObject;

import me.adityainnovates.void_phone.net.LinkClient;
import me.adityainnovates.void_phone.tools.PhoneTools;

/**
 * The always-on service. It holds the one connection to the Mac, answers tool calls with
 * {@link PhoneTools}, and keeps a quiet notification so Android doesn't kill it.
 */
public class LinkService extends Service {
    public static final String CHANNEL = "void-link";
    private static final int NOTIF_ID = 1;

    private static LinkService instance;

    private Config config;
    private LinkClient link;
    private PhoneTools tools;
    private String statusText = "Starting…";
    private BroadcastReceiver batteryReceiver;
    private boolean lowSent = false;

    public static LinkService get() {
        return instance;
    }

    public LinkClient link() {
        return link;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        config = new Config(this);
        tools = new PhoneTools(this);
        createChannel();
        startForeground(NOTIF_ID, buildNotification("Connecting to " + config.macName() + "…"));

        link = new LinkClient(
                (tool, args, done) -> tools.run(tool, args, done),
                new LinkClient.Listener() {
                    @Override public void onConnected(String macName) {
                        config.setMacName(macName);
                        String key = link.currentKey();
                        if (key != null) config.setDeviceKey(key);
                        setStatus("Connected to " + macName);
                    }
                    @Override public void onDisconnected() { setStatus("Reconnecting to " + config.macName() + "…"); }
                    @Override public void onNeedsPairing() { setStatus("Not paired — open VOID to pair"); }
                    @Override public void onPairingFailed(String reason) { setStatus(reason); }
                    @Override public void onEvent(String name, JSONObject data) { /* Mac->phone events, none yet */ }
                });
        link.configure(config.macUrl(), config.deviceKey(), config.deviceName());
        if (config.isPaired()) link.connect();
        watchBattery();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && "pair".equals(intent.getAction())) {
            String pin = intent.getStringExtra("pin");
            link.configure(config.macUrl(), null, config.deviceName());
            if (pin != null) link.pairWith(pin);
        } else if (intent != null && "reconnect".equals(intent.getAction())) {
            link.configure(config.macUrl(), config.deviceKey(), config.deviceName());
            link.connect();
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (batteryReceiver != null) try { unregisterReceiver(batteryReceiver); } catch (Exception ignored) {}
        if (link != null) link.stop();
        instance = null;
        super.onDestroy();
    }

    /** Pushes an event up to the Mac (used by the notification listener). */
    public void sendEvent(String name, JSONObject data) {
        if (link != null) link.event(name, data);
    }

    public boolean isConnected() {
        return link != null && link.isConnected();
    }

    public String status() {
        return statusText;
    }

    private void watchBattery() {
        batteryReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                int level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
                int scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
                int plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0);
                if (level < 0 || scale <= 0) return;
                int pct = level * 100 / scale;
                if (pct <= 15 && plugged == 0 && !lowSent) {
                    lowSent = true;
                    try {
                        JSONObject data = new JSONObject();
                        data.put("level", pct);
                        sendEvent("battery.low", data);
                    } catch (Exception ignored) {}
                } else if (pct > 25 || plugged != 0) {
                    lowSent = false;
                }
            }
        };
        registerReceiver(batteryReceiver, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
    }

    private void setStatus(String text) {
        statusText = text;
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) nm.notify(NOTIF_ID, buildNotification(text));
        Intent broadcast = new Intent("me.adityainnovates.void_phone.STATUS").putExtra("text", text);
        broadcast.setPackage(getPackageName());
        sendBroadcast(broadcast);
    }

    private Notification buildNotification(String text) {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CHANNEL)
                .setContentTitle("VOID")
                .setContentText(text)
                .setSmallIcon(R.drawable.ic_stat_void)
                .setContentIntent(pi)
                .setOngoing(true)
                .build();
    }

    private void createChannel() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        NotificationChannel channel = new NotificationChannel(CHANNEL, "VOID link", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Keeps VOID connected to your Mac.");
        channel.setShowBadge(false);
        if (nm != null) nm.createNotificationChannel(channel);
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // Convenience for starting the service with the right foreground type.
    public static void start(Context context) {
        Intent intent = new Intent(context, LinkService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent);
        else context.startService(intent);
    }
}
