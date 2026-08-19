# Codex Micro → Wispr Flow Bridge

A small native macOS helper that observes Codex Micro's private Layer-1 HID
protocol and turns a press of the wide Mic key into `Control+Option+Space`.
That shortcut toggles Wispr Flow's hands-free mode without switching hardware
layers.

The bridge opens the device non-exclusively. It does not reconfigure the
keyboard, write to it, or seize it from ChatGPT/Codex.

## Before running

1. In Wispr Flow, open **Settings → General → Shortcuts → Hands-free mode** and
   add `Control+Option+Space`.
2. In **ChatGPT/Codex → Settings → Codex Micro → Layout**, select the wide Mic
   key and assign it an unassigned/blank double-width keycap action. Otherwise,
   Codex push-to-talk and Wispr Flow will both respond to the same press.
3. Keep the Micro on Layer 1.

## Build and inspect

Requires macOS 13 or newer and Xcode Command Line Tools.

```sh
swift build
.build/debug/codex-micro-wispr-bridge --check-permissions
.build/debug/codex-micro-wispr-bridge --dry-run --verbose
```

Grant the executable both permissions when macOS opens System Settings:

- **Privacy & Security → Input Monitoring** to read report 6 from Codex Micro.
- **Privacy & Security → Accessibility** to post the Wispr shortcut.

With dry-run mode active, press the Mic key. The terminal should print a single
`Mic pressed` line even if both switches under the wide key actuate.

Run the bridge for real:

```sh
.build/debug/codex-micro-wispr-bridge
```

Press Mic once to start hands-free dictation and again to stop it.

## Install at login

Install the release binary and its LaunchAgent:

```sh
./scripts/install.sh
"$HOME/Library/Application Support/CodexMicroWisprBridge/codex-micro-wispr-bridge" --check-permissions
```

Approve the installed helper in both privacy panels. The LaunchAgent will retry
automatically after approval; if macOS asks you to quit the helper first, run
`launchctl kickstart -k gui/$(id -u)/com.roosh.codex-micro-wispr-bridge` when
you are done.

The installer places the executable and log under:

```text
~/Library/Application Support/CodexMicroWisprBridge/
```

## Diagnostics

```sh
# Decode reports but do not trigger Wispr
codex-micro-wispr-bridge --dry-run --verbose

# Verify synthetic shortcut delivery without pressing the Micro
codex-micro-wispr-bridge --trigger-once
```

The bridge matches VID `0x303A`, PID `0x8360`, filters vendor report ID `6`,
reassembles its newline-delimited JSON fragments, and recognizes Mic key IDs
`ACT10`, `ACT11`, and `ACT10_ACT11`. It triggers once per physical press and
coalesces the two switches under the wide key. It accepts both the compact
production envelope (`m`/`p`) and the expanded compatibility envelope
(`method`/`params`).

## Protocol status

The Codex Micro wire protocol is private and can change with firmware or
ChatGPT desktop updates. The implementation follows the currently observed
report framing:

- Report body byte 0: message type `2`
- Report body byte 1: JSON fragment length, at most 61 bytes
- Remaining bytes: a UTF-8 JSON fragment
- Mic messages: `v.oai.hid` with `act = 1` for press and `act = 0` for release

References:

- [Official Codex Micro documentation](https://learn.chatgpt.com/docs/features/codex-micro)
- [Unofficial protocol observations](https://github.com/ZyoungInc/codex-keyboard/blob/main/docs/TECHNICAL.md)

This project is independent and is not affiliated with or endorsed by OpenAI,
Work Louder, or Wispr Flow.
