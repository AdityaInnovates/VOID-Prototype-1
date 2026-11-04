package me.adityainnovates.void_phone.net;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import org.java_websocket.client.WebSocketClient;
import org.java_websocket.framing.Framedata;
import org.java_websocket.handshake.ServerHandshake;
import org.json.JSONObject;

import java.net.URI;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * The phone's side of the link to the Mac.
 *
 * Keeps one WebSocket open to wss://void.adityainnovates.me (through cloudflared),
 * proves who we are (a 6-digit PIN the first time, then the saved device key), and
 * carries tool calls both ways:
 *   - the Mac calls a tool here  -> {@link Responder} runs it and we send the result
 *   - we call a tool on the Mac  -> {@link #call} sends it and waits for the result
 * Reconnects on its own with a backoff, so the service just leaves it running.
 */
public class LinkClient {
    private static final String TAG = "VoidLink";

    public interface Responder {
        /** Runs a tool the Mac asked for and hands its JSON result (or an error) to {@code done}. */
        void respond(String tool, JSONObject args, Result done);
    }

    public interface Result {
        void ok(JSONObject data);
        void fail(String reason);
    }

    public interface Listener {
        void onConnected(String macName);
        void onDisconnected();
        void onNeedsPairing();
        void onPairingFailed(String reason);
        void onEvent(String name, JSONObject data);
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicInteger counter = new AtomicInteger();
    private final Map<String, Result> pending = new HashMap<>();

    private final Responder responder;
    private final Listener listener;

    private WebSocketClient socket;
    private String url;
    private String deviceKey;        // null while pairing
    private String pairingPin;       // set for one pairing attempt
    private String deviceName = "Phone";
    private boolean wantOpen = false;
    private boolean proven = false;
    private int backoffMs = 1000;
    private Runnable reconnect;

    public LinkClient(Responder responder, Listener listener) {
        this.responder = responder;
        this.listener = listener;
    }

    public boolean isConnected() {
        return proven;
    }

    /** The device key, freshly set after a successful pairing, so the service can save it. */
    public String currentKey() {
        return deviceKey;
    }

    public void configure(String url, String deviceKey, String deviceName) {
        this.url = url;
        this.deviceKey = deviceKey;
        this.deviceName = deviceName;
    }

    /** Connect and keep reconnecting. With no device key, the next connection pairs. */
    public synchronized void connect() {
        wantOpen = true;
        backoffMs = 1000;
        open();
    }

    /** Try one connection that pairs using this PIN. */
    public synchronized void pairWith(String pin) {
        this.pairingPin = pin;
        this.deviceKey = null;
        wantOpen = true;
        backoffMs = 1000;
        open();
    }

    public synchronized void stop() {
        wantOpen = false;
        if (reconnect != null) main.removeCallbacks(reconnect);
        closeSocket();
    }

    private synchronized void open() {
        closeSocket();
        if (url == null || url.isEmpty()) return;
        URI uri;
        try {
            uri = new URI(url);
        } catch (Exception e) {
            listener.onPairingFailed("That Mac address doesn't look right.");
            return;
        }
        proven = false;
        socket = new WebSocketClient(uri) {
            @Override
            public void onOpen(ServerHandshake handshake) {
                sendHandshake();
            }

            @Override
            public void onMessage(String message) {
                handle(message);
            }

            @Override
            public void onClose(int code, String reason, boolean remote) {
                proven = false;
                main.post(listener::onDisconnected);
                scheduleReconnect();
            }

            @Override
            public void onError(Exception ex) {
                Log.w(TAG, "socket error", ex);
            }

            @Override
            public void onWebsocketPong(org.java_websocket.WebSocket conn, Framedata f) {
                // keep-alive answered
            }
        };
        socket.setConnectionLostTimeout(40);
        try {
            socket.connect();
        } catch (Exception e) {
            scheduleReconnect();
        }
    }

    private void sendHandshake() {
        try {
            JSONObject hello = new JSONObject();
            if (deviceKey != null) {
                hello.put("type", "hello");
                hello.put("key", deviceKey);
            } else if (pairingPin != null) {
                hello.put("type", "pair");
                hello.put("pin", pairingPin);
                hello.put("device", deviceName);
            } else {
                main.post(listener::onNeedsPairing);
                return;
            }
            socket.send(hello.toString());
        } catch (Exception ignored) {
        }
    }

    private void handle(String message) {
        JSONObject msg;
        try {
            msg = new JSONObject(message);
        } catch (Exception e) {
            return;
        }
        String type = msg.optString("type");
        switch (type) {
            case "welcome":
            case "paired":
                if ("paired".equals(type)) {
                    deviceKey = msg.optString("key", null);
                }
                pairingPin = null;
                proven = true;
                backoffMs = 1000;
                final String mac = msg.optString("mac", "your Mac");
                main.post(() -> listener.onConnected(mac));
                return;
            case "rejected":
                final String reason = msg.optString("reason", "The Mac refused the connection.");
                final boolean forget = msg.optBoolean("forget", false);
                if (forget) deviceKey = null;
                pairingPin = null;
                main.post(() -> listener.onPairingFailed(reason));
                return;
            case "pong":
                return;
        }
        if (!proven) return;

        if ("call".equals(type)) {
            final String id = msg.optString("id");
            final String tool = msg.optString("tool");
            final JSONObject args = msg.optJSONObject("args") != null ? msg.optJSONObject("args") : new JSONObject();
            responder.respond(tool, args, new Result() {
                @Override
                public void ok(JSONObject data) {
                    reply(id, true, data, null);
                }

                @Override
                public void fail(String why) {
                    reply(id, false, null, why);
                }
            });
        } else if ("result".equals(type)) {
            String re = msg.optString("re");
            Result waiter;
            synchronized (pending) {
                waiter = pending.remove(re);
            }
            if (waiter == null) return;
            if (msg.optBoolean("ok", false)) {
                waiter.ok(msg.optJSONObject("data") != null ? msg.optJSONObject("data") : new JSONObject());
            } else {
                waiter.fail(msg.optString("error", "The Mac couldn't do that."));
            }
        } else if ("event".equals(type)) {
            final String name = msg.optString("name");
            final JSONObject data = msg.optJSONObject("data") != null ? msg.optJSONObject("data") : new JSONObject();
            main.post(() -> listener.onEvent(name, data));
        }
    }

    private void reply(String id, boolean ok, JSONObject data, String error) {
        try {
            JSONObject out = new JSONObject();
            out.put("type", "result");
            out.put("re", id);
            out.put("ok", ok);
            if (data != null) out.put("data", data);
            if (error != null) out.put("error", error);
            sendRaw(out);
        } catch (Exception ignored) {
        }
    }

    /** Calls a tool on the Mac. The callback runs on the main thread. */
    public void call(String tool, JSONObject args, Result done) {
        call(tool, args, done, 25000);
    }

    /** Same, with your own patience: asking VOID a question can take a while on the Mac. */
    public void call(String tool, JSONObject args, Result done, long timeoutMs) {
        if (!proven || socket == null) {
            main.post(() -> done.fail("Not connected to the Mac."));
            return;
        }
        String id = "p" + counter.incrementAndGet();
        synchronized (pending) {
            pending.put(id, done);
        }
        try {
            JSONObject out = new JSONObject();
            out.put("type", "call");
            out.put("id", id);
            out.put("tool", tool);
            out.put("args", args != null ? args : new JSONObject());
            sendRaw(out);
        } catch (Exception e) {
            synchronized (pending) {
                pending.remove(id);
            }
            main.post(() -> done.fail("Couldn't send that to the Mac."));
            return;
        }
        // Give up after 25 seconds so a lost reply doesn't hang forever.
        main.postDelayed(() -> {
            Result waiter;
            synchronized (pending) {
                waiter = pending.remove(id);
            }
            if (waiter != null) waiter.fail("The Mac didn't answer in time.");
        }, timeoutMs);
    }

    /** Pushes an event to the Mac (a notification, an incoming call, low battery). */
    public void event(String name, JSONObject data) {
        try {
            JSONObject out = new JSONObject();
            out.put("type", "event");
            out.put("name", name);
            out.put("data", data != null ? data : new JSONObject());
            sendRaw(out);
        } catch (Exception ignored) {
        }
    }

    private synchronized void sendRaw(JSONObject obj) {
        if (socket != null && socket.isOpen()) {
            socket.send(obj.toString());
        }
    }

    private void scheduleReconnect() {
        if (!wantOpen) return;
        if (reconnect != null) main.removeCallbacks(reconnect);
        reconnect = this::open;
        main.postDelayed(reconnect, backoffMs);
        backoffMs = Math.min(backoffMs * 2, 30000);
    }

    private void closeSocket() {
        if (socket != null) {
            try {
                socket.close();
            } catch (Exception ignored) {
            }
            socket = null;
        }
    }
}
