package me.adityainnovates.void_phone.tools;

import org.json.JSONObject;

import me.adityainnovates.void_phone.VoidAccessibility;
import me.adityainnovates.void_phone.net.LinkClient;

/** "Tap the Send button": finds on-screen text and taps it, via the accessibility service. */
public final class Tapper {
    public static void tap(String text, LinkClient.Result done) {
        VoidAccessibility service = VoidAccessibility.instance();
        if (service == null) {
            done.fail("VOID's accessibility control isn't on. Turn it on in the app to tap things in other apps.");
            return;
        }
        if (text == null || text.isEmpty()) { done.fail("Say what to tap."); return; }
        boolean tapped = service.tapByText(text);
        if (tapped) done.ok(new JSONObject());
        else done.fail("I couldn't find \"" + text + "\" on the screen.");
    }
}
