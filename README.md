# Item Spirit AIUI Glasses Client

This is the AIUI framework route for Item Spirit.

It is now the primary glasses-side UX direction for:

- proactive paper-reading interaction;
- ASR/TTS foreground interaction;
- IMU and voice-wakeup event tagging;
- relay-connected paper OCR/Wiki companion flow;
- relay WebSocket + MiniCPM-o Realtime native video/audio full-duplex session,
  with short-turn fallbacks.

The existing Android Probe and phone companion are kept as validated hardware
fallbacks. In particular, AIUI `CameraContext.takePhoto()` and
`RecorderManager.start()` are documented as requiring an interactive call site,
so product-grade background camera still needs real AIUI device validation or
CXR-L phone companion fallback.

## Relay Contract

Default relay URL is stored in AIUI storage key `item_spirit_relay_url`.
If no value exists, the app starts with `http://127.0.0.1:8787`, then runs a
bootstrap check over the saved URL, the current public tunnel candidate
`https://blossom-foilable-kermit.ngrok-free.dev`, `127.0.0.1`, and `localhost`.
The first URL that answers `/api/config/status` is persisted before command
polling, Watch, and capability probes start.

Main relay calls:

- `POST /api/events`
- `POST /api/media`
- `POST /api/vision/run/{event_id}`
- `POST /api/ocr/run/{event_id}`
- `POST /api/memory/events/{event_id}/paper-companion`
- `GET /api/glasses/commands/stream?device_id=aiui-glasses&actions=...`
- `GET /api/glasses/commands/next?device_id=aiui-glasses&actions=hud.paper_companion,interaction.full_duplex_start,interaction.full_duplex_stop,camera.photo,audio.capture_sample,audio.play_model,config.set_relay_url`
- `POST /api/glasses/commands/{command_id}/ack`
- `POST /api/config/relay-url-command`
- `PATCH /api/interaction`
- `POST /api/duplex/runtime-probe`
- `WS /api/duplex/native-video-stream`
- `WS /api/duplex/realtime-stream` as a short audio fallback
- `POST /api/duplex/turn` as the formal turn fallback
- `POST /api/models/minicpmo/realtime-audio-probe` for diagnostics / legacy probe fallback
- `POST /api/models/minicpmo/realtime-session-smoke` for diagnostics / text fallback
- `POST /api/models/minicpmo/realtime-smoke` as fallback

## Three-device Deployment Boundary

- Computer / relay: runs `services/relay`, dashboard, MiniCPM-V, PaddleOCR,
  MiniCPM-o Realtime, Wiki memory, task routing and audit logs.
- Phone companion: owns product-grade background camera fallback through CXR-L
  when AIUI camera is blocked by the interactive gate.
- Glasses / AIUI: owns the foreground user experience: green HUD,
  voice wakeup, ASR/TTS, IMU tags, a transient shape-only HUD prompt,
  touchpad fallback selection, single-tap confirmation, and
  command stream + polling fallback for HUD, interaction, camera, short audio
  capture, text-to-speech playback, and relay URL configuration.

The AIUI app should connect to the relay through an HTTPS public tunnel or a
phone/relay proxy for no-ADB tests. `127.0.0.1` only works inside the same
device and is kept as the default developer placeholder.

## Preflight

From the project root:

```bash
scripts/aiui-preflight.sh
node scripts/aiui-local-smoke.mjs
scripts/aiui-toolchain-probe.sh
scripts/aiui-toolchain-probe.sh --online
```

This checks the AIUI project shape, `app.json`, `.ink` sections, HUD styling
constraints, and the relay contracts for paper companion and full-duplex.
`scripts/aiui-preflight.sh` also runs `scripts/aiui-local-smoke.mjs`, which
executes the page script in a mocked AIUI runtime and verifies Watch policy,
camera-gate fallback to phone companion, Recorder capability reporting,
`/api/duplex/runtime-probe` streaming readiness reporting, the preferred
`/api/duplex/native-video-stream` long-lived session, the short
`/api/duplex/realtime-stream` and `/api/duplex/turn` fallbacks, touchpad swipe
selection, single-tap full-duplex activation, full-duplex state sync, native
`input.append` audio/video frames, and GlobalHook double-tap exit
without claiming any live device command. It also verifies the relay `EventSource` command stream wakes
`/api/glasses/commands/next` without server-side claiming. Preflight also keeps
the wearable HUD hidden until prompt text is present, with no persistent
foreground buttons and shape-only state markers for the green optical guide.

`scripts/aiui-toolchain-probe.sh` records the AIUI skill source, verifies that
the project `.agents/skills/aiui-dev` copy still matches the shared
`~/kk_skill/skills/aiui-dev` source, checks local `aix`/`aiui`/`oaf` style
packager commands, and optionally clones
`jsar-project/AIUI` to inspect whether the public repository exposes an
installable AIX/OAF packager. Official QuickStart scaffolds with
`npm create @yodaos-pkg/aiui-agent my-agent` and the underlying package is
`@yodaos-pkg/create-aiui-agent`; it is a scaffold CLI, not a packager. The
official AIX local CLI is still not publicly discoverable from the current
machine or the public repository probe.

The current pack route is the Rokid Craft web packager:

1. Open `https://js.rokid.com/craft?lang=en-US&region=global`.
2. Choose `GitHub Subdirectory` and import the current AIUI-only remote:
   `https://github.com/Zacklinkk/item-spirit-aiui`.
3. Click `Pack`, then `Start Packaging`, and download the generated `.aix`.

Use GitHub Subdirectory as the default path because it gives Craft a clean
source boundary. The current remote repository contains only this AIUI app at
the repository root. If you instead import from a larger monorepo, use
`https://github.com/<owner>/<repo>/tree/<branch>/apps/glasses-aiui` and do not
import the full Item Spirit workspace; that would mix relay code, Vault
contents, Android builds, local data and `.env` files into a glasses package
boundary. `Local Folder` is a workable one-off fallback, but it asks the browser
for read/write access to the selected folder.

`scripts/package-aiui.sh` creates a source bundle under
`services/relay/data/aiui-builds/` by default. If the official Rokid AIUI/AIX
packager is installed, run it through `AIUI_PACKAGER_CMD`; the script exposes
`AIUI_SOURCE_DIR`, `AIUI_SOURCE_ZIP`, `AIUI_OUT_DIR`, `AIUI_BUILD_NAME`, and
`AIUI_ARTIFACT_PATH` to that command, then records whether the installable
AIX/OAF artifact was actually produced. The generated manifest includes the
local AIUI toolchain probe result, packager logs, and artifact metadata so the
bundle can be audited later.

## Validation Targets

1. Install/open this AIUI app without USB debugging.
2. Confirm `wx.request` can reach the relay over HTTPS/public tunnel or phone proxy.
   On startup AIUI tries its bootstrap URL candidates before opening the
   command stream and polling fallback.
   If the tunnel changes, queue `POST /api/config/relay-url-command` with the
   new HTTPS tunnel; AIUI persists it to storage key `item_spirit_relay_url`
   and ACKs the command through the previous relay URL.
3. Trigger the paper companion by relay command, voice, or the internal touchpad
   fallback while looking at a paper page; verify relay creates PaperCard and
   returns a paper companion briefing.
4. Single-tap while the HUD asks whether to add the paper to Wiki; verify relay
   records the approval and creates a local `paper_reading` task without asking
   the dashboard again.
5. Trigger full-duplex by proactive scheduler command or the internal touchpad
   fallback; verify AIUI first opens
   `WS /api/duplex/native-video-stream`, sends `session.start`, then keeps
   sending `input.append` audio frames with the latest captured visual frame.
   Relay/model `response.output.delta` messages should update the HUD/TTS at
   `listen` boundaries. If native-video startup fails, AIUI falls back to
   `WS /api/duplex/realtime-stream`, then `POST /api/duplex/turn`, then ASR text
   through the same formal duplex endpoint before using legacy smoke fallbacks.
6. Try active watch mode; if automatic timer camera is rejected by the interaction
   gate, relay should receive a `aiui.camera_gate_failed` event and a phone
   companion `camera.photo` capture proposal.
7. Queue `camera.photo` for `device_id=aiui-glasses` from the Dashboard
   `论文真机验收` panel's `AIUI 拍照` button, or call
   `POST /api/acceptance/paper-reading/queue-aiui-camera-command`. AIUI should
   claim it, attempt `CameraContext.takePhoto()`, ACK success with the created
   event or ACK failure with `fallback=phone_companion`. Successful AIUI image
   events include the triggering `command_id`, so relay can distinguish
   command-driven proactive capture from manual `Paper`.
   Use `PYTHONPATH=services/relay services/relay/scripts/aiui_camera_command_acceptance.py --relay-url http://127.0.0.1:8787`
   to observe the real command without claiming it from the script. Add
   `--allow-gate-fallback` only when validating the phone companion fallback
   path instead of direct AIUI camera success; add
   `--require-phone-fallback-photo` as well when the fallback should pass only
   after a linked real `phone_companion.cxr_photo` with `camera_route=cxr_l`.
8. Queue `audio.capture_sample`; AIUI should claim it and attempt Recorder ->
   MiniCPM-o audio probe. Queue `audio.play_model` with text to verify AIUI TTS;
   remote WAV playback remains Android Probe / native-player territory because
   AIUI `Sound` only supports local files.

## Paper-reading Acceptance Events

Successful direct AIUI camera path:

- `aiui.camera.photo` image event
- `vision_result` with `ocr_needed=true`
- `OCRResult.status=done`
- `hud.paper_companion` command with `payload.source_event_id`
- AIUI ACKs the HUD command as `running` after display, then a confirmation
  gesture sends `decision=approved`; relay records
  `aiui.paper_companion_decision` and creates a local `paper_reading` task.
- PaperCard under `ItemSpiritVault/Papers/`

Successful relay-driven proactive path:

- any glasses/phone image event enters the relay analysis queue
- relay runs Vision and OCR when text is detected
- relay auto-queues `hud.paper_companion` for paper/document/screen contexts
- AIUI command stream notifies availability, AIUI claims the HUD command through
  `/api/glasses/commands/next`, displays it, then waits for confirmation or
  Back/double-GlobalHook dismissal
- relay may also queue a bounded `camera.photo` command directly for
  `device_id=aiui-glasses`; AIUI claims it and attempts the same Paper pipeline.
  If the AIUI interactive gate rejects it, the command is ACKed as failed and
  the phone companion fallback proposal keeps the same policy/dedupe evidence.
  The paper live acceptance panel exposes this as `aiui_camera_command`; it is a
  command-executor proof alongside, not a replacement for, the Watch policy
  proof. `aiui_camera_command_acceptance.py` is the strict on-site observer for
  this proof and only passes by default when a true `aiui.camera.photo` image
  event is linked to the command. In gate-fallback mode, it only passes when
  `--require-phone-fallback-photo` sees a CXR-L phone photo linked by
  `source_event_id`, `dedupe_key`, or `policy_id`.

If AIUI camera is blocked:

- `aiui.camera_gate_failed` event
- `camera.photo` capture proposal for `device_id=phone-companion`,
  `kind=camera.photo`, and `auto_capture=true`
- final fallback proof should be `phone_companion.cxr_photo` once CXR token/session
  is configured

`Watch` is policy-driven. On page load and while Watch is enabled, the AIUI
client calls `/api/sensing/policy?scenario=paper_reading&cold_start_day=1`.
When the relay returns a `camera.photo` recommendation, AIUI attempts
`CameraContext.takePhoto()` and records `aiui.watch_policy`, `policy_id`,
`policy_state`, capture reason, and `dedupe_key` in the resulting event or
phone fallback job. The `aiui.watch_policy` event id is propagated as
`source_event_id` into `aiui.camera_gate_failed` and the phone companion
fallback `CaptureJob`, so live acceptance can prove the CXR-L fallback belongs
to the same proactive Watch decision rather than a manual script trigger. If no
camera job is recommended, the next Watch tick follows the relay
`photo_heartbeat_s` interval.

True-device paper HUD acceptance:

```bash
PYTHONPATH=services/relay services/relay/scripts/paper_reading_e2e_acceptance.py \
  --relay-url http://127.0.0.1:8787 \
  --mode auto-capture \
  --aiui-hud-mode observe \
  --require-any-ocr-evidence
```

`observe` mode does not claim or ACK `hud.paper_companion`. It waits for this
AIUI client to claim the command, show the paper companion HUD, and ACK
`decision=approved` when the user confirms while the paper prompt is pending. The same run now also requires
relay to queue the paper-specific `interaction.full_duplex_start` follow-up
with `source=relay.paper_companion_followup`, so a saved paper immediately
turns into an active companion prompt. Add
`--run-aiui-recorder-acceptance --require-aiui-recorder-model-output` to keep
the same acceptance run going into MiniCPM-o Realtime.

Live-session watcher for the paper-reading scene:

```bash
PYTHONPATH=services/relay services/relay/scripts/aiui_paper_live_session.py \
  --relay-url http://127.0.0.1:8787 \
  --prepare \
  --relay-url-for-aiui https://<public-relay-tunnel> \
  --materialize
```

This watcher is the recommended on-site operator loop. It may prepare the
current scene by cleaning stale AIUI paper commands, queueing the relay URL
configuration, and queueing one bounded `camera.photo` command. After that it
only observes `/api/acceptance/paper-reading/live-plan`, `/api/glasses/commands`
and `/api/events`; it never calls `/api/glasses/commands/next` or ACKs a command
on behalf of the glasses. The same `operator_stage` now appears in the live-plan
API and Dashboard paper acceptance panel. It reports the current gate, for
example `waiting_for_aiui_watch_policy`, `waiting_for_hud_wiki_approval`,
`waiting_for_relay_side_effect`, or `waiting_for_talk_recorder`, plus the next
physical action the operator should take.

## Full-duplex Acceptance Events

The current AIUI MVP now prefers a long-lived native video/audio full-duplex
session:

- `PATCH /api/interaction` sets `interaction_mode=full_duplex`
- AIUI posts `/api/duplex/runtime-probe` on startup. The relay records
  `aiui.duplex_runtime_probe` and recommends `native_video_stream`,
  `streaming_audio`, `short_audio_turn`, `asr_text_turn`, or `display_only`
  from the actual socket, camera, `RecorderManager`, ASR, TTS, and MiniCPM-o
  Realtime configuration.
- AIUI emits `aiui.capability_probe` on page load and
  `aiui.recorder_capability` before each Recorder attempt. These events expose
  whether `wx.media.getRecorderManager()`, `start/stop`, `onHeader`,
  `onFrameRecorded`, `onStop`, and `onError` are actually present on the
  current glasses runtime.
- AIUI first opens `WS /api/duplex/native-video-stream`, sends
  `session.start`, then keeps sending `input.append` messages containing
  float32 audio and the latest visual frame from `CameraContext.takePhoto()`.
  Relay forwards these chunks to the MiniCPM-o native-video Realtime route and
  returns `response.output.delta` messages for `text`, `audio`, and `listen`.
- `listen` deltas are treated as turn boundaries. AIUI records
  `aiui.native_video_stream_result`, updates HUD text, and speaks accumulated
  text with TTS while keeping the socket open.
- if native-video startup fails, AIUI falls back to the relay-level
  `WS /api/duplex/realtime-stream` WAV path, then to `/api/duplex/turn` with
  `input_type=audio`, `device_id=aiui-glasses`,
  `source=aiui.recorder_probe`, `scenario=duplex_interaction`, and
  `audio_probe=minicpmo`.
- if recorder frames are unavailable, the Recorder API is incomplete, the
  interactive gate blocks `start()`, or all audio fallbacks fail, AIUI releases
  the recorder busy state, writes the failure event, and falls back to ASR text
  through `/api/duplex/turn`.
- if the formal duplex endpoint fails, AIUI falls back to
  `/api/models/minicpmo/realtime-session-smoke`, then
  `/api/models/minicpmo/realtime-smoke`
- AIUI HUD displays the response and TTS speaks it
- Touchpad swipes map to `ArrowLeft`/`ArrowRight`/`ArrowUp`/`ArrowDown` and
  move the internal fallback action. AIUI emits `aiui.nav_select` for this.
- `Enter` or a single `GlobalHook` tap confirms the selected fallback action.
  With full-duplex selected, AIUI emits `aiui.nav_activate` and starts the same
  full-duplex overlay through `startFullDuplex({ reason: 'nav_tap_talk' })`.
- Double GlobalHook or Back exits the overlay.
- Automatic scheduler commands should normally start this overlay. The touchpad
  path is kept as an operator fallback; a single-finger double tap on the touch
  area maps to double `GlobalHook` and exits it.

True-device Recorder acceptance:

```bash
PYTHONPATH=services/relay services/relay/scripts/aiui_realtime_audio_acceptance.py \
  --relay-url http://127.0.0.1:8787 \
  --require-model-output \
  --require-non-silent-audio
```

This script does not claim commands on behalf of AIUI. It queues
`interaction.full_duplex_start`, watches `/api/glasses/commands` for the real
client to claim it, and only passes when `/api/events` contains AIUI Recorder or
native-video evidence from `device_id=aiui-glasses`. The preferred source is
`aiui.native_video_stream_result` with `recorder_route=aiui_native_video`; the
fallback sources are `aiui.duplex_stream` / `aiui.duplex_stream_result` with
`recorder_route=aiui_stream`, then `aiui.recorder_probe` /
`aiui.recorder_probe_result` with `recorder_route=aiui`.
Use `--no-queue-start-command --no-require-command-claimed` when starting
full-duplex manually on the glasses.

True-device touchpad-to-full-duplex acceptance:

```bash
PYTHONPATH=services/relay services/relay/scripts/glasses_nav_duplex_acceptance.py \
  --relay-url http://127.0.0.1:8787 \
  --require-audio-evidence \
  --require-non-silent-audio \
  --materialize
```

This observer does not synthesize `nav_select` or `nav_activate`. It passes
only after relay events show a real touchpad/action route into full-duplex, a
full-duplex start event, and, when requested, MiniCPM-o audio evidence. It
accepts both the AIUI source names and the Android Probe fallback source names,
so the same command can be used before and after the final AIX install path is
available. The materialized report is
`ItemSpiritVault/Projects/Glasses-Nav-Duplex-Acceptance.md`.

The source and mocked runtime now implement the MiniCPM-o native-video session
shape. Remaining true-device risks are AIUI Recorder frame cadence, camera
interactive-gate behavior during a long session, direct 24 kHz model-audio
playback, barge-in, and echo handling.

Source bundle:

Run `scripts/package-aiui.sh` from the repository root. It writes the current
Craft-compatible source zip and manifest under
`services/relay/data/aiui-builds/`. Use the script output or
`GET /api/aiui/toolchain` for the latest timestamped artifact.

Previous local Craft-compatible AIX:

- `services/relay/data/aiui-builds/item-spirit-aiui-20260701-151847-local-aix.aix`
- sha256 `b7e9b908db05e72eb3cb9b2d206617e5ffb14122037f6434ffd97d0c391111dd`
- size `102261` bytes
- This AIX predates the native-video full-duplex source update. Repack with
  Rokid Craft before installing this revision on glasses.

This build includes the policy-driven Watch loop, full-duplex startup ordering,
the AIUI duplex runtime profile probe, the public scaffold core
`package.json`, AIUI command handlers for `camera.photo`,
`audio.capture_sample`, `audio.play_model`, and
`config.set_relay_url`, the relay command `EventSource` notification path,
plus the `source_event_id` propagation needed when a failed AIUI
`camera.photo` command falls back to the phone companion. It also intercepts
touchpad swipe keys for internal fallback action selection, `Enter`/single
`GlobalHook` for selected-action confirmation, and double `GlobalHook` for
full-duplex exit.
The AIUI client patches relay
`interaction_mode=full_duplex` and emits `aiui.full_duplex` before starting the
native-video session, so subsequent `aiui.recorder_capability`,
`aiui.native_video_stream_result`, `aiui.duplex_stream`, or
`aiui.recorder_probe` evidence is aligned with the relay state timeline. Relay
also accepts the new `aiui.heartbeat` event as the foreground online signal for
the paper-reading live acceptance gate. When a follow-up full-duplex command or
fallback action opens after a paper HUD/brief, it now inherits the latest
`paper_title` and enters the `paper_reading` full-duplex prompt instead of
falling back to generic chat.
Paper brief display now also emits `aiui.paper_companion_prompt` before speaking
the short prompt, giving live acceptance a separate proof that the glasses-side
agent proactively interacted with the user before Wiki approval.
`interaction.full_duplex_start` commands can also pass `scenario`,
`source_event_id`, `paper_title`, and `opening_prompt`; the AIUI full-duplex overlay
uses those fields so paper-reading follow-up turns are recorded as
`paper_reading` instead of generic duplex traffic. The latest source now tries
`/api/duplex/native-video-stream` first and sends continuous `input.append`
audio/video frames until the user exits with double `GlobalHook` / Back.
If native-video startup fails, it falls back to the older relay WebSocket audio
stream and `/api/duplex/turn` upload paths.
The live-plan should prefer `aiui.native_video_stream_result` as real AIUI
Recorder evidence, with `aiui.duplex_stream` or `aiui.recorder_probe` accepted
as fallback evidence.

The current HUD source is a transient overlay: default screen is black/off,
and only proactive prompts or agent replies show a shape marker plus one short
line for about three seconds. Relay/browser diagnostics live in the dashboard
under the `交互` tab's `AIUI 调试` panel, including `启动智能体`, simulated
swipes, simulated single tap, full-duplex command queueing, and paper camera
command queueing.

Relay exposes the same packaging state:

- `GET /api/aiui/toolchain`
- `POST /api/aiui/toolchain/materialize`

The Dashboard task tab renders this as the `AIUI 工具链` panel, including
latest bundle, shared-skill status, install artifact readiness, missing
packager, and the live paper acceptance command.

The latest local source can still be bundled by `scripts/package-aiui.sh`, but
the installable path is Rokid Craft. After this native-video update, regenerate
the `.aix` from the AIUI-only source boundary before live glasses validation,
then watch for `aiui.heartbeat`, capability probe, touchpad, native-video
Recorder, and paper HUD events to reach the relay.

Before using Craft Remote import, run:

```bash
scripts/aiui-craft-import-check.py
```

It verifies the AIUI source boundary, JSON files, registered `.ink` pages, and
that no `.env`, token, database, Android build or Vault-like file has leaked
into `apps/glasses-aiui`.
