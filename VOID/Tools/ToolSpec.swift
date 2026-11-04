import Foundation

/// One thing VOID can do, written the way a person would ask for it. The descriptions and
/// example sentences are what the tool index searches, so good examples make good matches.
struct ToolSpec: Sendable {
    enum Target: Sendable { case phone, mac }

    let id: String
    let target: Target
    /// The tool name sent to the phone, or run on this Mac.
    let tool: String
    let summary: String
    let examples: [String]
    /// Argument names with a short description, e.g. ("on", "true for on, false for off").
    let args: [(name: String, hint: String)]
    /// A question to ask before doing it (nil = just do it).
    let confirm: String?
    /// What VOID says afterwards for tools that return nothing worth reading.
    let done: String

    /// Everything the index embeds for this tool.
    var texts: [String] { [summary] + examples }

    init(_ id: String, _ target: Target, _ tool: String, _ summary: String, examples: [String],
         args: [(String, String)] = [], confirm: String? = nil, done: String = "Done.") {
        self.id = id
        self.target = target
        self.tool = tool
        self.summary = summary
        self.examples = examples
        self.args = args.map { (name: $0.0, hint: $0.1) }
        self.confirm = confirm
        self.done = done
    }
}

enum ToolRegistry {
    static let all: [ToolSpec] = phone + mac

    static func spec(_ id: String) -> ToolSpec? { all.first { $0.id == id } }

    // MARK: Android phone

    static let phone: [ToolSpec] = [
        ToolSpec("phone.ring", .phone, "ring", "Make the phone ring loudly so you can find it, even on silent",
                 examples: ["find my phone", "where is my phone", "ring my phone", "i lost my phone", "make my phone ring"],
                 done: "Ringing your phone. Say found it to stop."),
        ToolSpec("phone.ring.stop", .phone, "ring.stop", "Stop the phone from ringing",
                 examples: ["found it", "stop ringing", "i found my phone"], done: "Stopped."),
        ToolSpec("phone.status", .phone, "device.status", "Phone battery level, whether it is charging, and its model",
                 examples: ["how much battery does my phone have", "is my phone charging", "phone battery", "what phone is connected"]),
        ToolSpec("phone.location", .phone, "location.get", "Where the phone is right now (GPS location)",
                 examples: ["where is my phone right now", "where am i", "what's my location", "share my location"]),
        ToolSpec("phone.sms.read", .phone, "sms.read", "Read the latest text messages (SMS) on the phone",
                 examples: ["read my messages", "any new texts", "did anyone text me", "read my last message", "check my sms"],
                 args: [("limit", "how many messages, 1 to 5")]),
        ToolSpec("phone.sms.send", .phone, "sms.send", "Send a text message (SMS) to a contact or number",
                 examples: ["text mom i'll be late", "send a message to rahul saying ok", "sms dad that i reached"],
                 args: [("to", "contact name or phone number"), ("body", "the message text")],
                 confirm: "Send it?"),
        ToolSpec("phone.contacts", .phone, "contacts.find", "Look up a contact's phone number",
                 examples: ["what is mom's number", "find rahul in my contacts", "get dad's phone number"],
                 args: [("name", "the contact's name")]),
        ToolSpec("phone.call", .phone, "call.start", "Place a phone call to a contact or number",
                 examples: ["call mom", "phone rahul", "dial 112", "ring my brother"],
                 args: [("to", "contact name or phone number")], confirm: "Call them?"),
        ToolSpec("phone.apps.open", .phone, "apps.open", "Open an app on the phone",
                 examples: ["open whatsapp on my phone", "launch instagram on my phone", "open maps on my phone", "start spotify on my phone"],
                 args: [("name", "the app's name")]),
        ToolSpec("phone.apps.list", .phone, "apps.list", "List the apps installed on the phone",
                 examples: ["what apps are on my phone", "list my phone apps", "do i have telegram on my phone"]),
        ToolSpec("phone.torch", .phone, "torch", "Turn the phone's flashlight on or off",
                 examples: ["turn on the flashlight", "flashlight off", "torch on", "switch off the torch on my phone"],
                 args: [("on", "true for on, false for off")]),
        ToolSpec("phone.ringer", .phone, "ringer",
                 "Change the phone's sound mode: ring mode (normal), vibrate or silent. Turning silent mode off means ring mode",
                 examples: ["turn to ring mode", "switch to ring mode", "put it on ring mode", "turn off silent mode",
                            "disable silent mode", "take my phone off silent", "unmute my phone", "turn the ringer back on",
                            "put my phone on silent", "go silent", "turn on silent mode", "set my phone to vibrate",
                            "vibrate mode", "mute my phone", "normal sound mode"],
                 args: [("mode", "normal for ring mode or when silent/vibrate is turned off; vibrate; silent")],
                 done: "Done, sound mode changed."),
        ToolSpec("phone.dnd", .phone, "dnd", "Turn Do Not Disturb on or off on the phone",
                 examples: ["turn on do not disturb", "dnd off on my phone", "don't disturb me", "i want no notifications now"],
                 args: [("on", "true for on, false for off")]),
        ToolSpec("phone.alarm", .phone, "alarm.set", "Set an alarm on the phone at a time of day",
                 examples: ["set an alarm for 7 am", "wake me up at 6:30", "alarm at 5 pm"],
                 args: [("hour", "0 to 23"), ("minute", "0 to 59")], done: "Alarm set on your phone."),
        ToolSpec("phone.timer", .phone, "timer.set", "Start a countdown timer on the phone",
                 examples: ["set a timer for 10 minutes", "timer for 30 seconds", "remind me in an hour"],
                 args: [("seconds", "length in seconds")], done: "Timer started on your phone."),
        ToolSpec("phone.notifications", .phone, "notifications.list", "Read the notifications currently on the phone",
                 examples: ["what are my notifications", "tell me my new notifications", "what did i miss", "any whatsapp messages", "check my phone notifications"]),
        ToolSpec("phone.reply", .phone, "notifications.reply", "Reply to a phone notification such as a WhatsApp message",
                 examples: ["reply to rahul on whatsapp saying coming", "answer that message with yes", "reply ok to the last message"],
                 args: [("key", "the notification key, from the list"), ("text", "the reply")], confirm: "Send the reply?"),
        ToolSpec("phone.clipboard.get", .phone, "clipboard.get", "Read what is copied on the phone's clipboard",
                 examples: ["what's on my phone clipboard", "paste from my phone", "what did i copy on my phone"]),
        ToolSpec("phone.clipboard.set", .phone, "clipboard.set", "Put text on the phone's clipboard",
                 examples: ["copy this to my phone", "send this text to my phone clipboard"],
                 args: [("text", "the text to copy")], done: "It's on your phone's clipboard."),
        ToolSpec("phone.media", .phone, "media", "Play, pause, skip or go back in whatever media is playing on the phone",
                 examples: ["pause the music on my phone", "next song on my phone", "play the video on my phone"],
                 args: [("action", "toggle, next or previous")]),
        ToolSpec("phone.speak", .phone, "speak", "Say a sentence out loud on the phone",
                 examples: ["say hello on my phone", "announce dinner is ready on my phone", "tell my phone to say something"],
                 args: [("text", "what to say")]),
        ToolSpec("phone.vibrate", .phone, "vibrate", "Make the phone vibrate briefly",
                 examples: ["vibrate my phone", "buzz my phone"], done: "Buzzed."),
        ToolSpec("phone.open.url", .phone, "open.url", "Open a web link on the phone",
                 examples: ["open this link on my phone", "send this website to my phone", "open google.com on my phone"],
                 args: [("url", "the full web address")]),
        ToolSpec("phone.settings", .phone, "open.settings", "Open a settings screen on the phone",
                 examples: ["open wifi settings on my phone", "open my phone's bluetooth settings", "show phone battery settings"],
                 args: [("screen", "wifi, bluetooth, location, battery or empty for main settings")]),
        ToolSpec("phone.lock", .phone, "lock", "Lock the phone's screen",
                 examples: ["lock my phone", "lock the phone screen"], confirm: "Lock your phone?", done: "Phone locked."),
        ToolSpec("phone.tap", .phone, "tap", "Tap a button or text visible on the phone's screen, in any app",
                 examples: ["tap send on my phone", "press the play button on my phone", "click ok on my phone screen"],
                 args: [("text", "the words on the button")]),
    ]

    // MARK: This Mac

    static let mac: [ToolSpec] = [
        ToolSpec("mac.status", .mac, "mac.status", "Mac battery level, front app and uptime",
                 examples: ["how much battery does my mac have", "mac status", "what app am i in", "how long has my mac been on"]),
        ToolSpec("mac.open", .mac, "mac.open", "Open an app or a web link on the Mac",
                 examples: ["open safari", "launch xcode", "open notes on my mac", "open youtube.com"],
                 args: [("app", "the app's name, if opening an app"), ("url", "the web address, if opening a link")]),
        ToolSpec("mac.apps", .mac, "mac.apps", "List the apps running on the Mac",
                 examples: ["what apps are open", "what's running on my mac"]),
        ToolSpec("mac.clipboard.get", .mac, "mac.clipboard.get", "Read what is copied on the Mac clipboard",
                 examples: ["what's on my clipboard", "what did i copy"]),
        ToolSpec("mac.clipboard.set", .mac, "mac.clipboard.set", "Put text on the Mac clipboard",
                 examples: ["copy this to my clipboard"], args: [("text", "the text")], done: "Copied."),
        ToolSpec("mac.volume", .mac, "mac.volume", "Set the Mac's output volume, 0 to 100",
                 examples: ["set the mac volume to 30", "turn the volume down", "volume to 50 percent"],
                 args: [("level", "0 to 100")]),
        ToolSpec("mac.bluetooth", .mac, "mac.bluetooth", "Turn the Mac's Bluetooth on or off, or check it",
                 examples: ["turn off bluetooth on my mac", "turn off bluetooth of my mac", "switch bluetooth on", "disable bluetooth",
                            "is bluetooth on on my mac", "enable the mac bluetooth"],
                 args: [("state", "on, off, or status")]),
        ToolSpec("mac.wifi", .mac, "mac.wifi", "Turn the Mac's Wi-Fi on or off, or check it",
                 examples: ["turn off wifi on my mac", "switch the mac wifi on", "disable wi-fi", "is my mac wifi on"],
                 args: [("state", "on, off, or status")]),
        ToolSpec("mac.lock", .mac, "mac.lock", "Lock the Mac's screen",
                 examples: ["lock my mac", "lock the screen"], confirm: "Lock the Mac?", done: "Locked."),
        ToolSpec("mac.sleep", .mac, "mac.sleep", "Put the Mac to sleep",
                 examples: ["put my mac to sleep", "sleep the mac"], confirm: "Put the Mac to sleep?", done: "Sleeping."),
        ToolSpec("mac.shortcut", .mac, "mac.shortcut", "Run one of your Shortcuts app shortcuts by name",
                 examples: ["run my morning shortcut", "run the focus shortcut"], args: [("name", "the shortcut's name")]),
        ToolSpec("mac.notify", .mac, "mac.notify", "Show a notification on the Mac",
                 examples: ["remind me with a notification", "show a notification saying hello"],
                 args: [("title", "short title"), ("body", "the text")]),
    ]

    /// Plain-language overview, grouped, for "what can you do on my phone".
    static func overview(_ target: ToolSpec.Target) -> String {
        let list = all.filter { $0.target == target }.map { $0.summary.lowercased() }
        let first = list.prefix(list.count - 1).joined(separator: ", ")
        return first + ", and " + (list.last ?? "")
    }
}
