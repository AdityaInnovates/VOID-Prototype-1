package me.adityainnovates.void_phone;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.view.inputmethod.EditorInfo;
import android.widget.Toast;

import org.json.JSONObject;

import java.util.ArrayList;

import me.adityainnovates.void_phone.net.LinkClient;
import me.adityainnovates.void_phone.tools.Speaker;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;

import me.adityainnovates.void_phone.databinding.ActivityMainBinding;

/** The one screen: set the Mac address, pair, and grant the powers you want VOID to have. */
public class MainActivity extends AppCompatActivity {
    private ActivityMainBinding ui;
    private Config config;
    private BroadcastReceiver statusReceiver;
    private SpeechRecognizer recognizer;
    private boolean listening = false;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        ui = ActivityMainBinding.inflate(getLayoutInflater());
        setContentView(ui.getRoot());
        config = new Config(this);

        ui.macUrl.setText(config.macUrl());
        ui.mirror.setChecked(config.mirrorNotifications());

        LinkService.start(this);

        ui.pairButton.setOnClickListener(v -> pair());
        ui.unpairButton.setOnClickListener(v -> unpair());
        ui.mirror.setOnCheckedChangeListener((b, on) -> config.setMirrorNotifications(on));

        ui.micButton.setOnClickListener(v -> toggleMic());
        ui.askSend.setOnClickListener(v -> sendTyped());
        ui.askText.setOnEditorActionListener((v, action, event) -> {
            if (action == EditorInfo.IME_ACTION_SEND) { sendTyped(); return true; }
            return false;
        });

        ui.permCore.setOnClickListener(v -> requestCore());
        ui.permNotered.setOnClickListener(v -> open(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS));
        ui.permDnd.setOnClickListener(v -> open(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS));
        ui.permAccess.setOnClickListener(v -> open(Settings.ACTION_ACCESSIBILITY_SETTINGS));
        ui.permAdmin.setOnClickListener(v -> requestAdmin());
        ui.permBattery.setOnClickListener(v -> requestIgnoreBattery());
    }

    @Override
    protected void onResume() {
        super.onResume();
        statusReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                ui.status.setText(intent.getStringExtra("text"));
            }
        };
        IntentFilter filter = new IntentFilter("me.adityainnovates.void_phone.STATUS");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(statusReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(statusReceiver, filter);
        }
        LinkService service = LinkService.get();
        if (service != null) ui.status.setText(service.status());
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (statusReceiver != null) try { unregisterReceiver(statusReceiver); } catch (Exception ignored) {}
    }

    // MARK: talking to VOID

    private void toggleMic() {
        if (listening) {
            if (recognizer != null) recognizer.stopListening();
            return;
        }
        if (androidx.core.content.ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, new String[]{Manifest.permission.RECORD_AUDIO}, 2);
            return;
        }
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            toast("This phone has no speech recognition. Type instead.");
            return;
        }
        if (recognizer == null) {
            recognizer = SpeechRecognizer.createSpeechRecognizer(this);
            recognizer.setRecognitionListener(new RecognitionListener() {
                @Override public void onReadyForSpeech(Bundle params) { setListening(true); }
                @Override public void onBeginningOfSpeech() {}
                @Override public void onRmsChanged(float rmsdB) {}
                @Override public void onBufferReceived(byte[] buffer) {}
                @Override public void onEndOfSpeech() { setListening(false); }
                @Override public void onError(int error) {
                    setListening(false);
                    if (error != SpeechRecognizer.ERROR_NO_MATCH && error != SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                        toast("Couldn't hear that (error " + error + ").");
                    }
                }
                @Override public void onPartialResults(Bundle partial) {
                    ArrayList<String> parts = partial.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                    if (parts != null && !parts.isEmpty()) ui.askText.setText(parts.get(0));
                }
                @Override public void onResults(Bundle results) {
                    setListening(false);
                    ArrayList<String> texts = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                    if (texts != null && !texts.isEmpty()) {
                        ui.askText.setText(texts.get(0));
                        ask(texts.get(0));
                    }
                }
                @Override public void onEvent(int eventType, Bundle params) {}
            });
        }
        Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
        recognizer.startListening(intent);
    }

    private void setListening(boolean on) {
        listening = on;
        ui.micButton.setText(on ? "Listening… tap to stop" : "Tap to talk");
    }

    private void sendTyped() {
        String text = ui.askText.getText().toString().trim();
        if (!text.isEmpty()) ask(text);
    }

    /** Sends a line to VOID's brain on the Mac and shows (and optionally speaks) the answer. */
    private void ask(String text) {
        LinkService service = LinkService.get();
        if (service == null || !service.isConnected()) {
            ui.reply.setText("Not connected to the Mac yet.");
            return;
        }
        ui.reply.setText("…");
        JSONObject args = new JSONObject();
        try {
            args.put("text", text);
            args.put("speak", false);
        } catch (Exception ignored) {
        }
        service.link().call("ask", args, new LinkClient.Result() {
            @Override public void ok(JSONObject data) {
                String reply = data.optString("reply", "");
                if (reply.isEmpty()) reply = "(no reply)";
                final String shown = reply;
                runOnUiThread(() -> {
                    ui.reply.setText(shown);
                    ui.askText.setText("");
                    if (ui.speakReply.isChecked()) Speaker.say(MainActivity.this, shown);
                });
            }
            @Override public void fail(String reason) {
                runOnUiThread(() -> ui.reply.setText(reason));
            }
        });
    }

    @Override
    protected void onDestroy() {
        if (recognizer != null) recognizer.destroy();
        super.onDestroy();
    }

    private void pair() {
        String url = ui.macUrl.getText().toString().trim();
        String pin = ui.pin.getText().toString().trim();
        if (url.isEmpty()) { toast("Enter your Mac's address first."); return; }
        if (pin.length() != 6) { toast("The PIN is six digits."); return; }
        config.setMacUrl(url);
        LinkService.start(this);
        Intent intent = new Intent(this, LinkService.class).setAction("pair").putExtra("pin", pin);
        startService(intent);
        ui.pin.setText("");
        toast("Pairing…");
    }

    private void unpair() {
        config.unpair();
        Intent intent = new Intent(this, LinkService.class).setAction("reconnect");
        startService(intent);
        ui.status.setText("Not paired");
        toast("Unpaired. The Mac will need to pair again.");
    }

    private void requestCore() {
        java.util.ArrayList<String> wanted = new java.util.ArrayList<>(java.util.Arrays.asList(
                Manifest.permission.SEND_SMS, Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS,
                Manifest.permission.READ_CONTACTS, Manifest.permission.CALL_PHONE, Manifest.permission.READ_PHONE_STATE,
                Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION,
                Manifest.permission.RECORD_AUDIO, Manifest.permission.CAMERA));
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            wanted.add(Manifest.permission.POST_NOTIFICATIONS);
            wanted.add(Manifest.permission.READ_MEDIA_IMAGES);
        }
        ActivityCompat.requestPermissions(this, wanted.toArray(new String[0]), 1);
    }

    private void requestAdmin() {
        ComponentName admin = new ComponentName(this, VoidAdminReceiver.class);
        Intent intent = new Intent(android.app.admin.DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                .putExtra(android.app.admin.DevicePolicyManager.EXTRA_DEVICE_ADMIN, admin)
                .putExtra(android.app.admin.DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                        "Lets VOID lock this phone when you ask.");
        startActivity(intent);
    }

    @SuppressWarnings("BatteryLife")
    private void requestIgnoreBattery() {
        Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:" + getPackageName()));
        try { startActivity(intent); } catch (Exception e) { open(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS); }
    }

    private void open(String action) {
        try { startActivity(new Intent(action)); }
        catch (Exception e) { toast("Couldn't open that settings screen."); }
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show();
    }
}
