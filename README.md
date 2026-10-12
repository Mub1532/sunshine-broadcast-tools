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

## Requirements

- **[Sunshine](https://github.com/LizardByte/Sunshine)** - Streaming server used to broadcast to Moonlight clients.
- **[Moonlight](https://moonlight-stream.org/)** - Client used to receive and view the stream.
- **[VLC Media Player](https://www.videolan.org/vlc/)** - Used to display the webcam overlay.
- **[svcl](https://www.nirsoft.net/utils/sound_volume_command_line.html)** (SoundVolumeCommandLine by NirSoft) - Command-line tool for switching audio devices and routing the microphone. Download the x64 zip and place `svcl.exe` in the same folder as the scripts.
- **[VB-Audio Virtual Cable](https://vb-audio.com/Cable/)** - Virtual audio device used for routing microphone audio into the stream. Run the installer as administrator, then restart.

### Sunshine settings to change

- **Input:** if you don't want the viewer to be able to control the host PC, disable **keyboard**, **mouse** and **gamepad/controller** inputs (and others if there are others) in the Input/Output section of Sunshine config.

### Moonlight settings to change

- Turn on **Play audio on host PC**, so sound still plays from the host's speakers.

## Installation

WIP

## Usage

**Presenter:** double-click **Start Stream** → wait for the message → present → click **End Stream** on the webcam overlay (or the **End Stream** shortcut).

**Viewer:** open Moonlight → select the host → **Broadcast Desktop**.
