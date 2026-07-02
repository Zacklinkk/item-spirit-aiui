<script def>
{
  "navigationBarTitleText": "Item Spirit",
  "description": "Shows the Item Spirit glasses HUD for proactive paper reading, relay state, and full-duplex interaction.",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "mode": {
          "type": "string",
          "description": "Current foreground interaction mode"
        },
        "relayState": {
          "type": "string",
          "description": "Relay connection state"
        },
        "promptTitle": {
          "type": "string",
          "description": "Transient center HUD title"
        },
        "promptText": {
          "type": "string",
          "description": "Transient center HUD text"
        },
        "duplexActive": {
          "type": "boolean",
          "description": "Whether full-duplex overlay is active"
        }
      },
      "required": ["mode", "relayState", "duplexActive"]
    }
  }
}
</script>

<script setup>
import wx from 'wx';

const DEFAULT_RELAY = 'http://127.0.0.1:8787';
const DEVICE_ID = 'aiui-glasses';
const DUPLEX_TURN_LIMIT = 6;
const COMMAND_ACTIONS = 'hud.paper_companion,interaction.full_duplex_start,interaction.full_duplex_stop,camera.photo,audio.capture_sample,audio.play_model,config.set_relay_url';
const BOOTSTRAP_RELAY_URLS = [
  'https://blossom-foilable-kermit.ngrok-free.dev',
  'http://127.0.0.1:8787',
  'http://localhost:8787'
];
const WATCH_INITIAL_DELAY_MS = 1200;
const WATCH_MIN_DELAY_MS = 15000;
const WATCH_MAX_DELAY_MS = 240000;
const HEARTBEAT_INITIAL_DELAY_MS = 3000;
const HEARTBEAT_INTERVAL_MS = 30000;
const GLOBALHOOK_DOUBLE_TAP_MS = 420;
const GLOBALHOOK_SINGLE_TAP_DELAY_MS = 460;
const DUPLEX_NEXT_TURN_DELAY_MS = 650;
const NATIVE_VIDEO_FRAME_INTERVAL_MS = 1200;
const DUPLEX_PROACTIVE_PRIME_TIMEOUT_MS = 3000;
const DUPLEX_PROACTIVE_PRIME_PATH = '/static/proactive-start.f32';
const PROMPT_VISIBLE_MS = 3000;
const NAV_ACTIONS = [
  { id: 'talk', label: '全双工' },
  { id: 'paper', label: '论文' }
];

function normalizeRelayUrl(value) {
  const raw = String(value || '').trim();
  return raw ? raw.replace(/\/+$/, '') : DEFAULT_RELAY;
}

function relayWebSocketUrl(baseUrl, path) {
  const base = normalizeRelayUrl(baseUrl);
  const socketBase = base.indexOf('https://') === 0
    ? 'wss://' + base.slice('https://'.length)
    : base.indexOf('http://') === 0
      ? 'ws://' + base.slice('http://'.length)
      : base;
  return socketBase + path;
}

function jsonRequest(baseUrl, path, method, data) {
  return new Promise((resolve, reject) => {
    wx.request({
      url: normalizeRelayUrl(baseUrl) + path,
      method: method || 'GET',
      data: data || {},
      dataType: 'json',
      responseType: 'text',
      header: {
        'content-type': 'application/json'
      },
      success(res) {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(res.data);
        } else {
          reject(new Error('http_' + res.statusCode));
        }
      },
      fail(err) {
        reject(new Error(err && err.errMsg ? err.errMsg : 'request_failed'));
      }
    });
  });
}

function requestArrayBuffer(baseUrl, path, timeoutMs) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let timeoutId = 0;
    let requestTask = null;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      if (timeoutId) {
        clearTimeout(timeoutId);
        timeoutId = 0;
      }
      if (error) {
        reject(error);
        return;
      }
      resolve(value);
    };
    timeoutId = setTimeout(() => {
      try {
        if (requestTask && methodExists(requestTask, 'abort')) {
          requestTask.abort();
        }
      } catch (error) {
        // Abort is best-effort; the timeout still resolves the promise.
      }
      finish(new Error('request_timeout'));
    }, Number(timeoutMs) > 0 ? Number(timeoutMs) : DUPLEX_PROACTIVE_PRIME_TIMEOUT_MS);
    try {
      requestTask = wx.request({
        url: normalizeRelayUrl(baseUrl) + path,
        method: 'GET',
        responseType: 'arraybuffer',
        success(response) {
          if (response.statusCode >= 200 && response.statusCode < 300) {
            finish(null, response.data);
          } else {
            finish(new Error('http_' + response.statusCode));
          }
        },
        fail(error) {
          finish(new Error(error && error.errMsg ? error.errMsg : 'request_failed'));
        }
      });
    } catch (error) {
      finish(error);
    }
  });
}

function compactText(value, limit) {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  return text.length > limit ? text.slice(0, limit - 1) + '…' : text;
}

function reasonText(value, fallback) {
  return typeof value === 'string' && value.trim() ? value.trim() : fallback;
}

function eventIdFromResponse(value) {
  if (!value) return '';
  if (value.event_id) return value.event_id;
  if (value.event && value.event.event_id) return value.event.event_id;
  return '';
}

function toUint8Array(value) {
  if (value instanceof Uint8Array) return value;
  return new Uint8Array(value);
}

function concatBuffers(buffers) {
  let size = 0;
  const parts = [];
  for (const buffer of buffers) {
    if (!buffer) continue;
    const bytes = toUint8Array(buffer);
    if (!bytes.length) continue;
    parts.push(bytes);
    size += bytes.length;
  }
  const output = new Uint8Array(size);
  let offset = 0;
  for (const bytes of parts) {
    output.set(bytes, offset);
    offset += bytes.length;
  }
  return output.buffer;
}

function pcm16ArrayBufferToFloat32Base64(buffer) {
  const bytes = new Uint8Array(buffer || new ArrayBuffer(0));
  if (!bytes.length) return '';
  let offset = 0;
  if (
    bytes.length > 44 &&
    bytes[0] === 82 &&
    bytes[1] === 73 &&
    bytes[2] === 70 &&
    bytes[3] === 70
  ) {
    for (let i = 12; i < bytes.length - 8; i += 1) {
      if (bytes[i] === 100 && bytes[i + 1] === 97 && bytes[i + 2] === 116 && bytes[i + 3] === 97) {
        offset = i + 8;
        break;
      }
    }
    if (!offset) offset = 44;
  }
  const usableBytes = bytes.length - offset - ((bytes.length - offset) % 2);
  if (usableBytes <= 0) return '';
  const view = new DataView(bytes.buffer, bytes.byteOffset + offset, usableBytes);
  const samples = new Float32Array(usableBytes / 2);
  for (let i = 0; i < samples.length; i += 1) {
    samples[i] = Math.max(-1, Math.min(1, view.getInt16(i * 2, true) / 32768));
  }
  return wx.arrayBufferToBase64(samples.buffer);
}

function isWavBuffer(buffer) {
  const bytes = toUint8Array(buffer);
  return bytes.length > 16 &&
    bytes[0] === 82 &&
    bytes[1] === 73 &&
    bytes[2] === 70 &&
    bytes[3] === 70 &&
    bytes[8] === 87 &&
    bytes[9] === 65 &&
    bytes[10] === 86 &&
    bytes[11] === 69;
}

function methodExists(target, name) {
  return Boolean(target && typeof target[name] === 'function');
}

function clampNumber(value, minValue, maxValue, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(minValue, Math.min(maxValue, parsed));
}

function pickCameraJob(policy) {
  const jobs = policy && policy.recommended_capture_jobs ? policy.recommended_capture_jobs : [];
  for (const job of jobs) {
    if (job && job.kind === 'camera.photo') return job;
  }
  return null;
}

function preventDefaultIfPossible(event) {
  if (event && typeof event.preventDefault === 'function') {
    event.preventDefault();
  }
}

function eventFieldValues(event) {
  const values = [];
  if (!event) return values;
  for (const key of ['code', 'key', 'action', 'type', 'direction', 'gesture', 'name']) {
    if (event[key] !== undefined && event[key] !== null) values.push(event[key]);
  }
  if (event.detail) {
    if (typeof event.detail === 'string') {
      values.push(event.detail);
    } else {
      for (const key of ['code', 'key', 'action', 'type', 'direction', 'gesture', 'name']) {
        if (event.detail[key] !== undefined && event.detail[key] !== null) {
          values.push(event.detail[key]);
        }
      }
    }
  }
  return values;
}

function eventText(event) {
  return eventFieldValues(event).map(value => String(value).toLowerCase()).join(' ');
}

function eventKeyCode(event) {
  const raw = event && (event.keyCode !== undefined ? event.keyCode : event.which);
  const value = Number(raw);
  return Number.isFinite(value) ? value : 0;
}

function hasAny(text, values) {
  for (const value of values) {
    if (text.indexOf(value) >= 0) return true;
  }
  return false;
}

function classifyNavKey(event) {
  const text = eventText(event);
  const keyCode = eventKeyCode(event);
  if (keyCode === 8 || hasAny(text, ['backspace', 'escape', 'esc', 'system_back', 'systemback'])) {
    return 'back';
  }
  if (hasAny(text, ['globalhook', 'global_hook', 'temple', 'hook'])) {
    return 'globalhook';
  }
  if (keyCode === 13 || hasAny(text, ['enter', 'confirm', 'select', 'ok', 'single_tap', 'singletap', 'tap', 'click'])) {
    return 'tap';
  }
  if (
    keyCode === 39 ||
    keyCode === 40 ||
    hasAny(text, ['arrowright', 'arrowdown', 'dpad_right', 'dpad_down', 'dpadrigh', 'dpaddown', 'swipe_right', 'swiperight', 'swipe_down', 'swipedown', 'scroll_down', 'scrolldown', 'next', 'forward'])
  ) {
    return 'next';
  }
  if (
    keyCode === 37 ||
    keyCode === 38 ||
    hasAny(text, ['arrowleft', 'arrowup', 'dpad_left', 'dpad_up', 'dpadleft', 'dpadup', 'swipe_left', 'swipeleft', 'swipe_up', 'swipeup', 'scroll_up', 'scrollup', 'previous', 'prev', 'backward'])
  ) {
    return 'prev';
  }
  return '';
}

function navReasonFromEvent(event, fallback) {
  const values = eventFieldValues(event);
  for (const value of values) {
    const text = String(value || '').trim();
    if (text) return text;
  }
  return fallback;
}

function validRelayUrl(value) {
  const raw = String(value || '').trim();
  return raw.indexOf('https://') === 0 || raw.indexOf('http://') === 0;
}

function optionalGlobal(name) {
  try {
    if (typeof globalThis !== 'undefined' && globalThis && globalThis[name]) {
      return globalThis[name];
    }
  } catch (error) {
    // Some runtimes expose only a narrow QuickJS global scope.
  }
  try {
    if (typeof window !== 'undefined' && window && window[name]) {
      return window[name];
    }
  } catch (error) {
    // Window is not guaranteed in the AIUI simulator.
  }
  return null;
}

function navActionAt(index) {
  const normalized = ((Number(index) || 0) % NAV_ACTIONS.length + NAV_ACTIONS.length) % NAV_ACTIONS.length;
  return NAV_ACTIONS[normalized];
}

function statePatch(state) {
  const safeState = state || 'watch';
  return {
    stateIcon: '',
    stateIconClass: 'status-mark state-' + safeState
  };
}

function uniqueRelayCandidates(values) {
  const seen = {};
  const candidates = [];
  for (const value of values) {
    if (!validRelayUrl(value)) continue;
    const normalized = normalizeRelayUrl(value);
    if (seen[normalized]) continue;
    seen[normalized] = true;
    candidates.push(normalized);
  }
  return candidates;
}

export default {
  data: {
    relayUrl: DEFAULT_RELAY,
    relayState: 'relay --',
    mode: 'Watch',
    sensorLine: 'imu --',
    taskLine: 'idle',
    stateIcon: '○',
    stateIconClass: 'status-mark state-watch',
    promptTitle: '',
    promptText: '',
    promptTimerId: 0,
    watchActive: true,
    watchTimerId: 0,
    heartbeatTimerId: 0,
    lastHeartbeatAt: 0,
    latestWatchPolicyId: '',
    latestWatchPolicyEventId: '',
    latestWatchReason: '',
    lastPolicyCaptureAt: 0,
    duplexActive: false,
    duplexTurnActive: false,
    duplexTurnTimerId: 0,
    duplexNativeSessionActive: false,
    recorderProbeActive: false,
    duplexTurns: 0,
    duplexRuntimeRoute: 'short_audio_turn',
    duplexStreamReady: false,
    duplexScenario: 'duplex_interaction',
    duplexPrompt: '',
    duplexPaperTitle: '',
    duplexVisualEventId: '',
    duplexCommandPayload: {},
    commandPolling: false,
    commandStreamActive: false,
    commandStreamLastEvent: '',
    lastGlobalHookAt: 0,
    globalHookSingleTapTimerId: 0,
    navIndex: 0,
    selectedAction: 'talk',
    selectedActionLabel: '全双工',
    latestPaperTitle: '',
    latestEventId: '',
    latestPaperCommandId: '',
    latestPaperCardPath: '',
    latestPaperDecisionPending: false
  },

  onLoad() {
    this.installPromptAutoClear();
    let stored = '';
    try {
      stored = wx.getStorageSync('item_spirit_relay_url') || '';
    } catch (error) {
      stored = '';
    }
    this.setData({ relayUrl: normalizeRelayUrl(stored) });
    this.bootstrapRelayAndStart();
  },

  onUnload() {
    this.setData({ commandPolling: false });
    this.stopCommandStream();
    this.clearGlobalHookSingleTapTimer();
    this.clearDuplexTurnTimer();
    this.clearHeartbeatTimer();
    this.clearWatchTimer();
    this.clearPromptTimer();
    this.stopFullDuplex('page_unload');
  },

  installPromptAutoClear() {
    if (this.__itemSpiritPromptAutoClearInstalled) return;
    const nativeSetData = this.setData;
    if (typeof nativeSetData !== 'function') return;
    this.__itemSpiritPromptAutoClearInstalled = true;
    this.setData = (patch, callback) => {
      nativeSetData.call(this, patch, callback);
      if (patch && (
        Object.prototype.hasOwnProperty.call(patch, 'promptTitle') ||
        Object.prototype.hasOwnProperty.call(patch, 'promptText')
      )) {
        this.schedulePromptAutoClear();
      }
    };
  },

  clearPromptTimer() {
    if (this.data.promptTimerId) {
      clearTimeout(this.data.promptTimerId);
      this.setData({ promptTimerId: 0 });
    }
  },

  schedulePromptAutoClear() {
    const hasPrompt = Boolean(this.data.promptTitle || this.data.promptText);
    this.clearPromptTimer();
    if (!hasPrompt) return;
    const timerId = setTimeout(() => {
      this.setData({
        promptTitle: '',
        promptText: '',
        promptTimerId: 0
      });
    }, PROMPT_VISIBLE_MS);
    this.setData({ promptTimerId: timerId });
  },

  onKeyUp(event) {
    const navKey = classifyNavKey(event);
    if (navKey === 'back') {
      if (this.data.duplexActive) {
        preventDefaultIfPossible(event);
        this.stopFullDuplex('back_key');
      }
      return;
    }
    if (navKey === 'next') {
      preventDefaultIfPossible(event);
      this.moveNavSelection(1, navReasonFromEvent(event, 'touchpad_swipe_next'));
      return;
    }
    if (navKey === 'prev') {
      preventDefaultIfPossible(event);
      this.moveNavSelection(-1, navReasonFromEvent(event, 'touchpad_swipe_prev'));
      return;
    }
    if (navKey === 'tap') {
      preventDefaultIfPossible(event);
      const tapReason = navReasonFromEvent(event, 'enter_key');
      this.activateSelectedAction(tapReason === 'Enter' ? 'enter_key' : tapReason);
      return;
    }
    if (navKey === 'globalhook') {
      const now = Date.now();
      if (this.data.duplexActive && now - this.data.lastGlobalHookAt < GLOBALHOOK_DOUBLE_TAP_MS) {
        preventDefaultIfPossible(event);
        this.clearGlobalHookSingleTapTimer();
        this.stopFullDuplex('globalhook_double_tap');
        this.setData({ lastGlobalHookAt: 0 });
        return;
      }
      preventDefaultIfPossible(event);
      this.setData({ lastGlobalHookAt: now });
      this.scheduleGlobalHookSingleTap('globalhook_single_tap');
    }
  },

  clearGlobalHookSingleTapTimer() {
    if (this.data.globalHookSingleTapTimerId) {
      clearTimeout(this.data.globalHookSingleTapTimerId);
      this.setData({ globalHookSingleTapTimerId: 0 });
    }
  },

  scheduleGlobalHookSingleTap(reason) {
    this.clearGlobalHookSingleTapTimer();
    const timerId = setTimeout(() => {
      this.setData({ globalHookSingleTapTimerId: 0 });
      this.activateSelectedAction(reason);
    }, GLOBALHOOK_SINGLE_TAP_DELAY_MS);
    this.setData({ globalHookSingleTapTimerId: timerId });
  },

  moveNavSelection(delta, reason) {
    const nextIndex = this.data.navIndex + delta;
    const action = navActionAt(nextIndex);
    const normalizedIndex = ((nextIndex % NAV_ACTIONS.length) + NAV_ACTIONS.length) % NAV_ACTIONS.length;
    this.setData({
      navIndex: normalizedIndex,
      selectedAction: action.id,
      selectedActionLabel: action.label,
      taskLine: 'sel ' + action.label,
      ...statePatch(action.id === 'talk' ? 'duplex' : 'paper')
    });
    this.postEvent('aiui.nav_select', 'interaction', {
      selected_action: action.id,
      selected_label: action.label,
      nav_index: normalizedIndex,
      reason: reasonText(reason, 'touchpad_swipe'),
      scenario: action.id === 'talk' ? 'duplex_interaction' : 'paper_reading'
    }, {
      input_route: 'touchpad_swipe',
      selected_action: action.id
    });
  },

  activateSelectedAction(reason) {
    const action = navActionAt(this.data.navIndex);
    this.setData({
      taskLine: 'tap ' + action.label,
      selectedAction: action.id,
      selectedActionLabel: action.label,
      ...statePatch(action.id === 'talk' ? 'duplex' : 'paper')
    });
    this.postEvent('aiui.nav_activate', 'interaction', {
      selected_action: action.id,
      selected_label: action.label,
      reason: reasonText(reason, 'touchpad_tap'),
      scenario: action.id === 'talk' ? 'duplex_interaction' : 'paper_reading'
    }, {
      input_route: 'touchpad_tap',
      selected_action: action.id
    });
    if (action.id === 'paper') {
      if (this.data.latestPaperDecisionPending) {
        this.confirmPaperWiki();
      } else {
        this.capturePaperFrame('nav_tap_paper');
      }
    } else if (action.id === 'talk') {
      this.startFullDuplex({ reason: 'nav_tap_talk' });
    }
  },

  tapTalkButton() {
    this.setData({ navIndex: 0 });
    this.activateSelectedAction('button_talk');
  },

  tapPaperButton() {
    this.setData({ navIndex: 1 });
    this.activateSelectedAction('button_paper');
  },

  async bootstrapRelayAndStart() {
    await this.bootstrapRelay();
    this.startImuTags();
    this.startCommandPolling();
    this.startCommandStream();
    this.postCapabilityProbe();
    this.postDuplexRuntimeProbe();
    this.postEvent('aiui.app_open', 'status', {
      aiui_route: true,
      note: 'AIUI client opened'
    }, { mode: 'Watch' });
    this.startHeartbeat();
    this.schedulePaperWatch(WATCH_INITIAL_DELAY_MS);
  },

  async bootstrapRelay() {
    const candidates = uniqueRelayCandidates([
      this.data.relayUrl,
      ...BOOTSTRAP_RELAY_URLS
    ]);
    let latestError = null;
    for (const relayUrl of candidates) {
      try {
        await jsonRequest(relayUrl, '/api/config/status', 'GET');
        try {
          if (wx.setStorageSync) {
            wx.setStorageSync('item_spirit_relay_url', relayUrl);
          }
        } catch (storageError) {
          // Keep the session URL even if persistent storage is unavailable.
        }
        this.setData({
          relayUrl,
          relayState: 'relay ok',
          promptTitle: '',
          promptText: '',
          ...statePatch('watch')
        });
        return relayUrl;
      } catch (error) {
        latestError = error;
      }
    }
    this.setData({
      relayState: 'relay --',
      promptTitle: 'RELAY',
      promptText: compactText(latestError && latestError.message ? latestError.message : 'unreachable', 36),
      ...statePatch('error')
    });
    return this.data.relayUrl;
  },

  recorderCapabilities(recorder) {
    return {
      recorder_available: Boolean(recorder),
      recorder_start: methodExists(recorder, 'start'),
      recorder_stop: methodExists(recorder, 'stop'),
      recorder_on_header: methodExists(recorder, 'onHeader'),
      recorder_on_frame: methodExists(recorder, 'onFrameRecorded'),
      recorder_on_start: methodExists(recorder, 'onStart'),
      recorder_on_stop: methodExists(recorder, 'onStop'),
      recorder_on_error: methodExists(recorder, 'onError')
    };
  },

  async postCapabilityProbe() {
    let recorder = null;
    let camera = null;
    try {
      recorder = wx.media && wx.media.getRecorderManager ? wx.media.getRecorderManager() : null;
    } catch (error) {
      recorder = null;
    }
    try {
      camera = wx.media && wx.media.createCameraContext ? wx.media.createCameraContext() : null;
    } catch (error) {
      camera = null;
    }
    const recorderCaps = this.recorderCapabilities(recorder);
    const payload = {
      wx_media: Boolean(wx.media),
      camera_context_available: Boolean(camera),
      socket_available: Boolean(wx.createSocket || wx.connectSocket),
      event_source_available: Boolean(wx.createEventSource),
      speech_recognition_available: Boolean(wx.speech && wx.speech.startRecognition),
      speech_tts_available: Boolean(wx.speech && wx.speech.playTTS),
      web_speech_recognition_available: Boolean(optionalGlobal('SpeechRecognition')),
      web_speech_tts_available: Boolean(optionalGlobal('speechSynthesis')),
      ...recorderCaps
    };
    await this.postEvent('aiui.capability_probe', 'status', {
      ...payload,
      scenario: 'duplex_interaction'
    }, {
      recorder_route: 'aiui',
      recorder_ready: Boolean(
        recorderCaps.recorder_available &&
        recorderCaps.recorder_start &&
        recorderCaps.recorder_stop &&
        recorderCaps.recorder_on_header &&
        recorderCaps.recorder_on_frame
      )
    });
  },

  async postDuplexRuntimeProbe() {
    let recorder = null;
    let camera = null;
    try {
      recorder = wx.media && wx.media.getRecorderManager ? wx.media.getRecorderManager() : null;
    } catch (error) {
      recorder = null;
    }
    try {
      camera = wx.media && wx.media.createCameraContext ? wx.media.createCameraContext() : null;
    } catch (error) {
      camera = null;
    }
    const recorderCaps = this.recorderCapabilities(recorder);
    try {
      const result = await jsonRequest(this.data.relayUrl, '/api/duplex/runtime-probe', 'POST', {
        device_id: DEVICE_ID,
        scenario: 'duplex_interaction',
        state_context: 'Watch',
        reason: 'aiui_bootstrap_runtime_probe',
        transport: {
          socket_available: Boolean(wx.createSocket || wx.connectSocket),
          create_socket_available: Boolean(wx.createSocket),
          connect_socket_available: Boolean(wx.connectSocket),
          event_source_available: Boolean(wx.createEventSource),
          camera_context_available: Boolean(camera)
        },
        recorder: recorderCaps,
        speech: {
          speech_recognition_available: Boolean(wx.speech && wx.speech.startRecognition),
          web_speech_recognition_available: Boolean(optionalGlobal('SpeechRecognition'))
        },
        tts: {
          speech_tts_available: Boolean(wx.speech && wx.speech.playTTS),
          web_speech_tts_available: Boolean(optionalGlobal('speechSynthesis'))
        },
        preferred_route: 'native_video_stream',
        tags: {
          aiui_online: true,
          runtime_probe: true
        }
      });
      const profile = result && result.profile ? result.profile : {};
      this.setData({
        duplexRuntimeRoute: profile.recommended_route || this.data.duplexRuntimeRoute,
        duplexStreamReady: Boolean(profile.stream_ready),
        taskLine: profile.recommended_route ? String(profile.recommended_route).replace('_audio', '') : this.data.taskLine
      });
      return result;
    } catch (error) {
      await this.postEvent('aiui.duplex_runtime_probe_failed', 'capability', {
        error: error.message,
        scenario: 'duplex_interaction'
      }, {
        duplex_runtime_probe: true
      });
      return null;
    }
  },

  onVoiceWakeup(event) {
    const keyword = String(event && event.keyword ? event.keyword : '').toLowerCase();
    this.postEvent('aiui.voice_wakeup', 'audio', { keyword }, { voice_wakeup: keyword });
    if (keyword.indexOf('论文') >= 0 || keyword.indexOf('paper') >= 0) {
      this.capturePaperFrame('voice_wakeup_paper');
    } else {
      this.startFullDuplex();
    }
  },

  async pingRelay() {
    try {
      await jsonRequest(this.data.relayUrl, '/api/config/status', 'GET');
      this.setData({ relayState: 'relay ok', ...statePatch(this.data.duplexActive ? 'duplex' : 'watch') });
    } catch (error) {
      this.setData({ relayState: 'relay --', promptTitle: 'RELAY', promptText: compactText(error.message, 36), ...statePatch('error') });
    }
  },

  startHeartbeat() {
    this.clearHeartbeatTimer();
    this.scheduleHeartbeat(HEARTBEAT_INITIAL_DELAY_MS);
  },

  clearHeartbeatTimer() {
    if (this.data.heartbeatTimerId) {
      clearTimeout(this.data.heartbeatTimerId);
      this.setData({ heartbeatTimerId: 0 });
    }
  },

  scheduleHeartbeat(delayMs) {
    this.clearHeartbeatTimer();
    const timerId = setTimeout(async () => {
      await this.postHeartbeat();
      this.scheduleHeartbeat(HEARTBEAT_INTERVAL_MS);
    }, clampNumber(delayMs, 1000, HEARTBEAT_INTERVAL_MS, HEARTBEAT_INITIAL_DELAY_MS));
    this.setData({ heartbeatTimerId: timerId });
  },

  async postHeartbeat() {
    const now = Date.now();
    const previous = this.data.lastHeartbeatAt || 0;
    this.setData({ lastHeartbeatAt: now });
    await this.postEvent('aiui.heartbeat', 'status', {
      scenario: 'paper_reading',
      mode: this.data.mode || 'Watch',
      relay_state: this.data.relayState || '',
      watch_active: Boolean(this.data.watchActive),
      duplex_active: Boolean(this.data.duplexActive),
      command_polling: Boolean(this.data.commandPolling),
      command_stream_active: Boolean(this.data.commandStreamActive),
      latest_watch_policy_id: this.data.latestWatchPolicyId || '',
      latest_event_id: this.data.latestEventId || '',
      uptime_hint_ms: previous ? now - previous : 0
    }, {
      aiui_online: true,
      watch_active: Boolean(this.data.watchActive),
      interaction_mode: this.data.duplexActive ? 'full_duplex' : 'watch'
    });
  },

  async postEvent(source, modality, payload, tags) {
    try {
      return await jsonRequest(this.data.relayUrl, '/api/events', 'POST', {
        device_id: DEVICE_ID,
        state_context: this.data.mode || 'Watch',
        scenario: payload && payload.scenario ? payload.scenario : 'paper_reading',
        source,
        modality,
        payload: payload || {},
        tags: tags || {},
        confidence: 0.9,
        privacy: 'normal'
      });
    } catch (error) {
      this.setData({ relayState: 'relay err' });
      return null;
    }
  },

  startCommandPolling() {
    if (this.data.commandPolling) return;
    this.setData({ commandPolling: true });
    this.scheduleCommandPoll(800);
  },

  scheduleCommandPoll(delayMs) {
    setTimeout(async () => {
      if (!this.data.commandPolling) return;
      await this.pollNextCommand();
      this.scheduleCommandPoll(this.data.duplexActive ? 1200 : 2200);
    }, delayMs);
  },

  startCommandStream() {
    this.stopCommandStream(false);
    if (!wx.createEventSource) {
      this.setData({ commandStreamActive: false, commandStreamLastEvent: 'unsupported' });
      return;
    }
    const streamUrl = normalizeRelayUrl(this.data.relayUrl) +
      '/api/glasses/commands/stream?device_id=' + encodeURIComponent(DEVICE_ID) +
      '&actions=' + encodeURIComponent(COMMAND_ACTIONS);
    try {
      const task = wx.createEventSource({
        url: streamUrl,
        method: 'GET',
        dataType: 'json'
      });
      this.commandStreamTask = task;
      this.setData({ commandStreamActive: true, commandStreamLastEvent: 'connect' });
      if (methodExists(task, 'onOpen')) {
        task.onOpen(() => {
          this.setData({ relayState: 'relay live', commandStreamActive: true, commandStreamLastEvent: 'open' });
        });
      }
      if (methodExists(task, 'onMessage')) {
        task.onMessage((message) => {
          this.handleCommandStreamMessage(message);
        });
      }
      if (methodExists(task, 'onError')) {
        task.onError(() => {
          this.setData({ commandStreamActive: false, commandStreamLastEvent: 'error', relayState: 'relay poll' });
          this.commandStreamTask = null;
          setTimeout(() => {
            if (this.data.commandPolling) {
              this.startCommandStream();
            }
          }, 5000);
        });
      }
    } catch (error) {
      this.setData({ commandStreamActive: false, commandStreamLastEvent: 'failed' });
    }
  },

  stopCommandStream(updateState) {
    const task = this.commandStreamTask;
    this.commandStreamTask = null;
    if (task && methodExists(task, 'close')) {
      try {
        task.close();
      } catch (error) {
        // Closing is best-effort; polling remains the fallback command path.
      }
    }
    if (updateState !== false) {
      this.setData({ commandStreamActive: false, commandStreamLastEvent: 'closed' });
    }
  },

  handleCommandStreamMessage(message) {
    let payload = {};
    const raw = message && typeof message.data === 'string' ? message.data : '';
    if (raw) {
      try {
        payload = JSON.parse(raw);
      } catch (error) {
        payload = {};
      }
    } else if (message && typeof message.data === 'object' && message.data) {
      payload = message.data;
    }
    const eventName = (message && message.event) || payload.type || '';
    if (eventName === 'command_available' || payload.command_id) {
      this.setData({
        relayState: 'relay live',
        commandStreamActive: true,
        commandStreamLastEvent: 'command'
      });
      this.pollNextCommand();
      return;
    }
    if (eventName === 'heartbeat' || eventName === 'hello') {
      this.setData({
        relayState: 'relay live',
        commandStreamActive: true,
        commandStreamLastEvent: eventName
      });
    }
  },

  async pollNextCommand() {
    try {
      const result = await jsonRequest(
        this.data.relayUrl,
        '/api/glasses/commands/next?device_id=' + DEVICE_ID + '&actions=' + COMMAND_ACTIONS,
        'GET'
      );
      const command = result && result.command ? result.command : null;
      if (command) {
        await this.handleRelayCommand(command);
      }
    } catch (error) {
      this.setData({ relayState: 'relay err' });
    }
  },

  async handleRelayCommand(command) {
    const action = command.action || '';
    if (action === 'hud.paper_companion') {
      this.displayPaperCommandPayload(command.payload || {}, command.command_id);
      await this.ackRelayCommand(command.command_id, 'running', 'aiui_paper_companion_displayed', {
        decision: 'shown',
        interaction_state: 'awaiting_user_decision'
      });
      return;
    }
    if (action === 'interaction.full_duplex_start') {
      await this.startFullDuplex(command.payload || {});
      await this.ackRelayCommand(command.command_id, 'done', 'aiui_full_duplex_started', {
        source_event_id: (command.payload || {}).source_event_id || '',
        paper_title: (command.payload || {}).paper_title || '',
        scenario: (command.payload || {}).scenario || 'duplex_interaction',
        reason: (command.payload || {}).reason || 'relay_command'
      });
      return;
    }
    if (action === 'interaction.full_duplex_stop') {
      await this.stopFullDuplex('relay_command');
      await this.ackRelayCommand(command.command_id, 'done', 'aiui_full_duplex_stopped');
      return;
    }
    if (action === 'camera.photo') {
      const result = await this.handleCameraPhotoCommand(command);
      await this.ackRelayCommand(
        command.command_id,
        result.ok ? 'done' : 'failed',
        result.ok ? 'aiui_camera_photo_done' : 'aiui_camera_photo_failed',
        result
      );
      return;
    }
    if (action === 'audio.capture_sample') {
      const result = await this.handleAudioCaptureCommand(command);
      await this.ackRelayCommand(
        command.command_id,
        result.ok ? 'done' : 'failed',
        result.ok ? 'aiui_audio_capture_done' : 'aiui_audio_capture_failed',
        result
      );
      return;
    }
    if (action === 'audio.play_model') {
      const result = await this.handleAudioPlaybackCommand(command);
      await this.ackRelayCommand(
        command.command_id,
        result.ok ? 'done' : 'failed',
        result.ok ? 'aiui_audio_playback_done' : 'aiui_audio_playback_failed',
        result
      );
      return;
    }
    if (action === 'config.set_relay_url') {
      const previousRelayUrl = this.data.relayUrl;
      const result = await this.handleRelayUrlConfigCommand(command);
      await this.ackRelayCommand(
        command.command_id,
        result.ok ? 'done' : 'failed',
        result.ok ? 'aiui_relay_url_configured' : 'aiui_relay_url_config_failed',
        result,
        previousRelayUrl
      );
      if (result.ok) {
        this.pingRelay();
        this.startCommandStream();
      }
      return;
    }
    await this.ackRelayCommand(command.command_id, 'failed', 'unsupported_aiui_action');
  },

  async handleRelayUrlConfigCommand(command) {
    const payload = command.payload || {};
    const rawRelayUrl = payload.relay_url || payload.url || '';
    if (!validRelayUrl(rawRelayUrl)) {
      this.setData({ relayState: 'relay bad', promptTitle: 'RELAY', promptText: 'invalid url' });
      return {
        ok: false,
        action: 'config.set_relay_url',
        command_id: command.command_id,
        error: 'invalid_relay_url'
      };
    }
    const relayUrl = normalizeRelayUrl(rawRelayUrl);
    try {
      if (payload.persist !== false && wx.setStorageSync) {
        wx.setStorageSync('item_spirit_relay_url', relayUrl);
      }
      this.setData({
        relayUrl,
        relayState: 'relay set',
        promptTitle: 'RELAY',
        promptText: compactText(relayUrl, 44)
      });
      await this.postEvent('aiui.relay_url_configured', 'status', {
        command_id: command.command_id,
        relay_url: relayUrl,
        persisted: payload.persist !== false,
        scenario: 'duplex_interaction'
      }, {
        config_route: 'aiui_storage',
        storage_key: 'item_spirit_relay_url'
      });
      return {
        ok: true,
        action: 'config.set_relay_url',
        command_id: command.command_id,
        relay_url: relayUrl,
        persisted: payload.persist !== false
      };
    } catch (error) {
      this.setData({ relayState: 'relay cfg err', promptTitle: 'RELAY', promptText: compactText(error.message, 44) });
      return {
        ok: false,
        action: 'config.set_relay_url',
        command_id: command.command_id,
        relay_url: relayUrl,
        error: error.message
      };
    }
  },

  async handleCameraPhotoCommand(command) {
    const payload = command.payload || {};
    const job = payload.job || {};
    const captureContext = payload.capture_context || {};
    const reason = captureContext.capture_trigger || job.reason || payload.reason || 'camera_photo_command';
    const policy = job.policy || payload.policy || null;
    const sourceEventId = payload.source_event_id || job.source_event_id || captureContext.source_event_id || '';
    const result = await this.capturePaperFrame(reason, {
      policy,
      job,
      command_id: command.command_id,
      capture_context: captureContext,
      source_event_id: sourceEventId
    });
    return {
      ...result,
      action: 'camera.photo',
      command_id: command.command_id,
      auto_capture: Boolean(job.auto_capture || payload.auto_capture),
      dedupe_key: job.dedupe_key || '',
      source_event_id: result && result.event_id ? result.event_id : sourceEventId
    };
  },

  async handleAudioCaptureCommand(command) {
    const payload = command.payload || {};
    const scenario = payload.scenario || 'duplex_interaction';
    const prompt = payload.prompt || '用户正在通过 Rokid 眼镜和器灵进行语音交互。请根据音频内容用一句中文回应。';
    this.setData({
      duplexScenario: scenario,
      duplexPrompt: prompt,
      mode: 'Task',
      taskLine: 'mic',
      promptTitle: 'VOICE',
      promptText: 'listening'
    });
    try {
      const result = await this.recordAndCallRealtimeAudio(payload.reason || 'audio_capture_command');
      const answer = compactText(result && result.answer ? result.answer : '我听到了。', 80);
      this.setData({ taskLine: 'voice ok', promptTitle: 'VOICE', promptText: answer });
      this.speak(answer);
      return {
        ok: true,
        action: 'audio.capture_sample',
        command_id: command.command_id,
        scenario,
        answer
      };
    } catch (error) {
      this.setData({ taskLine: 'mic gate', promptTitle: 'VOICE', promptText: compactText(error.message, 44) });
      await this.postEvent('aiui.audio_capture_failed', 'audio', {
        command_id: command.command_id,
        error: error.message,
        scenario
      }, {
        recorder_route: 'aiui',
        capture_trigger: payload.reason || 'audio_capture_command'
      });
      return {
        ok: false,
        action: 'audio.capture_sample',
        command_id: command.command_id,
        scenario,
        error: error.message
      };
    }
  },

  async handleAudioPlaybackCommand(command) {
    const payload = command.payload || {};
    const spokenText = payload.text || payload.speech_text || payload.response_text || payload.prompt || '';
    if (spokenText) {
      const text = compactText(spokenText, 120);
      this.setData({ taskLine: 'tts', promptTitle: 'VOICE', promptText: compactText(text, 44) });
      this.speak(text);
      await this.postEvent('aiui.audio_playback', 'audio', {
        command_id: command.command_id,
        audio_kind: payload.audio_kind || 'model_response',
        route: 'aiui_tts',
        text_chars: text.length,
        scenario: payload.scenario || 'duplex_interaction'
      }, {
        audio_route: 'aiui_tts'
      });
      return {
        ok: true,
        action: 'audio.play_model',
        command_id: command.command_id,
        route: 'aiui_tts',
        text_chars: text.length
      };
    }
    this.setData({ taskLine: 'audio ref', promptTitle: 'VOICE', promptText: 'audio file unsupported' });
    await this.postEvent('aiui.audio_playback_failed', 'audio', {
      command_id: command.command_id,
      output_audio_ref: payload.output_audio_ref || '',
      output_audio_url: payload.output_audio_url || '',
      error: 'aiui_sound_requires_local_file'
    }, {
      audio_route: 'unsupported_remote_audio'
    });
    return {
      ok: false,
      action: 'audio.play_model',
      command_id: command.command_id,
      error: 'aiui_sound_requires_local_file'
    };
  },

  async ackRelayCommand(commandId, status, note, extraPayload, relayUrlOverride) {
    if (!commandId) return;
    const payload = extraPayload || {};
    const ackEventId = payload.event_id || payload.source_event_id || this.data.latestEventId || '';
    try {
      await jsonRequest(relayUrlOverride || this.data.relayUrl, '/api/glasses/commands/' + commandId + '/ack', 'POST', {
        status,
        note,
        event_id: ackEventId,
        payload: {
          device_id: DEVICE_ID,
          route: 'aiui',
          source_event_id: this.data.latestEventId,
          paper_title: this.data.latestPaperTitle,
          paper_card_path: this.data.latestPaperCardPath,
          ...payload
        }
      });
    } catch (error) {
      this.setData({ relayState: 'relay err' });
    }
  },

  startWatch() {
    const next = !this.data.watchActive;
    this.setData({
      watchActive: next,
      mode: next ? 'Watch' : 'Idle',
      promptTitle: '',
      promptText: '',
      taskLine: next ? 'watch policy' : 'idle',
      ...statePatch(next ? 'watch' : 'idle')
    });
    this.postEvent('aiui.watch_toggle', 'status', {
      watch_active: next,
      scenario: 'paper_reading'
    }, { watch_active: next });
    if (next) {
      this.schedulePaperWatch(WATCH_INITIAL_DELAY_MS);
    } else {
      this.clearWatchTimer();
    }
  },

  clearWatchTimer() {
    if (this.data.watchTimerId) {
      clearTimeout(this.data.watchTimerId);
      this.setData({ watchTimerId: 0 });
    }
  },

  schedulePaperWatch(delayMs) {
    if (!this.data.watchActive) return;
    this.clearWatchTimer();
    const timerId = setTimeout(async () => {
      if (!this.data.watchActive) return;
      await this.runPaperWatchPolicy();
    }, clampNumber(delayMs, WATCH_INITIAL_DELAY_MS, WATCH_MAX_DELAY_MS, WATCH_INITIAL_DELAY_MS));
    this.setData({ watchTimerId: timerId });
  },

  async runPaperWatchPolicy() {
    let policy = null;
    let cameraJob = null;
    let nextDelayMs = 90000;
    try {
      const hour = new Date().getHours();
      policy = await jsonRequest(
        this.data.relayUrl,
        '/api/sensing/policy?scenario=paper_reading&cold_start_day=1&local_hour=' + hour,
        'GET'
      );
      cameraJob = pickCameraJob(policy);
      const intervals = policy && policy.intervals ? policy.intervals : {};
      nextDelayMs = clampNumber((intervals.photo_heartbeat_s || 90) * 1000, WATCH_MIN_DELAY_MS, WATCH_MAX_DELAY_MS, 90000);
      const reasons = policy && policy.reasons ? policy.reasons : [];
      const policyId = policy && policy.policy_id ? policy.policy_id : '';
      const policyState = policy && policy.perception_state ? policy.perception_state : 'Watch';
      this.setData({
        mode: policyState,
        latestWatchPolicyId: policyId,
        latestWatchReason: reasons.length ? compactText(reasons[0], 36) : '',
        taskLine: cameraJob ? 'policy photo' : 'policy wait',
        ...statePatch(policyState === 'Idle' ? 'idle' : 'watch')
      });
      const watchPolicyEvent = await this.postEvent('aiui.watch_policy', 'status', {
        policy_id: policyId,
        perception_state: policyState,
        sampling_score: policy && policy.sampling_score,
        reason: reasons.length ? reasons[0] : '',
        recommended_camera_job: cameraJob,
        scenario: 'paper_reading'
      }, {
        policy_id: policyId,
        policy_state: policyState,
        capture_trigger: cameraJob ? (cameraJob.reason || 'policy_camera_job') : 'policy_wait'
      });
      const watchPolicyEventId = eventIdFromResponse(watchPolicyEvent);
      if (watchPolicyEventId) {
        this.setData({ latestWatchPolicyEventId: watchPolicyEventId });
      }
      if (cameraJob) {
        await this.capturePaperFrame('aiui_policy_' + reasonText(cameraJob.reason, 'camera_job'), {
          policy,
          job: cameraJob,
          source_event_id: watchPolicyEventId
        });
      }
    } catch (error) {
      this.setData({ taskLine: 'policy err', promptTitle: 'WATCH', promptText: compactText(error.message, 36), ...statePatch('error') });
      await this.postEvent('aiui.watch_policy_error', 'status', {
        error: error.message,
        scenario: 'paper_reading'
      }, {
        capture_trigger: 'policy_error'
      });
      nextDelayMs = 60000;
    }
    this.schedulePaperWatch(nextDelayMs);
  },

  startImuTags() {
    try {
      const accelerometer = new Accelerometer({ frequency: 15 });
      accelerometer.addEventListener('reading', () => {
        const magnitude = Math.sqrt(
          (accelerometer.x || 0) * (accelerometer.x || 0) +
          (accelerometer.y || 0) * (accelerometer.y || 0) +
          (accelerometer.z || 0) * (accelerometer.z || 0)
        );
        const label = magnitude > 13 ? 'moving' : 'stable';
        this.setData({ sensorLine: 'imu ' + label });
      });
      accelerometer.addEventListener('error', () => {
        this.setData({ sensorLine: 'imu err' });
      });
      accelerometer.start();
    } catch (error) {
      this.setData({ sensorLine: 'imu --' });
    }
  },

  async capturePaperFrame(reason, watchContext) {
    const captureReason = reasonText(reason, 'paper_button');
    const policy = watchContext && watchContext.policy ? watchContext.policy : null;
    const policyJob = watchContext && watchContext.job ? watchContext.job : null;
    const commandId = watchContext && watchContext.command_id ? watchContext.command_id : '';
    const triggerSourceEventId = watchContext && watchContext.source_event_id ? watchContext.source_event_id : '';
    const policyId = policy && policy.policy_id ? policy.policy_id : '';
    const policyState = policy && policy.perception_state ? policy.perception_state : '';
    const policyReason = policy && policy.reasons && policy.reasons.length ? policy.reasons[0] : '';
    const captureJobReason = policyJob && policyJob.reason ? policyJob.reason : '';
    const captureJobDedupeKey = policyJob && policyJob.dedupe_key ? policyJob.dedupe_key : '';
    this.setData({
      mode: 'Focus',
      taskLine: 'camera',
      promptTitle: '',
      promptText: '',
      ...statePatch('paper')
    });
    try {
      const camera = wx.media && wx.media.createCameraContext ? wx.media.createCameraContext() : undefined;
      if (!camera) {
        throw new Error('camera_unavailable');
      }
      const photo = await camera.takePhoto({ quality: 'high' });
      const base64 = wx.arrayBufferToBase64(photo.data);
      const media = await jsonRequest(this.data.relayUrl, '/api/media', 'POST', {
        filename: 'aiui_paper_' + Date.now() + '.jpg',
        content_base64: base64,
        media_type: photo.mimeType || 'image/jpeg',
        create_event: true,
        device_id: DEVICE_ID,
        state_context: 'Focus',
        scenario: 'paper_reading',
        source: 'aiui.camera.photo',
        modality: 'image',
        tags: {
          camera_route: 'aiui',
          visual_context: 'paper',
          capture_trigger: captureReason,
          ocr_needed: true,
          auto_capture: Boolean(policyJob && policyJob.auto_capture),
          policy_id: policyId,
          policy_state: policyState,
          capture_job_reason: captureJobReason,
          capture_job_dedupe_key: captureJobDedupeKey,
          command_id: commandId,
          source_event_id: triggerSourceEventId
        },
        payload: {
          title_hint: 'AIUI paper capture',
          route: 'aiui_camera',
          visual_context: 'paper',
          capture_trigger: captureReason,
          command_id: commandId,
          source_event_id: triggerSourceEventId,
          policy_id: policyId,
          policy_reason: policyReason,
          capture_job: policyJob || null
        },
        confidence: 0.92,
        privacy: 'normal'
      });
      this.setData({ lastPolicyCaptureAt: Date.now() });
      const eventId = media && media.event && media.event.event_id ? media.event.event_id : '';
      this.setData({ latestEventId: eventId, taskLine: 'ocr' });
      if (eventId) {
        await jsonRequest(this.data.relayUrl, '/api/vision/run/' + eventId, 'POST', {});
        await jsonRequest(this.data.relayUrl, '/api/ocr/run/' + eventId, 'POST', {});
        const companion = await jsonRequest(this.data.relayUrl, '/api/memory/events/' + eventId + '/paper-companion', 'POST', {});
        this.showPaperCompanion(companion);
      }
      return {
        ok: true,
        route: 'aiui_camera',
        event_id: eventId,
        source_event_id: eventId,
        trigger_source_event_id: triggerSourceEventId,
        command_id: commandId,
        policy_id: policyId,
        dedupe_key: captureJobDedupeKey,
        reason: captureReason
      };
    } catch (error) {
      this.setData({
        taskLine: 'camera gate',
        promptTitle: '',
        promptText: '',
        ...statePatch('error')
      });
      await this.postEvent('aiui.camera_gate_failed', 'status', {
        reason: captureReason,
        error: error.message,
        scenario: 'paper_reading',
        command_id: commandId,
        source_event_id: triggerSourceEventId,
        policy_id: policyId,
        capture_job: policyJob || null
      }, {
        camera_route: 'aiui',
        fallback: 'phone_companion',
        command_id: commandId,
        source_event_id: triggerSourceEventId,
        policy_id: policyId,
        capture_job_dedupe_key: captureJobDedupeKey,
        capture_job_reason: captureJobReason
      });
      await this.proposePhoneCapture(captureReason, watchContext || {});
      return {
        ok: false,
        route: 'aiui_camera',
        fallback: 'phone_companion',
        error: error.message,
        command_id: commandId,
        source_event_id: triggerSourceEventId,
        policy_id: policyId,
        dedupe_key: captureJobDedupeKey,
        reason: captureReason
      };
    }
  },

  async captureDuplexVisualFrame(reason, context) {
    const captureReason = reasonText(reason, 'duplex_auto_visual');
    const scenario = context && context.scenario ? context.scenario : 'duplex_interaction';
    const triggerSourceEventId = context && context.source_event_id ? context.source_event_id : '';
    this.setData({
      mode: 'Focus',
      taskLine: 'look',
      promptTitle: '',
      promptText: '',
      ...statePatch('duplex')
    });
    try {
      const camera = wx.media && wx.media.createCameraContext ? wx.media.createCameraContext() : undefined;
      if (!camera) {
        throw new Error('camera_unavailable');
      }
      const photo = await camera.takePhoto({ quality: 'high' });
      const base64 = wx.arrayBufferToBase64(photo.data);
      const media = await jsonRequest(this.data.relayUrl, '/api/media', 'POST', {
        filename: 'aiui_duplex_' + Date.now() + '.jpg',
        content_base64: base64,
        media_type: photo.mimeType || 'image/jpeg',
        create_event: true,
        device_id: DEVICE_ID,
        state_context: 'Focus',
        scenario,
        source: 'aiui.duplex_camera.photo',
        modality: 'image',
        tags: {
          camera_route: 'aiui',
          visual_context: 'duplex',
          capture_trigger: captureReason,
          ocr_needed: true,
          auto_capture: true,
          source_event_id: triggerSourceEventId,
          duplex_visual_context: true
        },
        payload: {
          title_hint: 'AIUI duplex visual frame',
          route: 'aiui_camera',
          visual_context: 'duplex',
          capture_trigger: captureReason,
          source_event_id: triggerSourceEventId
        },
        confidence: 0.9,
        privacy: 'normal'
      });
      const eventId = media && media.event && media.event.event_id ? media.event.event_id : '';
      if (eventId) {
        this.setData({
          latestEventId: eventId,
          duplexVisualEventId: eventId,
          taskLine: 'look ok'
        });
        try {
          await jsonRequest(this.data.relayUrl, '/api/vision/run/' + eventId, 'POST', {});
          await jsonRequest(this.data.relayUrl, '/api/ocr/run/' + eventId, 'POST', {});
        } catch (analysisError) {
          await this.postEvent('aiui.duplex_visual_analysis_failed', 'status', {
            event_id: eventId,
            error: analysisError.message,
            scenario
          }, {
            visual_context_event_id: eventId,
            interaction_mode: 'full_duplex'
          });
        }
      }
      return {
        ok: Boolean(eventId),
        route: 'aiui_camera',
        event_id: eventId,
        source_event_id: eventId,
        reason: captureReason
      };
    } catch (error) {
      this.setData({
        taskLine: 'look gate',
        promptTitle: '',
        promptText: '',
        ...statePatch('duplex')
      });
      await this.postEvent('aiui.duplex_camera_gate_failed', 'status', {
        reason: captureReason,
        error: error.message,
        scenario,
        source_event_id: triggerSourceEventId
      }, {
        camera_route: 'aiui',
        fallback: 'phone_companion',
        interaction_mode: 'full_duplex',
        visual_context: 'duplex',
        source_event_id: triggerSourceEventId
      });
      await this.proposePhoneCapture(captureReason, {
        source_event_id: triggerSourceEventId,
        job: {
          scenario,
          visual_context: 'duplex',
          reason: captureReason,
          priority: 0.9,
          deadline_ms: 5000,
          auto_capture: true,
          dedupe_key: 'aiui-duplex-' + Math.floor(Date.now() / 60000),
          budget: {
            route: 'cxr_l',
            source: 'aiui_duplex_fallback'
          }
        }
      });
      return {
        ok: false,
        route: 'aiui_camera',
        fallback: 'phone_companion',
        error: error.message,
        source_event_id: triggerSourceEventId,
        reason: captureReason
      };
    }
  },

  async proposePhoneCapture(reason, watchContext) {
    const policy = watchContext && watchContext.policy ? watchContext.policy : null;
    const policyJob = watchContext && watchContext.job ? watchContext.job : null;
    const jobReason = policyJob && policyJob.reason ? policyJob.reason : reason;
    const policyId = policy && policy.policy_id ? policy.policy_id : '';
    const sourceEventId = (watchContext && watchContext.source_event_id) || this.data.latestEventId || '';
    try {
      await jsonRequest(this.data.relayUrl, '/api/capture-jobs/propose', 'POST', {
        device_id: 'phone-companion',
        kind: 'camera.photo',
        priority: policyJob && policyJob.priority ? policyJob.priority : 0.9,
        reason: jobReason,
        resource_lock: 'camera',
        deadline_ms: policyJob && policyJob.deadline_ms ? policyJob.deadline_ms : 5000,
        dedupe_key: policyJob && policyJob.dedupe_key ? policyJob.dedupe_key : 'aiui-paper-' + Math.floor(Date.now() / 60000),
        budget: {
          route: 'cxr_l',
          source: 'aiui_fallback',
          policy_id: policyId,
          policy_reason: policy && policy.reasons && policy.reasons.length ? policy.reasons[0] : '',
          ...(policyJob && policyJob.budget ? policyJob.budget : {})
        },
        state_context: policyJob && policyJob.state_context ? policyJob.state_context : 'Focus',
        scenario: policyJob && policyJob.scenario ? policyJob.scenario : 'paper_reading',
        visual_context: policyJob && policyJob.visual_context ? policyJob.visual_context : 'paper',
        source_event_id: sourceEventId,
        auto_capture: true
      });
    } catch (error) {
      this.setData({ taskLine: 'fallback err' });
    }
  },

  showPaperCompanion(result) {
    const briefing = result && result.briefing ? result.briefing : {};
    const command = result && result.command ? result.command : {};
    const payload = command && command.payload ? command.payload : { briefing };
    this.displayPaperCommandPayload(payload, command.command_id || '');
  },

  displayPaperCommandPayload(payload, commandId) {
    const briefing = payload && payload.briefing ? payload.briefing : payload;
    this.displayPaperBriefing(briefing || {}, commandId || '', payload || {});
  },

  displayPaperBriefing(briefing, commandId, payload) {
    const lines = briefing.hud_lines || [];
    const title = briefing.paper_title || 'Paper';
    const text = lines.length ? lines.join(' ') : briefing.abstract_draft || '已识别论文，是否沉淀到 Wiki？';
    const sourceEventId = briefing.source_event_id || (payload && payload.source_event_id) || this.data.latestEventId;
    const paperCardPath = briefing.paper_card_path || (payload && payload.paper_card_path) || '';
    const promptText = compactText(text, 44);
    const spokenPrompt = compactText('发现论文：' + title + '。' + text, 80);
    this.setData({
      latestPaperTitle: title,
      latestEventId: sourceEventId,
      latestPaperCommandId: commandId || this.data.latestPaperCommandId,
      latestPaperCardPath: paperCardPath,
      latestPaperDecisionPending: Boolean(commandId || briefing.ask_to_add_to_wiki),
      taskLine: 'wiki ready',
      promptTitle: 'PAPER',
      promptText: promptText,
      ...statePatch('paper')
    });
    this.postEvent('aiui.paper_companion_prompt', 'interaction', {
      state: 'shown',
      paper_title: title,
      prompt_text: promptText,
      spoken_prompt: spokenPrompt,
      command_id: commandId || '',
      source_event_id: sourceEventId || '',
      paper_card_path: paperCardPath,
      ask_to_add_to_wiki: Boolean(commandId || briefing.ask_to_add_to_wiki),
      voice_prompt: true
    }, {
      proactive_interaction: true,
      prompt_route: 'hud_tts',
      paper_context: true,
      command_id: commandId || '',
      source_event_id: sourceEventId || ''
    });
    this.speak(spokenPrompt);
  },

  async confirmPaperWiki() {
    if (!this.data.latestPaperDecisionPending) {
      this.setData({ taskLine: 'no paper', promptTitle: 'WIKI', promptText: 'no pending paper' });
      return;
    }
    if (this.data.latestPaperCommandId) {
      await this.ackRelayCommand(this.data.latestPaperCommandId, 'done', 'aiui_paper_companion_approved', {
        decision: 'approved'
      });
    } else if (this.data.latestEventId) {
      await jsonRequest(this.data.relayUrl, '/api/memory/events/' + this.data.latestEventId + '/paper-reading-task', 'POST', {});
    }
    this.setData({
      latestPaperDecisionPending: false,
      latestPaperCommandId: '',
      taskLine: 'wiki saved',
      promptTitle: 'WIKI',
      promptText: 'saved as paper task',
      ...statePatch('watch')
    });
    this.speak('已加入 Wiki 草案。');
  },

  async rejectPaperWiki(reason) {
    if (!this.data.latestPaperDecisionPending) {
      this.clearPrompt();
      return;
    }
    if (this.data.latestPaperCommandId) {
      await this.ackRelayCommand(this.data.latestPaperCommandId, 'done', 'aiui_paper_companion_denied', {
        decision: 'denied',
        reason: reasonText(reason, 'user_dismissed')
      });
    }
    this.setData({
      latestPaperDecisionPending: false,
      latestPaperCommandId: '',
      taskLine: 'wiki skipped',
      promptTitle: '',
      promptText: '',
      ...statePatch('watch')
    });
  },

  async startFullDuplex(context) {
    const payload = context || {};
    const duplexCommandPayload = Object.keys(payload).length ? payload : (this.data.duplexCommandPayload || {});
    const paperTitle = payload.paper_title || this.data.duplexPaperTitle || this.data.latestPaperTitle || '';
    let sourceEventId = payload.source_event_id || payload.visual_context_event_id || this.data.latestEventId || '';
    let visualEventId = payload.visual_context_event_id || sourceEventId || this.data.duplexVisualEventId || '';
    const scenario = payload.scenario || (paperTitle ? 'paper_reading' : 'duplex_interaction');
    const prompt = payload.prompt || (
      paperTitle
        ? '请结合当前论文、眼镜看到的画面、OCR/视觉标签和我的 Wiki 记忆，用中文短句主动伴读。'
        : '你是器灵，正在通过 Rokid 眼镜和用户全双工交流。请同时结合用户语音、最近看到的画面、OCR/视觉标签和记忆上下文，用中文短句回应。'
    );
    const openingText = payload.opening_prompt || (paperTitle ? '论文伴读已打开' : (visualEventId ? '听看中' : 'listening'));
    const startReason = payload.reason || (paperTitle ? 'aiui_talk_paper_button' : 'aiui_talk_button');
    if (this.data.duplexActive) {
      this.setData({
        duplexScenario: scenario,
        duplexPrompt: prompt || this.data.duplexPrompt,
        duplexPaperTitle: paperTitle || this.data.duplexPaperTitle,
        duplexVisualEventId: visualEventId || this.data.duplexVisualEventId,
        duplexCommandPayload,
        latestEventId: sourceEventId,
        promptText: compactText(openingText, 80),
        ...statePatch('duplex')
      });
      if (this.data.duplexRuntimeRoute === 'native_video_stream') {
        try {
          const nativeStarted = await this.startNativeVideoDuplexSession('context_update');
          if (nativeStarted) return;
        } catch (error) {
          await this.postEvent('aiui.native_video_stream_failed', 'audio', {
            error: error.message,
            scenario
          }, {
            recorder_route: 'aiui_native_video',
            interaction_mode: 'full_duplex',
            fallback: 'streaming_audio'
          });
        }
      }
      this.scheduleNextDuplexTurn('context_update', 80);
      return;
    }
    this.setData({
      duplexActive: true,
      duplexTurns: 0,
      duplexScenario: scenario,
      duplexPrompt: prompt,
      duplexPaperTitle: paperTitle,
      duplexVisualEventId: visualEventId,
      duplexCommandPayload,
      latestEventId: sourceEventId,
      mode: 'Task',
      promptTitle: 'DUPLEX',
      promptText: compactText(openingText, 80),
      taskLine: 'talk on',
      ...statePatch('duplex')
    });
    await this.patchInteraction('full_duplex', startReason, scenario);
    if (!visualEventId) {
      const visualResult = await this.captureDuplexVisualFrame('duplex_start_auto_visual', {
        scenario,
        source_event_id: sourceEventId
      });
      if (visualResult && visualResult.event_id) {
        visualEventId = visualResult.event_id;
        sourceEventId = visualResult.event_id;
        this.setData({
          duplexVisualEventId: visualEventId,
          latestEventId: sourceEventId
        });
      }
    }
    await this.postEvent('aiui.full_duplex', 'interaction', {
      state: 'started',
      scenario,
      reason: startReason,
      paper_title: paperTitle,
      source_event_id: sourceEventId,
      visual_context_event_id: visualEventId,
      multimodal_context_active: Boolean(visualEventId),
      paper_context_active: Boolean(paperTitle)
    }, {
      interaction_mode: 'full_duplex',
      multimodal_context: Boolean(visualEventId),
      visual_context_event_id: visualEventId,
      paper_context: Boolean(paperTitle)
    });
    let nativeStarted = false;
    if (this.data.duplexRuntimeRoute === 'native_video_stream') {
      try {
        nativeStarted = await this.startNativeVideoDuplexSession(startReason);
      } catch (error) {
        await this.postEvent('aiui.native_video_stream_failed', 'audio', {
          error: error.message,
          scenario
        }, {
          recorder_route: 'aiui_native_video',
          interaction_mode: 'full_duplex',
          fallback: 'streaming_audio'
        });
        this.setData({ taskLine: 'audio fallback' });
      }
    }
    if (!nativeStarted) {
      this.scheduleNextDuplexTurn('duplex_start', 80);
    }
  },

  clearDuplexTurnTimer() {
    if (this.data.duplexTurnTimerId) {
      clearTimeout(this.data.duplexTurnTimerId);
      this.setData({ duplexTurnTimerId: 0 });
    }
  },

  scheduleNextDuplexTurn(reason, delayMs) {
    if (!this.data.duplexActive) return;
    this.clearDuplexTurnTimer();
    const timerId = setTimeout(() => {
      this.setData({ duplexTurnTimerId: 0 });
      if (this.data.duplexActive) {
        this.runDuplexTurn(reasonText(reason, 'duplex_loop'));
      }
    }, clampNumber(delayMs, 80, 5000, DUPLEX_NEXT_TURN_DELAY_MS));
    this.setData({ duplexTurnTimerId: timerId });
  },

  finishDuplexAnswer(answerText, taskPrefix) {
    const answer = compactText(answerText || '我听到了。', 80);
    const nextTurn = this.data.duplexTurns + 1;
    this.setData({
      duplexTurns: nextTurn,
      taskLine: taskPrefix + ' ' + nextTurn,
      promptTitle: 'DUPLEX',
      promptText: answer
    });
    this.speak(answer);
    if (nextTurn >= DUPLEX_TURN_LIMIT) {
      this.stopFullDuplex('turn_budget_done');
      return;
    }
    this.scheduleNextDuplexTurn('auto_continue_' + nextTurn, DUPLEX_NEXT_TURN_DELAY_MS);
  },

  async runDuplexTurn(reason) {
    if (!this.data.duplexActive) return;
    if (this.data.duplexTurnActive) return;
    if (this.data.duplexTurns >= DUPLEX_TURN_LIMIT) {
      this.stopFullDuplex('turn_budget_done');
      return;
    }
    this.clearDuplexTurnTimer();
    this.setData({ duplexTurnActive: true, taskLine: 'rec', promptTitle: 'DUPLEX', promptText: 'speak now' });
    try {
      const audioResult = await this.recordAndCallRealtimeAudio(reasonText(reason, 'duplex_turn'));
      if (audioResult && audioResult.answer) {
        this.finishDuplexAnswer(audioResult.answer, 'audio');
        return;
      }
    } catch (audioError) {
      await this.postEvent('aiui.recorder_probe_failed', 'audio', {
        error: audioError.message,
        scenario: this.data.duplexScenario || 'duplex_interaction'
      }, {
        recorder_route: 'aiui',
        interaction_mode: 'full_duplex'
      });
    }
    this.setData({ taskLine: 'asr', promptTitle: 'DUPLEX', promptText: 'speak now' });
    try {
      const userText = await this.recognizeOnce();
      if (!userText) {
        this.setData({ taskLine: 'asr empty', promptText: '继续说' });
        this.scheduleNextDuplexTurn('asr_empty', 1200);
        return;
      }
      this.setData({ taskLine: 'model', promptText: compactText(userText, 44) });
      const result = await this.callRealtimeSession(userText);
      this.finishDuplexAnswer(result.answer || '我听到了。', result.session ? 'session' : 'turn');
    } catch (error) {
      this.setData({
        taskLine: 'talk err',
        promptTitle: 'DUPLEX',
        promptText: compactText(error.message, 44)
      });
      this.postEvent('aiui.full_duplex_error', 'interaction', {
        error: error.message,
        scenario: this.data.duplexScenario || 'duplex_interaction'
      }, { interaction_mode: 'full_duplex' });
    } finally {
      this.setData({ duplexTurnActive: false });
    }
  },

  async fetchProactivePrimeBase64() {
    const response = await requestArrayBuffer(
      this.data.relayUrl,
      DUPLEX_PROACTIVE_PRIME_PATH,
      DUPLEX_PROACTIVE_PRIME_TIMEOUT_MS
    );
    return wx.arrayBufferToBase64(response);
  },

  async sendNativeVideoProactivePrime(session, sendJson, refreshFrame) {
    if (!this.data.duplexActive || session.proactivePrimeSent) return false;
    await refreshFrame();
    if (session.closed || !this.data.duplexActive) return false;
    const audio = await this.fetchProactivePrimeBase64();
    if (session.closed || !this.data.duplexActive) return false;
    sendJson({
      type: 'input.append',
      input: {
        audio,
        video_frames: session.latestFrameBase64 ? [session.latestFrameBase64] : [],
        force_listen: false,
        max_slice_nums: 1
      }
    });
    if (session.closed || !this.data.duplexActive) return false;
    session.proactivePrimeSent = true;
    if (session.closed || !this.data.duplexActive) return false;
    await this.postEvent('aiui.native_video_proactive_prime', 'audio', {
      ok: true,
      scenario: this.data.duplexScenario || 'duplex_interaction',
      video_frame_attached: Boolean(session.latestFrameBase64)
    }, {
      recorder_route: 'aiui_native_video',
      interaction_mode: 'full_duplex',
      duplex_route: 'minicpmo_native_video',
      proactive_prime: true
    });
    if (session.closed || !this.data.duplexActive) return false;
    return true;
  },

  async startNativeVideoDuplexSession(reason) {
    if (this.data.duplexNativeSessionActive && this.duplexNativeSession && !this.duplexNativeSession.closed) {
      return true;
    }
    if (this.data.recorderProbeActive) {
      throw new Error('recorder_busy');
    }
    const recorder = wx.media && wx.media.getRecorderManager ? wx.media.getRecorderManager() : undefined;
    const camera = wx.media && wx.media.createCameraContext ? wx.media.createCameraContext() : undefined;
    if (!recorder) throw new Error('recorder_unavailable');
    if (!camera) throw new Error('camera_unavailable');
    const caps = this.recorderCapabilities(recorder);
    const scenario = this.data.duplexScenario || 'duplex_interaction';
    const sourceEventId = this.data.duplexVisualEventId || this.data.latestEventId || '';
    await this.postEvent('aiui.recorder_capability', 'audio', {
      ...caps,
      scenario,
      route: 'native_video_stream'
    }, {
      recorder_route: 'aiui_native_video',
      interaction_mode: 'full_duplex'
    });
    if (!(caps.recorder_start && caps.recorder_stop && caps.recorder_on_frame && caps.recorder_on_error)) {
      throw new Error('recorder_api_incomplete');
    }
    const createSocket = wx.createSocket || wx.connectSocket;
    if (!createSocket) throw new Error('socket_unavailable');

    this.setData({ recorderProbeActive: true, duplexNativeSessionActive: true, taskLine: 'native open' });
    return await new Promise((resolve, reject) => {
      let startupSettled = false;
      let socketTask = null;
      let socketOpened = false;
      let recorderStarted = false;
      const session = {
        closed: false,
        frameTimerId: 0,
        latestFrameBase64: '',
        responseText: '',
        audioDeltas: 0,
        listenDeltas: 0,
        proactivePrimeSent: false,
        startupInProgress: false
      };

      const settleStartup = (error, value) => {
        if (startupSettled) return;
        startupSettled = true;
        if (error) {
          reject(error);
          return;
        }
        resolve(Boolean(value));
      };
      const sendJson = (payload) => {
        if (!socketTask || !methodExists(socketTask, 'send')) throw new Error('socket_send_unavailable');
        socketTask.send(JSON.stringify(payload));
      };
      const closeSocket = () => {
        if (socketTask && methodExists(socketTask, 'close')) {
          try {
            socketTask.close();
          } catch (error) {
            // Close is best effort.
          }
        }
      };
      const cleanup = (stopReason, notifyRelay) => {
        if (session.closed) return;
        session.closed = true;
        if (session.frameTimerId) {
          clearInterval(session.frameTimerId);
          session.frameTimerId = 0;
        }
        if (notifyRelay) {
          try {
            sendJson({ type: 'session.close', reason: reasonText(stopReason, 'aiui_stop') });
          } catch (error) {
            // Best effort; socket may already be unavailable.
          }
        }
        try {
          const stopped = recorder.stop();
          if (stopped && typeof stopped.catch === 'function') {
            stopped.catch(() => {});
          }
        } catch (error) {
          // Recorder may already be stopped.
        }
        if (notifyRelay) {
          setTimeout(closeSocket, 80);
        } else {
          closeSocket();
        }
        if (this.duplexNativeSession === session) {
          this.duplexNativeSession = null;
        }
        this.setData({ recorderProbeActive: false, duplexNativeSessionActive: false });
      };
      const failSession = (error) => {
        cleanup('native_video_error', false);
        this.postEvent('aiui.native_video_stream_failed', 'audio', {
          error: error.message,
          scenario
        }, {
          recorder_route: 'aiui_native_video',
          interaction_mode: 'full_duplex',
          fallback: 'streaming_audio'
        });
        if (!startupSettled) {
          settleStartup(error);
          return;
        }
        if (this.data.duplexActive) {
          this.scheduleNextDuplexTurn('native_video_error', 1000);
        }
      };
      const postListenBoundary = () => {
        const answer = compactText(session.responseText || '', 100);
        const audioDeltas = session.audioDeltas;
        if (!answer && !audioDeltas) return;
        this.postEvent('aiui.native_video_stream_result', 'audio', {
          ok: true,
          status: 'listen',
          answer,
          audio_deltas: audioDeltas,
          listen_deltas: session.listenDeltas,
          scenario,
          native_session_active: !session.closed
        }, {
          recorder_route: 'aiui_native_video',
          interaction_mode: 'full_duplex',
          duplex_route: 'minicpmo_native_video'
        });
        if (answer) {
          this.speak(answer);
        }
        session.responseText = '';
        session.audioDeltas = 0;
      };
      const refreshFrame = async () => {
        if (session.closed) return;
        try {
          const photo = await camera.takePhoto({ quality: 'normal' });
          session.latestFrameBase64 = wx.arrayBufferToBase64(photo.data);
        } catch (error) {
          // Keep audio flowing if camera capture is temporarily gated.
        }
      };
      const startRecorder = async () => {
        if (recorderStarted || session.closed || !this.data.duplexActive) return false;
        await refreshFrame();
        if (recorderStarted || session.closed || !this.data.duplexActive) return false;
        recorderStarted = true;
        session.frameTimerId = setInterval(refreshFrame, NATIVE_VIDEO_FRAME_INTERVAL_MS);
        try {
          const started = recorder.start({});
          if (started && typeof started.then === 'function') {
            started.catch(error => failSession(error));
          }
          this.setData({ taskLine: 'native live', promptText: 'listening' });
          return true;
        } catch (error) {
          failSession(error);
          return false;
        }
      };
      const parseSocketPayload = (message) => {
        const raw = typeof message === 'string'
          ? message
          : message && typeof message.data === 'string'
            ? message.data
            : '';
        if (raw) {
          try {
            return JSON.parse(raw);
          } catch (error) {
            return {};
          }
        }
        if (message && typeof message.data === 'object' && message.data) return message.data;
        return {};
      };

      session.cleanup = cleanup;
      this.duplexNativeSession = session;

      if (methodExists(recorder, 'onHeader')) {
        recorder.onHeader(() => {});
      }
      recorder.onFrameRecorded(event => {
        if (!socketOpened || session.closed || !event || !event.frameBuffer) return;
        const audio = pcm16ArrayBufferToFloat32Base64(event.frameBuffer);
        if (!audio) return;
        try {
          sendJson({
            type: 'input.append',
            input: {
              audio,
              video_frames: session.latestFrameBase64 ? [session.latestFrameBase64] : [],
              force_listen: false,
              max_slice_nums: 1
            }
          });
        } catch (error) {
          failSession(error);
        }
      });
      recorder.onError(event => {
        failSession(new Error(event && event.errMsg ? event.errMsg : 'recorder_error'));
      });
      if (methodExists(recorder, 'onStop')) {
        recorder.onStop(() => {});
      }

      const socketPath = '/api/duplex/native-video-stream?device_id=' + encodeURIComponent(DEVICE_ID) +
        '&scenario=' + encodeURIComponent(scenario) +
        '&state_context=Task' +
        (sourceEventId ? '&source_event_id=' + encodeURIComponent(sourceEventId) : '');
      try {
        socketTask = createSocket({
          url: relayWebSocketUrl(this.data.relayUrl, socketPath),
          method: 'GET'
        });
      } catch (error) {
        failSession(error);
        return;
      }
      if (!socketTask || !methodExists(socketTask, 'onOpen') || !methodExists(socketTask, 'onMessage')) {
        failSession(new Error('socket_api_incomplete'));
        return;
      }
      socketTask.onOpen(() => {
        socketOpened = true;
        try {
          sendJson({
            type: 'session.start',
            device_id: DEVICE_ID,
            scenario,
            state_context: 'Task',
            source_event_id: sourceEventId,
            visual_context_event_id: this.data.duplexVisualEventId || '',
            prompt: this.data.duplexPrompt || '',
            reason: reasonText(reason, 'native_video_duplex_session')
          });
        } catch (error) {
          failSession(error);
        }
      });
      socketTask.onMessage(message => {
        const payload = parseSocketPayload(message);
        if (payload.type === 'duplex.session.ready') {
          this.setData({ taskLine: 'native ready' });
          return;
        }
        if (payload.type === 'duplex.session.started') {
          if (session.startupInProgress || recorderStarted || session.closed) return;
          session.startupInProgress = true;
          (async () => {
            try {
              if ((this.data.duplexCommandPayload || {}).proactive_prime !== false) {
                try {
                  await this.sendNativeVideoProactivePrime(session, sendJson, refreshFrame);
                } catch (error) {
                  this.postEvent('aiui.native_video_proactive_prime_failed', 'audio', {
                    error: error.message,
                    scenario
                  }, {
                    recorder_route: 'aiui_native_video',
                    interaction_mode: 'full_duplex',
                    duplex_route: 'minicpmo_native_video',
                    proactive_prime: true
                  });
                }
              }
              const recorderStartedNow = await startRecorder();
              if (!recorderStartedNow) {
                settleStartup(null, false);
                return;
              }
              if (session.closed || !this.data.duplexActive) {
                settleStartup(null, false);
                return;
              }
              await this.postEvent('aiui.native_video_stream_result', 'audio', {
                ok: true,
                status: 'started',
                scenario,
                native_session_active: true
              }, {
                recorder_route: 'aiui_native_video',
                interaction_mode: 'full_duplex',
                duplex_route: 'minicpmo_native_video'
              });
              if (session.closed || !this.data.duplexActive) {
                settleStartup(null, false);
                return;
              }
              settleStartup(null, true);
            } catch (error) {
              failSession(error);
            } finally {
              session.startupInProgress = false;
            }
          })().catch(error => failSession(error));
          return;
        }
        if (payload.type === 'response.output.delta') {
          if (payload.kind === 'text') {
            session.responseText += payload.text || '';
            this.setData({ taskLine: 'native text', promptText: compactText(session.responseText, 80) });
          } else if (payload.kind === 'audio') {
            session.audioDeltas += 1;
            this.setData({ taskLine: 'native audio' });
          } else if (payload.kind === 'listen') {
            session.listenDeltas += 1;
            this.setData({ taskLine: 'native listen' });
            postListenBoundary();
          }
          return;
        }
        if (payload.type === 'duplex.error' || payload.type === 'error') {
          failSession(new Error(payload.error || 'native_video_stream_error'));
        }
      });
      if (methodExists(socketTask, 'onError')) {
        socketTask.onError(event => failSession(new Error(event && event.errMsg ? event.errMsg : 'socket_error')));
      }
      if (methodExists(socketTask, 'onClose')) {
        socketTask.onClose(() => {
          if (!session.closed) {
            failSession(new Error('socket_closed'));
          }
        });
      }
    });
  },

  stopNativeVideoDuplexSession(reason) {
    const session = this.duplexNativeSession;
    if (!session) {
      this.setData({ recorderProbeActive: false, duplexNativeSessionActive: false });
      return;
    }
    if (typeof session.cleanup === 'function') {
      session.cleanup(reasonText(reason, 'aiui_stop'), true);
    }
    this.duplexNativeSession = null;
  },

  async recordAndCallRealtimeAudio(reason) {
    if ((wx.createSocket || wx.connectSocket) && (
      this.data.duplexRuntimeRoute === 'native_video_stream' ||
      this.data.duplexRuntimeRoute === 'streaming_audio'
    )) {
      try {
        return await this.recordAndCallRealtimeStreamAudio(reason);
      } catch (error) {
        await this.postEvent('aiui.duplex_stream_failed', 'audio', {
          error: error.message,
          scenario: this.data.duplexScenario || 'duplex_interaction'
        }, {
          recorder_route: 'aiui_stream',
          interaction_mode: 'full_duplex',
          fallback: 'duplex_turn'
        });
        this.setData({ taskLine: 'turn fallback' });
      }
    }
    return await this.recordAndCallRealtimeTurnAudio(reason);
  },

  async recordAndCallRealtimeStreamAudio(reason) {
    if (this.data.recorderProbeActive) {
      throw new Error('recorder_busy');
    }
    const recorder = wx.media && wx.media.getRecorderManager ? wx.media.getRecorderManager() : undefined;
    if (!recorder) {
      throw new Error('recorder_unavailable');
    }
    const caps = this.recorderCapabilities(recorder);
    const scenario = this.data.duplexScenario || 'duplex_interaction';
    const visualEventId = this.data.duplexVisualEventId || '';
    await this.postEvent('aiui.recorder_capability', 'audio', {
      ...caps,
      scenario,
      route: 'realtime_stream'
    }, {
      recorder_route: 'aiui_stream',
      interaction_mode: 'full_duplex'
    });
    if (!(caps.recorder_start && caps.recorder_stop && caps.recorder_on_header && caps.recorder_on_frame && caps.recorder_on_stop && caps.recorder_on_error)) {
      throw new Error('recorder_api_incomplete');
    }
    const sourceEventId = visualEventId || '';
    const socketPath = '/api/duplex/realtime-stream?device_id=' + encodeURIComponent(DEVICE_ID) +
      '&scenario=' + encodeURIComponent(scenario) +
      '&state_context=Task' +
      (sourceEventId ? '&source_event_id=' + encodeURIComponent(sourceEventId) : '') +
      (visualEventId ? '&visual_context_event_id=' + encodeURIComponent(visualEventId) : '');
    const createSocket = wx.createSocket || wx.connectSocket;
    if (!createSocket) {
      throw new Error('socket_unavailable');
    }
    this.setData({ recorderProbeActive: true, taskLine: 'stream' });
    return await new Promise((resolve, reject) => {
      let settled = false;
      let stopTimer = null;
      let forceTimer = null;
      let socketOpened = false;
      let recorderStarted = false;
      let headerFormat = '';
      let durationSeconds = 2.2;
      let socketTask = null;

      const safeClose = () => {
        if (socketTask && methodExists(socketTask, 'close')) {
          try {
            socketTask.close();
          } catch (error) {
            // Close is best-effort; the relay can expire the session.
          }
        }
      };

      const finish = (error, result) => {
        if (settled) return;
        settled = true;
        if (stopTimer) clearTimeout(stopTimer);
        if (forceTimer) clearTimeout(forceTimer);
        this.setData({ recorderProbeActive: false });
        if (error) {
          safeClose();
          reject(error);
          return;
        }
        safeClose();
        resolve(result);
      };

      const sendJson = (payload) => {
        if (!socketTask || !methodExists(socketTask, 'send')) {
          throw new Error('socket_send_unavailable');
        }
        socketTask.send(JSON.stringify(payload));
      };

      const startRecorder = () => {
        if (recorderStarted) return;
        recorderStarted = true;
        try {
          const started = recorder.start({});
          if (started && typeof started.then === 'function') {
            started.catch(error => finish(error));
          }
          stopTimer = setTimeout(() => {
            try {
              sendJson({
                type: 'audio.commit',
                filename: 'aiui_stream_' + Date.now() + '.wav',
                duration_seconds: durationSeconds,
                prompt: this.data.duplexPrompt || '用户正在通过 Rokid 眼镜和器灵进行全双工交流。请根据音频内容用一句中文回应。',
                scenario,
                state_context: 'Task',
                device_id: DEVICE_ID,
                source_event_id: sourceEventId,
                visual_context_event_id: visualEventId,
                reason: reasonText(reason, 'duplex_stream_turn'),
                timeout_seconds: 40,
                max_messages: 90,
                audio_chunk_seconds: 0.5,
                audio_tail_silence_seconds: 0.8,
                header_format: headerFormat
              });
              const stopped = recorder.stop();
              if (stopped && typeof stopped.catch === 'function') {
                stopped.catch(error => finish(error));
              }
            } catch (error) {
              finish(error);
            }
          }, 2200);
          forceTimer = setTimeout(() => {
            finish(new Error('duplex_stream_timeout'));
          }, 9000);
        } catch (error) {
          finish(error);
        }
      };

      recorder.onHeader((format, buffer) => {
        headerFormat = String(format || '');
        if (!buffer || !socketOpened) return;
        try {
          sendJson({
            type: 'audio.header',
            content_base64: wx.arrayBufferToBase64(buffer),
            format: headerFormat
          });
        } catch (error) {
          finish(error);
        }
      });
      recorder.onFrameRecorded(event => {
        if (!event || !event.frameBuffer || !socketOpened) return;
        try {
          sendJson({
            type: 'audio.frame',
            content_base64: wx.arrayBufferToBase64(event.frameBuffer)
          });
        } catch (error) {
          finish(error);
        }
      });
      recorder.onError(event => {
        finish(new Error(event && event.errMsg ? event.errMsg : 'recorder_error'));
      });
      if (methodExists(recorder, 'onStart')) {
        recorder.onStart(() => {
          this.setData({ taskLine: 'stream live' });
        });
      }
      recorder.onStop(event => {
        if (event && event.duration) {
          durationSeconds = Number(event.duration) || durationSeconds;
        }
      });

      try {
        socketTask = createSocket({
          url: relayWebSocketUrl(this.data.relayUrl, socketPath),
          method: 'GET'
        });
      } catch (error) {
        finish(error);
        return;
      }
      if (!socketTask || !methodExists(socketTask, 'onOpen') || !methodExists(socketTask, 'onMessage')) {
        finish(new Error('socket_api_incomplete'));
        return;
      }
      socketTask.onOpen(() => {
        socketOpened = true;
        try {
          sendJson({
            type: 'session.start',
            device_id: DEVICE_ID,
            scenario,
            state_context: 'Task',
            source_event_id: sourceEventId,
            visual_context_event_id: visualEventId,
            prompt: this.data.duplexPrompt || '',
            reason: reasonText(reason, 'duplex_stream_turn')
          });
          startRecorder();
        } catch (error) {
          finish(error);
        }
      });
      socketTask.onMessage(async message => {
        let payload = {};
        const raw = typeof message === 'string'
          ? message
          : message && typeof message.data === 'string'
            ? message.data
            : '';
        if (raw) {
          try {
            payload = JSON.parse(raw);
          } catch (error) {
            payload = {};
          }
        } else if (message && typeof message.data === 'object' && message.data) {
          payload = message.data;
        }
        if (payload.type === 'duplex.answer') {
          await this.postEvent('aiui.duplex_stream_result', 'audio', {
            ok: Boolean(payload.ok),
            status: payload.status || '',
            event_id: payload.event_id || '',
            answer: payload.answer || payload.response_text || '',
            input_audio_quality: payload.input_audio_quality || '',
            output_audio_url: payload.output_audio_url || '',
            scenario,
            header_format: headerFormat
          }, {
            recorder_route: 'aiui_stream',
            interaction_mode: 'full_duplex',
            audio_probe: 'minicpmo',
            duplex_route: 'relay_websocket'
          });
          finish(null, {
            session: true,
            audio: true,
            stream: true,
            answer: payload.answer || payload.response_text || ''
          });
        } else if (payload.type === 'duplex.error') {
          finish(new Error(payload.error || 'duplex_stream_error'));
        }
      });
      if (methodExists(socketTask, 'onError')) {
        socketTask.onError(event => {
          finish(new Error(event && event.errMsg ? event.errMsg : 'socket_error'));
        });
      }
      if (methodExists(socketTask, 'onClose')) {
        socketTask.onClose(() => {
          if (!settled) {
            finish(new Error('socket_closed'));
          }
        });
      }
    });
  },

  async recordAndCallRealtimeTurnAudio(reason) {
    if (this.data.recorderProbeActive) {
      throw new Error('recorder_busy');
    }
    const recorder = wx.media && wx.media.getRecorderManager ? wx.media.getRecorderManager() : undefined;
    if (!recorder) {
      throw new Error('recorder_unavailable');
    }
    const caps = this.recorderCapabilities(recorder);
    const scenario = this.data.duplexScenario || 'duplex_interaction';
    const visualEventId = this.data.duplexVisualEventId || '';
    await this.postEvent('aiui.recorder_capability', 'audio', {
      ...caps,
      scenario
    }, {
      recorder_route: 'aiui',
      interaction_mode: 'full_duplex'
    });
    if (!(caps.recorder_start && caps.recorder_stop && caps.recorder_on_header && caps.recorder_on_frame && caps.recorder_on_stop && caps.recorder_on_error)) {
      throw new Error('recorder_api_incomplete');
    }
    this.setData({ recorderProbeActive: true, taskLine: 'rec' });
    return await new Promise((resolve, reject) => {
      let settled = false;
      let stopTimer = null;
      let forceTimer = null;
      let headerFormat = '';
      const chunks = [];

      const finish = async (error) => {
        if (settled) return;
        settled = true;
        if (stopTimer) clearTimeout(stopTimer);
        if (forceTimer) clearTimeout(forceTimer);
        this.setData({ recorderProbeActive: false });
        if (error) {
          reject(error);
          return;
        }
        try {
          const audioBuffer = concatBuffers(chunks);
          if (!isWavBuffer(audioBuffer)) {
            throw new Error('recorder_no_wav_header');
          }
          const result = await jsonRequest(this.data.relayUrl, '/api/duplex/turn', 'POST', {
            input_type: 'audio',
            filename: 'aiui_duplex_' + Date.now() + '.wav',
            content_base64: wx.arrayBufferToBase64(audioBuffer),
            duration_seconds: 2.2,
            prompt: this.data.duplexPrompt || '用户正在通过 Rokid 眼镜和器灵进行全双工交流。请根据音频内容用一句中文回应。',
            timeout_seconds: 40,
            max_messages: 90,
            audio_chunk_seconds: 0.5,
            audio_tail_silence_seconds: 0.8,
            device_id: DEVICE_ID,
            source: 'aiui.recorder_probe',
            scenario,
            state_context: 'Task',
            source_event_id: visualEventId || '',
            visual_context_event_id: visualEventId,
            context_event_ids: visualEventId ? [visualEventId] : [],
            tags: {
              recorder_route: 'aiui',
              interaction_mode: 'full_duplex',
              audio_probe: 'minicpmo',
              duplex_turn: true,
              multimodal_context: Boolean(visualEventId),
              visual_context_event_id: visualEventId,
              use_latest_visual_context: true,
              capture_trigger: reasonText(reason, 'duplex_turn')
            }
          });
          await this.postEvent('aiui.recorder_probe_result', 'audio', {
            ok: Boolean(result && result.ok),
            status: result && result.status,
            event_id: result && result.event_id,
            input_audio_quality: result && result.input_audio_quality,
            uploaded_audio_seconds: result && result.uploaded_audio_seconds,
            uploaded_audio_rms: result && result.uploaded_audio_rms,
            output_audio_url: result && result.output_audio_url,
            header_format: headerFormat,
            scenario
          }, {
            recorder_route: 'aiui',
            interaction_mode: 'full_duplex',
            audio_probe: 'minicpmo'
          });
          resolve({
            session: false,
            audio: true,
            answer: result && result.response_text ? result.response_text : ''
          });
        } catch (sendError) {
          reject(sendError);
        }
      };

      recorder.onHeader((format, buffer) => {
        headerFormat = String(format || '');
        if (buffer) chunks.push(buffer);
      });
      recorder.onFrameRecorded(event => {
        if (event && event.frameBuffer) chunks.push(event.frameBuffer);
      });
      recorder.onError(event => {
        finish(new Error(event && event.errMsg ? event.errMsg : 'recorder_error'));
      });
      if (methodExists(recorder, 'onStart')) {
        recorder.onStart(() => {
          this.setData({ taskLine: 'rec live' });
        });
      }
      recorder.onStop(event => {
        if (event && event.tempFilePath) {
          headerFormat = headerFormat || 'tempFilePath';
        }
        finish(null);
      });

      try {
        const started = recorder.start({});
        if (started && typeof started.then === 'function') {
          started.catch(error => finish(error));
        }
        stopTimer = setTimeout(() => {
          try {
            const stopped = recorder.stop();
            if (stopped && typeof stopped.catch === 'function') {
              stopped.catch(error => finish(error));
            }
          } catch (error) {
            finish(error);
          }
        }, 2200);
        forceTimer = setTimeout(() => {
          finish(new Error('recorder_timeout'));
        }, 7000);
      } catch (error) {
        finish(error);
      }
    });
  },

  async callRealtimeSession(userText) {
    const contextualPrompt = this.data.duplexPrompt
      ? this.data.duplexPrompt + '\n用户刚才说：' + userText
      : userText;
    const scenario = this.data.duplexScenario || 'duplex_interaction';
    try {
      const result = await jsonRequest(this.data.relayUrl, '/api/duplex/turn', 'POST', {
        input_type: 'text',
        user_text: userText,
        prompt: this.data.duplexPrompt || '',
        device_id: DEVICE_ID,
        source: 'aiui.duplex_turn',
        scenario,
        state_context: 'Task',
        source_event_id: this.data.duplexVisualEventId || '',
        visual_context_event_id: this.data.duplexVisualEventId || '',
        context_event_ids: this.data.duplexVisualEventId ? [this.data.duplexVisualEventId] : [],
        reason: 'asr_text_fallback',
        timeout_seconds: 30,
        max_messages_per_turn: 60,
        tags: {
          recorder_route: 'aiui_asr',
          interaction_mode: 'full_duplex',
          duplex_turn: true,
          multimodal_context: Boolean(this.data.duplexVisualEventId),
          visual_context_event_id: this.data.duplexVisualEventId || '',
          use_latest_visual_context: true
        }
      });
      return {
        session: true,
        answer: result && result.answer ? result.answer : result.response_text || ''
      };
    } catch (duplexError) {
      try {
        const result = await jsonRequest(this.data.relayUrl, '/api/models/minicpmo/realtime-session-smoke', 'POST', {
          mode: 'chat',
          prompts: [contextualPrompt],
          timeout_seconds: 30,
          max_messages_per_turn: 60
        });
        const turns = result && result.turns ? result.turns : [];
        const latestTurn = turns.length ? turns[turns.length - 1] : null;
        return {
          session: true,
          answer: latestTurn && latestTurn.response_text ? latestTurn.response_text : ''
        };
      } catch (error) {
        const fallback = await jsonRequest(this.data.relayUrl, '/api/models/minicpmo/realtime-smoke', 'POST', {
          mode: 'chat',
          prompt: contextualPrompt,
          timeout_seconds: 30,
          max_messages: 40
        });
        return {
          session: false,
          answer: fallback && fallback.response_text ? fallback.response_text : ''
        };
      }
    }
  },

  async recognizeOnce() {
    if (wx.speech && wx.speech.startRecognition) {
      const text = wx.speech.startRecognition();
      if (text && typeof text.then === 'function') {
        return compactText(await text, 240);
      }
      return compactText(text, 240);
    }
    return await new Promise((resolve, reject) => {
      const SpeechRecognitionCtor = optionalGlobal('SpeechRecognition');
      if (!SpeechRecognitionCtor) {
        reject(new Error('asr_unavailable'));
        return;
      }
      const recognition = new SpeechRecognitionCtor();
      recognition.lang = 'zh-CN';
      recognition.continuous = false;
      recognition.interimResults = false;
      recognition.maxAlternatives = 1;
      recognition.onresult = event => {
        const best = event.results && event.results[0] && event.results[0][0];
        resolve(best && best.transcript ? best.transcript : '');
      };
      recognition.onerror = event => {
        reject(new Error(event && event.message ? event.message : event.error || 'asr_failed'));
      };
      recognition.start();
    });
  },

  async stopFullDuplex(reason) {
    const stopReason = reasonText(reason, 'aiui_stop');
    const scenario = this.data.duplexScenario || 'duplex_interaction';
    if (!this.data.duplexActive) {
      await this.rejectPaperWiki(stopReason);
      return;
    }
    this.clearDuplexTurnTimer();
    this.stopNativeVideoDuplexSession(stopReason);
    this.setData({
      duplexActive: false,
      duplexTurnActive: false,
      duplexNativeSessionActive: false,
      duplexScenario: 'duplex_interaction',
      duplexPrompt: '',
      duplexPaperTitle: '',
      duplexVisualEventId: '',
      duplexCommandPayload: {},
      mode: 'Watch',
      taskLine: 'idle',
      promptTitle: 'DUPLEX',
      promptText: 'stopped',
      ...statePatch('watch')
    });
    await this.patchInteraction('off', stopReason, scenario);
    this.postEvent('aiui.full_duplex', 'interaction', {
      state: 'stopped',
      reason: stopReason,
      scenario
    }, { interaction_mode: 'off' });
  },

  async patchInteraction(mode, reason, scenario) {
    try {
      await jsonRequest(this.data.relayUrl, '/api/interaction', 'PATCH', {
        interaction_mode: mode,
        scenario: scenario || 'duplex_interaction',
        reason: reason || 'aiui',
        mic_chunk_ms: 3000,
        max_turns: DUPLEX_TURN_LIMIT
      });
    } catch (error) {
      this.setData({ relayState: 'relay err' });
    }
  },

  speak(text) {
    const message = compactText(text, 120);
    try {
      if (wx.speech && wx.speech.playTTS) {
        wx.speech.playTTS(message);
        return;
      }
    } catch (error) {
      // Fall through to Web Speech.
    }
    try {
      const SpeechSynthesisUtteranceCtor = optionalGlobal('SpeechSynthesisUtterance');
      const speechSynthesisApi = optionalGlobal('speechSynthesis');
      if (!SpeechSynthesisUtteranceCtor || !speechSynthesisApi) {
        throw new Error('tts_unavailable');
      }
      const utterance = new SpeechSynthesisUtteranceCtor(message);
      utterance.lang = 'zh-CN';
      utterance.rate = 1.0;
      utterance.pitch = 1.0;
      utterance.volume = 1.0;
      speechSynthesisApi.speak(utterance);
    } catch (error) {
      this.setData({ taskLine: 'tts --' });
    }
  },

  clearPrompt() {
    this.clearPromptTimer();
    this.setData({ promptTitle: '', promptText: '' });
  }
}
</script>

<page>
  <view class="hud">
    <view class="center" bindtap="clearPrompt">
      <view class="prompt" ink:if="{{ promptTitle || promptText }}">
        <view class="prompt-symbol">
          <view class="{{ stateIconClass }}">
            <view class="status-mark-inner"></view>
          </view>
        </view>
        <text class="prompt-body">{{ promptText }}</text>
      </view>
    </view>
  </view>
</page>

<style>
.hud {
  width: 480px;
  height: 240px;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  padding: 0;
  background-color: #000000;
  color: var(--color-text-primary);
  font-family: Arial, sans-serif;
}

.center {
  width: 480px;
  height: 240px;
  box-sizing: border-box;
  display: flex;
  flex-direction: row;
  align-items: flex-end;
  justify-content: flex-start;
  padding: 0 0 30px 28px;
}

.prompt {
  width: 392px;
  min-height: 34px;
  box-sizing: border-box;
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 12px;
  padding: 4px 0;
  background-color: transparent;
}

.prompt-symbol {
  width: 30px;
  height: 30px;
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: center;
}

.prompt-body {
  flex-grow: 1;
  font-size: 15px;
  line-height: 20px;
  text-align: left;
  color: var(--color-primary);
  word-break: break-word;
}

.status-mark {
  width: 22px;
  height: 22px;
  box-sizing: border-box;
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: center;
  border: 2px solid var(--color-primary);
  color: transparent;
  background-color: transparent;
  font-size: 0;
  line-height: 0;
}

.status-mark-inner {
  width: 8px;
  height: 8px;
  box-sizing: border-box;
  border: 1px solid var(--color-primary);
  background-color: transparent;
}

.state-idle {
  width: 16px;
  height: 16px;
  border-radius: 2px;
  border-width: 1px;
}

.state-idle .status-mark-inner {
  width: 0;
  height: 0;
  border-width: 0;
}

.state-watch {
  border-radius: 22px;
}

.state-watch .status-mark-inner {
  width: 8px;
  height: 8px;
  border-radius: 8px;
}

.state-duplex {
  border-radius: 22px;
  border-width: 3px;
}

.state-duplex .status-mark-inner {
  width: 10px;
  height: 14px;
  border-width: 0 2px;
}

.state-paper {
  border-radius: 2px;
}

.state-paper .status-mark-inner {
  width: 12px;
  height: 2px;
  border-width: 0;
  background-color: var(--color-primary);
}

.state-error {
  width: 18px;
  height: 18px;
  border-radius: 2px;
  transform: rotate(45deg);
}

.state-error .status-mark-inner {
  width: 5px;
  height: 5px;
  border-width: 0;
  background-color: var(--color-primary);
}
</style>
