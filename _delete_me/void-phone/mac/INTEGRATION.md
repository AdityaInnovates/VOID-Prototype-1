# Wiring the phone link into VOID (Mac)

The four new files go in `VOID/Phone/`:

- `PhoneLink.swift` — the WebSocket server on `127.0.0.1:47322`, pairing + device keys
- `MacTools.swift` — what the phone can do on the Mac
- `PhoneIntent.swift` — the phrases you say to VOID about your phone
- `PhoneController.swift` — ties it together (a `.shared` singleton)

They lean on the same patterns as the Music code (XcodeGen picks up new files under
`VOID/` automatically, so `project.yml` needs no change). Four small edits wire it in. I
couldn't see your current music-integrated copies of these files, so apply these by hand —
each is a couple of lines.

### 1. `VOID/App/AppState.swift` — add phone state

Near the other published vars (e.g. by `nowPlaying`), add:

```swift
    /// Phone link.
    var phoneConnected = false
    var phoneStatus = "Phone: not paired"
    /// The PIN while pairing is open, shown in the menu.
    var phonePin: String?
```

### 2. Start the controller — in `AppDelegate.applicationDidFinishLaunching` (or `Conversation.warmUp`, wherever `music.start()` is called)

```swift
    PhoneController.shared.start(state: state)
```

### 3. `VOID/Brain/Conversation.swift` — let phone commands answer first

In `runTurn(_:)`, right where the music line is handled (just after
`music.noteUserText(text)` / before the router), add the phone check **before** music, so
"text Mom" and "find my phone" are caught here:

```swift
        if let phoneReply = await PhoneController.shared.handle(text) {
            show(phoneReply)
            say(phoneReply)
            remember(user: text, void: phoneReply)
            finishTurn()
            return
        }
```

(Use the same `show` / `say` / `finishTurn` helpers the music path uses. If your music
code returns through a shared point, mirror that instead.)

### 4. `VOID/App/VOIDApp.swift` — menu items

Inside `MenuContent`, add a phone section (after the music items):

```swift
        Divider()
        Text(state.phoneStatus)
        if let pin = state.phonePin {
            Text("Pair PIN: \(pin)")
        }
        Button(state.phoneConnected ? "Re-pair a phone…" : "Pair a phone…") {
            AppDelegate.shared?.pairPhone()
        }
        Button("Forget paired phones") {
            PhoneController.shared.forgetPhones()
        }
```

And in `AppDelegate`:

```swift
    func pairPhone() {
        let pin = PhoneController.shared.link.openPairing()
        // The PIN also shows in the menu via state.phonePin.
        let alert = NSAlert()
        alert.messageText = "Pair your phone"
        alert.informativeText = "On the phone, open VOID and enter this PIN within 5 minutes:\n\n\(pin)"
        alert.runModal()
    }
```

### 5. Screen Recording (only for `mac.screenshot`)

If you want the phone to pull a Mac screenshot, give VOID **Screen Recording** permission
in System Settings → Privacy & Security. Everything else works without it.

That's all — rebuild with `./build.sh`.
