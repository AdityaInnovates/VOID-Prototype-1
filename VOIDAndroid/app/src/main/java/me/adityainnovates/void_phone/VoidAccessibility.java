package me.adityainnovates.void_phone;

import android.accessibilityservice.AccessibilityService;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.List;

/**
 * Optional "control" service. When you turn it on, VOID can tap on-screen things and
 * press Back/Home in other apps — the deep reach that normal app permissions don't give.
 * It does nothing on its own; it only acts when a tool calls it.
 */
public class VoidAccessibility extends AccessibilityService {
    private static VoidAccessibility instance;

    public static VoidAccessibility instance() {
        return instance;
    }

    @Override
    protected void onServiceConnected() {
        instance = this;
    }

    @Override
    public void onDestroy() {
        if (instance == this) instance = null;
        super.onDestroy();
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // We don't react to events; we only act on demand.
    }

    @Override
    public void onInterrupt() {
    }

    /** Finds a clickable node whose text or description matches and taps it. */
    public boolean tapByText(String text) {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return false;
        AccessibilityNodeInfo node = firstMatch(root, text.toLowerCase());
        if (node == null) return false;
        AccessibilityNodeInfo clickable = node;
        while (clickable != null && !clickable.isClickable()) clickable = clickable.getParent();
        if (clickable == null) return false;
        return clickable.performAction(AccessibilityNodeInfo.ACTION_CLICK);
    }

    public boolean back() {
        return performGlobalAction(GLOBAL_ACTION_BACK);
    }

    public boolean home() {
        return performGlobalAction(GLOBAL_ACTION_HOME);
    }

    private AccessibilityNodeInfo firstMatch(AccessibilityNodeInfo node, String needle) {
        if (node == null) return null;
        CharSequence text = node.getText();
        CharSequence desc = node.getContentDescription();
        if ((text != null && text.toString().toLowerCase().contains(needle))
                || (desc != null && desc.toString().toLowerCase().contains(needle))) {
            return node;
        }
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo found = firstMatch(node.getChild(i), needle);
            if (found != null) return found;
        }
        return null;
    }
}
