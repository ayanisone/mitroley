# mitroley

A small Mac app for fitting sound effects and ambience to picture. Drop in a video, generate
sounds with ElevenLabs, and let the sound follow what the picture does: a track that follows the
scene picks up a cave's reverb the moment the scene becomes a cave.

## Build and run

Needs macOS 15 or later and the Xcode Command Line Tools (full Xcode is not required).

```bash
./build.sh
```

```bash
open build/mitroley.app
```

API keys go in Settings (⌘,) and are stored in a file only your account can read (`~/Library/Application Support/mitroley/keys.json`): ElevenLabs for generating sounds,
Anthropic for the built-in Claude panel.

## How it works

| Idea | What it is |
| --- | --- |
| Scene | A region of the timeline. Detected from cuts on import; split with ⌘B. |
| Space | What a place sounds like: reverb, echo, brightness, and how muffled or quiet direct sound gets there. |
| Track | Follows the scene, sits in one fixed space, or stays dry. Stereo bed or a spatial object with a room position. |
| Clip | A sound on a track, with several takes. Press 1–9 to switch takes while it plays. |
| Automation | Per-track lanes for volume, muffle, space amount and position. |
| Group | Tracks mixed together: one fader, mute and solo, and they fold away. Session › Group Tracks by Kind (⌘G). |
| Revised cut | File › Import Revised Cut (⇧⌘I) compares a new cut with the old one shot by shot and makes a new session where every sound has moved with its picture. Only new or longer shots are left to do. A/B/C in the transport bar switches between cuts on the same moment. |
| Footsteps | On a foley track: Mark Steps, press T on every footfall, Place. One recorded walk is cut into single steps and a different one lands on each mark. |
| Film's own sound | File › Use the Film's Own Sound: as one muted track, or split into stems with ElevenLabs. |

Scenes crossfade into each other over each scene's "Crossfade in" time: short for a hard cut,
a second or more when a character walks from one room into the next.

## Claude

Two ways in, both using the same commands (`Sources/Foley/Commands.swift`):

- **In the app**: the Claude panel (⌘K). Claude looks at frames of the video, reads the storyboard,
  writes scenes and spaces, and fits the clips. Every change can be undone.
- **From Claude Code**: mitroley is an MCP server. This folder's `.mcp.json` already registers it;
  elsewhere, use "Copy Setup Command" in the Claude panel. Claude Code can then combine mitroley with
  other tools, for example ranking takes by ear with an audio-analysis tool.

## Mixing

| Thing | What it is |
| --- | --- |
| Session format | 7.1.4, 5.1, binaural or stereo, chosen in the transport bar (new sessions take the default from Settings). It decides which speakers the panner and the Room window show and which export is offered first. Every other format can still be exported from it. On a Mac you always listen in two channels: binaurally for the spatial formats, plainly for stereo. |
| Panner | A top-down disc for each spatial track. Speakers light up with the signal they get, the lit arc on the rim shows how widely the sound is spread, and the glow grows as it is lifted. Shift-drag for fine moves, double-click to centre. |
| Master effects | Click the output meter for the rack. It starts empty, so the mix goes out untouched; add an effect when you need it, bypass it with its switch, remove it with ×. |
| Compressor, Limiter | Linked across every channel (one gain from the loudest channel, applied to all, so the image never moves and no channel clips), on the live output and in every export except stems. The limiter also holds the 5.1 and stereo fold-downs under its ceiling. |
| Surround reverb | In surround exports, gives the side, rear and height speakers their own decorrelated copy of each space's reverb. |
| Fold-down trims | Level of the surrounds and heights when the 7.1.4 is folded to fewer speakers. |
| Loudness meter | BS.1770-4 momentary, short-term and integrated loudness and true peak of what is playing, and "Measure full mix" for the 7.1.4, 5.1, stereo fold-down and laptop-and-phone versions. |
| IR reverb | In a space's panel, switch Room to "IR reverb" and load an impulse response (a recording of a real room). It replaces the built-in reverb for that space, live and in exports. Up to six seconds. |
| Track order | Drag a track's name up or down, or ⌥⌘↑ / ⌥⌘↓. |

## Export

Movie with the stereo mix, stereo WAV, binaural WAV, 12-channel 7.1.4 WAV, and an ADM BWF
(7.1.2 bed plus one object per spatial track, with position data) for Atmos workflows in
Logic Pro, Pro Tools, Resolve or the Dolby Atmos Renderer. Files land in the session's
`Exports` folder. Sessions live in `~/Movies/mitroley`.

To hear how the immersive mix translates to smaller systems, these are all folded from one
7.1.4 render, so they are the same mix:

| Format | What it is |
| --- | --- |
| 5.1 surround | 6-channel WAV (L R C LFE Ls Rs). Heights fold into the front at −3 dB, rear surrounds and top rears into the side surrounds at −3 dB. |
| Stereo fold-down (Lo/Ro) | The standard ITU downmix of that 5.1, LFE left out: what a TV or streaming service plays on a stereo set. |
| Stereo for laptop and phone speakers | Keeps as much of the surround impression as two small speakers can: surrounds widened past the speakers, heights brightened, deep bass carried by its harmonics. Aimed at −14 LUFS with peaks held at −1 dBTP; a quiet, peaky mix stops short rather than take more than 12 dB of limiting. The widening backs off if the mono sum would lose more than 3 dB. |
| Mixdown set | A folder with all of the above plus the 7.1.4 and the mono sum of the laptop and phone file (what one phone speaker plays), and `How these translate.txt` with the loudness, true peak, correlation and mono loss of each. |

## Checking the engine

```bash
build/mitroley.app/Contents/MacOS/Foley --selftest /path/to/folder
```

The folder needs a short `click.wav` and `noise.wav`. The test renders a synthetic session
offline and checks scene-following reverb, muffling, sample-locked tracks, panning, automation
and every export format.

## Sharing

`docs/SHARING.md` covers putting this on GitHub, how other people install it and how to send updates.
`docs/MCP.md` covers connecting it to Claude.

## Copyright

Made by Ayan Mitra. Copyright © 2026 Ayan Mitra. All rights reserved. See `LICENSE`.
