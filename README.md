> **WARNING: AI SLOP**

# FlowTube

[Flow](https://github.com/Flow-Tube/Flow-Desktop)'s on-device recommendation algorithm, **FlowNeuro**,
as your YouTube Home feed on iOS. It's an injectable feature in the style of VolumeBoostYT or
DontEatMyContent, not a modified client, and it runs alongside **YTKACE** (the main target),
**YTPlusM** and **YTLitePlus**.

Only the algorithm changes. Videos still open in YouTube's own player while you're signed in, so
views, watch history, likes, comments, subscriptions and everything else stay in your account,
exactly as before.

## What you get

- **Flow on Home.** Home shows Flow's feed, built the way Flow builds it:
  - discovery searches from your interests
  - videos related to what you really watched (not misclicks)
  - new uploads from followed channels
  - "channels you often watch"
  - "a channel like X" neighbours from co-watch

  Everything is ranked by FlowNeuro, with Flow's own "why you see this" line on each card.
- **YouTube's feed is one tap away.** Flow's **⋯** menu → *Show YouTube's feed* brings YouTube's
  own Home back, and the **Flow** pill returns.
- **It learns as you go.** It learns from what you watch (watch time, skips under 20%,
  rewatches), likes and dislikes (from YouTube's buttons), and long-press → *Not interested* /
  *Don't recommend channel* on Flow cards.
- **On-device.** Everything learned stays in the app's own storage
  (`Application Support/FlowTube/flowneuro_state.json`). Flow's searches go to YouTube *logged
  out* (no cookies), so they never touch your account or YouTube's recommendations.
- **Subscriptions, both places.** Subscribing or unsubscribing in YouTube also does it in Flow.
  Opening **Subscriptions → All** in YouTube copies your account's channel list into Flow (or tap
  *Copy subscriptions from my account* in Flow's settings). Flow's header has a **For you /
  Subscriptions** switch, and *Subscriptions* lists your followed channels' newest uploads.
- **Local mode (off by default).** This makes it work like Flow itself:
  - Subscribing, unsubscribing, liking and disliking stay on the device, and YouTube never hears
    about them.
  - Signed out, YouTube's "Sign in to subscribe / like" prompts are answered by Flow instead.
  - YouTube's Subscriptions tab shows Flow's local Subscriptions feed.
  - **Settings → Library** lists your Flow subscriptions, liked videos and history.

  For YouTube to know nothing, use it with YouTube signed out (profile picture → Switch account →
  *Use YouTube signed out*), after copying your subscriptions in.
- **Head start.** Settings (the sliders icon) lets you pick interests from Flow's catalog, or
  import subscriptions (Google Takeout `subscriptions.csv` or NewPipe `.json`) and watch history
  (Takeout `watch-history.json`).
- **Return YouTube Dislike (optional).** The workflow can add Return YouTube Dislike too. It's
  ticked by default, and skipped if your IPA already has it.

## How it's built

```
core/    Rust: FlowNeuro, unmodified from Flow Desktop (src/flow_neuro, 15k lines), Flow's
         Home feed assembly (src/home), and FlowTube's glue: engine.rs (Flow's
         RecommendationService + Home load, sync, one JSON state file), youtube.rs (InnerTube
         requests + Flow's own renderer parsers), import.rs, ffi.rs (C API: include/flowneuro.h)
tweak/   Objective-C: the feed UI, the Home/Subscriptions overlay, player/like sampling,
         command-router hooks (subscribe/like, local mode), settings and library
scripts/ build-dylib.sh and build-ryd.sh (no Theos install needed), inject-ipa.sh
tools/   macho_inject.py (from YTKACE, MIT)
```

The only changes to Flow's code are in the 8 files that touched SQLite and Tauri. Those now keep
their state in memory and save it as a snapshot. Flow's own test suites run unchanged:

```
cd core && cargo test      # 218 tests: Flow's unit + golden (Android parity) tests, plus FlowTube's
```

Tweak design notes:

- **Runtime hooks only.** The tweak uses Objective-C runtime hooks, with no Substrate, Logos or
  ElleKit. Every hook checks that the class and method exist, and chains to whatever was there
  before (YouTube's, or YTKACE's).
- **Untouched surfaces.** It never touches the tab bar (YTKACE manages that) or the player's
  time callbacks (YTKACE/SponsorBlock hook those). Playback is sampled from the visible player
  every 2 seconds instead.
- **Home placement.** Home is the `YTBrowseViewController` for `FEwhat_to_watch`. Flow sits
  directly above YouTube's feed view, in its frame and insets, so YouTube's top bar and chips stay
  on top.
- **Playing videos.** Videos play through YouTube's own `YTICommand` watch endpoint, as if you'd
  tapped one of its cards.
- **Subscribes and likes.** These are read from the commands passing through `YTCommandRouter`
  (YTKACE hooks the same routers). Each command's protobuf extensions are read by name
  (`subscribeEndpoint`, `unsubscribeEndpoint`, `likeEndpoint`, sign-in prompts), so only commands
  that actually run count. An "Unsubscribe?" dialog that's cancelled changes nothing.
- **Return YouTube Dislike.** It's built from PoomSmart's source with Logos's `internal`
  generator, so its hooks are plain runtime swaps too, and the IPA still needs no Substrate or
  ElleKit. Its `RYD.bundle` goes into the app.
- **Fallback.** If a future YouTube moves Home, a draggable Flow button opens it full screen
  instead.

## Getting an IPA (AltStore)

1. Push this folder to a GitHub repo (it can be private).
2. **Actions → Build → Run workflow.** Leave *IPA URL* empty to use the latest
   [YTKACE release](https://github.com/itzzace/ytkace/releases) (YouTube 21.42, iOS 17+), or
   tick *iOS 16* for its other build. To use YTPlusM or YTLitePlus instead, paste a direct link
   to that IPA.
   Untick *FlowTube* for an IPA with just Return YouTube Dislike added (artifact
   **YouTube-IPA**).
3. Download the **FlowTube-IPA** artifact, unzip it, and in AltStore go to **My Apps → +** and
   pick the IPA. Tick *release* if you'd rather have it as a GitHub release.

You'll be installing it as an IPA file instead of from YTKACE's AltStore source, so updates to
YTKACE mean re-running the workflow, which takes about 5 minutes.

### Building locally

macOS with Xcode: `rustup target add aarch64-apple-ios && scripts/build-dylib.sh`.

Linux: `SDKROOT=/path/to/iPhoneOS16.5.sdk scripts/build-dylib.sh` (needs clang + lld, and an SDK
from [theos/sdks](https://github.com/theos/sdks)).

Then run `scripts/inject-ipa.sh base.ipa out.ipa dist/FlowTube.dylib`. Add
`dist/YouTubeDislikesReturn.dylib --resource dist/RYD.bundle` after it (built by
`scripts/build-ryd.sh`) for Return YouTube Dislike. For a jailbroken device,
`tweak/Makefile` also builds a Theos `.deb`.

## Limits

- **Copying from your account.** This takes the channels on the first page YouTube loads for
  Subscriptions → All. For very long lists, Takeout's `subscriptions.csv` gets every channel.
- **Local mode and YouTube's buttons.** In local mode, FlowTube sets the watch page's subscribe and
  like state from Flow's own data before YouTube draws it, and switches a tapped Subscribe label
  right away. A like/dislike tap shows a toast, and the icon itself catches up the next time the
  video opens. These are undocumented parts of YouTube, so if a button doesn't follow, *Copy debug
  log* in Flow's settings shows what was found.
- **Signed-out prompts.** Telling which button opened a signed-out "Sign in" prompt goes by the
  button's accessibility label and the prompt's text. If one isn't caught, the normal sign-in
  prompt shows, and the device log says `[FlowTube] sign-in prompt` with what was seen.
- **Search.** YouTube searches don't teach Flow yet.
- **Not tested on a device.** This first version builds and links for iOS, and the engine is
  tested, but the hooks follow YouTube's current class names (the ones YTKACE uses) and haven't
  been run on a device yet. If something doesn't show up, search the device log for
  `[FlowTube]`: every skipped hook is logged there.

## License

GPL-3.0, like Flow, whose engine it contains. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
