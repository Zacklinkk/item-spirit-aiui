# Agent Manifest

## Identity

- **Name**: Item Spirit AIUI
- **Version**: 0.1.0
- **Description**: AIUI glasses client for proactive paper reading and full-duplex interaction.
- **Author**: linzekun

## Capabilities

- **Permissions**:
  - camera
  - microphone
  - network
  - audio
  - sensor
  - storage

- **Skills**:
  - paper-companion
  - duplex-interaction
  - relay-event-upload

## Runtime Contract

- The glasses client owns foreground interaction, HUD text, wake/gesture routing, ASR/TTS and IMU tags.
- Relay owns OCR, MiniCPM-V, MiniCPM-o Realtime, Wiki memory, task routing and audit.
- Camera and recorder calls must be treated as interactive-gated until real device tests prove background behavior.

