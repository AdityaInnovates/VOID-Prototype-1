# Keep Java-WebSocket; it uses reflection in places.
-keep class org.java_websocket.** { *; }
-dontwarn org.java_websocket.**
