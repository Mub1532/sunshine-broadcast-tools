# Sunshine Broadcast Tools

Scripts to turn [Sunshine](https://github.com/LizardByte/Sunshine) into a low-latency broadcasting solution, allowing you to stream your screen, webcam and microphone over a local network to official [Moonlight](https://moonlight-stream.org/) clients.

- Supports a movable and resizable webcam overlay, with controls to end the stream directly from the host.
- Support the hosts microphone, which is not supported in offical Sunshine/Moonlight clients, normally requires forked versions, which are not in official app stores.
- No modifications to Sunshine or Moonlight are required.

## Why Sunshine?

- **Blazing fast** - practically no delay between the host and the screen you're streaming to.
- **No buffering** - on weaker networks it doesnt pause the stream, it can lower the quality and etc.
- **Customisable** - resolution, frame rate and bitrate can all be tuned, so it works on low-quality networks too.
- **Runs basically anywhere** - Moonlight is available on basically any device, and even in the official app stores for example, from PC, new consoles, Apple TV, Google/Android TV and even with sideloading, can be added to obscure devices like old consoles, LG webOS or Samsung Tizen TV's etc.

## Who is this for?

Anyone who wants to show a computer's screen, face and voice on another screen over the local network, without delay, and without the presenter needing any technical knowledge. For example:

- Classes, talks or lessons streamed to another room
- Presentations or meetings shown on a TV elsewhere in the building
- Any setup where the presenter should only need to click **Start** and **End**

## Modes

- **Casting** - shows the screen and the computer's sound on the TV. No camera or microphone.
- **Broadcast** - shows the screen, a webcam overlay and the microphone on the TV, while the computer's own sound keeps playing in the room.

## Requirements

- **[Sunshine](https://github.com/LizardByte/Sunshine)** - Streaming server used to broadcast to Moonlight clients. Installed automatically if missing.
- **[Moonlight](https://moonlight-stream.org/)** - Client used on the viewing device to receive and view the stream.

### Extra requirements for broadcast

Setup downloads and installs these automatically when broadcast is chosen:

- **[VB-Audio Virtual Cable](https://vb-audio.com/Cable/)** - Virtual audio device used for routing microphone audio into the stream. Needs a restart after installing.
- **[svcl](https://www.nirsoft.net/utils/sound_volume_command_line.html)** (SoundVolumeCommandLine by NirSoft) - Command-line tool for switching audio devices and routing the microphone.
- **[libmpv](https://github.com/shinchiro/mpv-winbuild-cmake)** - Used to display the webcam overlay.

### Moonlight settings to change

- **Broadcast:** host audio must **not be muted**: untick **Mute host PC speakers while streaming** (PC), or turn on **Play audio on PC** (Android/Google TV). Devices with it muted are refused, with a popup on the computer saying how to fix it.
- **Casting:** either works. Muted plays the sound only on the TV, unmuted plays it on both.

# Installation

## Windows

Open **PowerShell as administrator** (not CMD) and run:

```powershell
irm https://raw.githubusercontent.com/Mub1532/sunshine-broadcast-tools/main/windows/install.ps1 | iex
```

This installs everything to `C:\ProgramData\sunshine-broadcast-tools` and opens Setup.

In Setup, choose a mode:

- **Setup for casting** - pick the options, then click **Save / Apply to Sunshine**.
- **Setup for broadcast** - installs the extra requirements if needed, then pick the speakers, microphone, camera and options, and click **Save / Apply to Sunshine**.

The options can:

- set a default Sunshine login (admin / admin) if none is set
- remove the other Sunshine apps, so only **Desktop Broadcast** (broadcast) or **Desktop** (casting) shows
- stop the viewer controlling the PC (keyboard, mouse and controller)
- set the gamepad driver to ViGEmBus
- stop Sunshine installing the Steam audio drivers

Then pair Moonlight with Sunshine using the PIN.

To change mode or settings later, open **Sunshine Broadcast Setup** in `C:\ProgramData\sunshine-broadcast-tools`.

## Updates

When an update is available, **Start Sunshine Stream** asks to update first. Click **Update Now** or **Later**.

If an update causes problems, open Setup and click **Undo last update** to go back to the previous version.

## Linux

WIP

## Usage

**Presenter:** double-click **Start Sunshine Stream** → wait for the message → present → click **End Stream** on the webcam overlay (broadcast), or click the red record icon in the system tray → **End Stream** (both modes).

**Viewer:** open Moonlight → select the host → **Desktop Broadcast** (broadcast) or **Desktop** (casting).

The stream also ends by itself if the computer is put to sleep, the lid is closed or it's shut down. If the viewer disconnects, the presenter gets a popup saying so.

The popup messages can be changed in `messageConfig.json`.
