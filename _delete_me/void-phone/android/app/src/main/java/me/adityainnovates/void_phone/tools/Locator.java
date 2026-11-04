package me.adityainnovates.void_phone.tools;

import android.annotation.SuppressLint;
import android.content.Context;
import android.location.Location;
import android.location.LocationManager;
import android.os.Handler;
import android.os.Looper;

/** One fresh GPS/network fix, or the last known position, whichever comes first. */
public final class Locator {
    public interface Callback {
        void onLocation(Location location);
        void onFailed(String why);
    }

    @SuppressLint("MissingPermission")
    public static void current(Context context, Callback callback) {
        LocationManager lm = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
        if (lm == null) { callback.onFailed("No location service on this phone."); return; }

        Location best = null;
        for (String provider : new String[]{LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER}) {
            try {
                Location l = lm.getLastKnownLocation(provider);
                if (l != null && (best == null || l.getTime() > best.getTime())) best = l;
            } catch (Exception ignored) {
            }
        }
        final Location lastKnown = best;
        final boolean[] answered = {false};
        final Handler handler = new Handler(Looper.getMainLooper());

        android.location.LocationListener listener = new android.location.LocationListener() {
            @Override public void onLocationChanged(Location location) {
                if (answered[0]) return;
                answered[0] = true;
                lm.removeUpdates(this);
                callback.onLocation(location);
            }
            @Override public void onProviderDisabled(String p) {}
            @Override public void onProviderEnabled(String p) {}
            @Override public void onStatusChanged(String p, int s, android.os.Bundle e) {}
        };

        try {
            String provider = lm.isProviderEnabled(LocationManager.GPS_PROVIDER)
                    ? LocationManager.GPS_PROVIDER : LocationManager.NETWORK_PROVIDER;
            lm.requestLocationUpdates(provider, 0, 0, listener, Looper.getMainLooper());
        } catch (Exception e) {
            if (lastKnown != null) { callback.onLocation(lastKnown); return; }
            callback.onFailed("Couldn't start location on the phone.");
            return;
        }

        // Wait up to 12 seconds for a fresh fix; otherwise fall back to last known.
        handler.postDelayed(() -> {
            if (answered[0]) return;
            answered[0] = true;
            try { lm.removeUpdates(listener); } catch (Exception ignored) {}
            if (lastKnown != null) callback.onLocation(lastKnown);
            else callback.onFailed("The phone couldn't get a location. Is GPS on?");
        }, 12000);
    }
}
