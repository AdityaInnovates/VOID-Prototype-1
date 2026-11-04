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
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;

import me.adityainnovates.void_phone.databinding.ActivityMainBinding;

/** The one screen: set the Mac address, pair, and grant the powers you want VOID to have. */
public class MainActivity extends AppCompatActivity {
    private ActivityMainBinding ui;
    private Config config;
    private BroadcastReceiver statusReceiver;

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
