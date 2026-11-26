# Handover: building mitroley for Windows

Read this first if you are a new session picking the project up, on Windows or anywhere else. It holds what the code
cannot tell you: what the app is for, what its owner likes and has rejected, the standing rules, and what is unfinished.
The Mac app in this repo is the reference; when this file and the code disagree about behaviour, the code is right.

## What mitroley is

A Mac app for fitting sound to a video: sound effects, foley, ambience, music and voice laid on a timeline under the
picture, mixed on a console, and exported for the place it will be played. It is a small DAW with the picture at its
centre, and with Claude able to drive it (analyse the video, plan cues, generate sounds, place and mix them).

- Swift, SwiftUI, AppKit, AVFoundation, Metal. About 21,000 lines in `Sources/Foley`, built with `./build.sh`.
- Bundle id `studio.foley.app`, executable `Foley`, a second executable `foley-mcp` for the MCP server (`MCP.md`).
- `Foley --selftest <folder>` runs the engine tests and prints `ALL PASSED`. The folder needs `click.wav` and `noise.wav`.
- Sessions are folders with a `project.json` and the audio beside it. New fields in saved types are always optional, so
  older sessions keep opening.

## What does not carry over to Windows

Almost all of the code is tied to Apple frameworks, so a Windows version is a rebuild that follows the same design:

| Part | On the Mac | Needs a Windows equivalent |
| --- | --- | --- |
| Interface | SwiftUI + AppKit | Any toolkit that can draw custom controls and a canvas |
| Audio engine | AVAudioEngine (`MixGraph.swift`, `Player.swift`) | A real-time graph: tracks, buses, pre/post effects, sidechain |
| Effects | Apple audio units | Own DSP or another plugin format |
| Video | AVPlayer, AVAssetReader | Frame-accurate playback and frame grabs |
| Backdrop | Metal shader in `Flag.swift` | The same shader in HLSL/GLSL; it is a port of a WebGL one, so the maths is portable |
| Export | AVFoundation writers, ADM BWF by hand | Same file formats; the ADM writer is plain bytes and ports directly |
| Spatial | AVAudioEnvironmentNode | A binaural/Atmos-bed renderer |

What does carry over, and should be kept identical: the session file format, the mixing and routing rules, loudness
targets and export formats, the library measuring (`Library.swift`), the cut check (`CutCheck.swift`), ducking and EQ
ducking logic, and the whole look and behaviour described below.

Not yet decided by the owner: one shared codebase for both systems (for example JUCE, or a web interface over a native
engine) or a separate Windows app. Ask before choosing; a shared codebase means the Mac app eventually moves onto it.

## The window, as it is now

- **Picture** top centre, with a vertical tool strip on its left and a floating transport bar under it. The transport
  sheds items when the pane is narrow (film volume slider, then meter, then Mine/Film).
- **Timeline** under the picture: ruler, filmstrip and scenes pinned on top; track names pinned on the left; lanes with
  clips, fades, crossfades, automation lanes. It can scroll past the end of the film.
- **Dock** under the timeline: the mixer or the library, resizable, and either can pop out into its own window.
- **Library browser** down the left (⌥⌘L): shapes and folders in a narrow column, a dense list of sounds beside it,
  a preview at the foot. Click plays, double-click places, drag drops onto a track, arrow keys step through.
- **Right panel** (⌥⌘I to hide): the inspector for whatever is selected, or the Claude panel.
- **Backdrop**: the theme's picture hung behind the whole window like a flag in a slow wind, blurred behind the panels in
  its own shader. Seven themes; six ship with a picture in `Support/Backdrops`.

## The mixer

- **Console** style by default: narrow strips divided by hairlines, each with a name plate, a pan knob, small lit keys
  (M, S, PRE/PST, A for automation), a long fader with a scale, a segmented meter, a duck key and an output menu.
  The older rounded **Cards** style still ships and must keep working (Settings › Mixer, and a switch in the dock).
- Strips share out the width of the mixer so it fills from side to side. Dragging the line between strips sets a
  chosen width; double-click goes back to filling. Below 62 pt per strip it scrolls.
- **Cables** under the strips: each track's output runs to its bus or the master, sidechains are dashed. They hang and
  swing on springs. Pull a plug out of a jack and carry it to another to reroute, or onto another track to sidechain;
  take a cable by its middle and it follows the hand. Right-click a jack for Route / Route Only / Sidechain /
  Sidechain Only, the cable shape (hanging, stepped) and look (fading, dotted, flat).
- Buses are group nodes with their own effect chain. Effects can sit before or after the fader per track.

## What the owner likes, and has rejected

Likes:
- Things that feel physical and alive: springs, cables that swing, faders with detents, haptic taps, a backdrop that
  moves like cloth. Motion that responds to the hand, never decoration running on its own.
- Glass: translucent panels with the backdrop blurred behind them, thin floating scroll bars, no solid slabs.
- A real console look for the mixer. References given: FL Studio, Ableton, Reaper, Pro Tools.
- Gradients over flat colour for sliders, track colour bars, strip top lines and cables.
- Dense, quiet controls. Colour only where it carries meaning (the track's own colour, a lit key, a meter).
- Plain words in the interface. No em dashes in UI copy.

Rejected, do not bring back:
- Polka dots or any generated pattern as a backdrop. It must be the actual picture, moving.
- Glossy toy-like jacks (a gradient disc with a bright dot and a shine), and arrow-shaped ports. The jacks are flat: a
  hairline collar, a dark recess, a small point in the cable's colour.
- Cut corners on the mixer cards.
- A taut straight cable shape.
- A 30 fps backdrop as the default ("feels tacky"). 60 fps, with lighter motion levels offered as an option.
- A serial-number gate at launch. The checker code stays; the gate is removed.
- Solid fills where a panel should show the backdrop through it.
- Fat system scroll bars.

Standing concerns:
- **Heat and battery.** The laptop runs hot. Idle work must be near zero: the audio engine pauses after 20 idle
  seconds, the cable clock only runs while something moves, the backdrop has motion levels (auto, smooth, light, still).
- **Nothing lost.** When a look is replaced, the old one stays available behind a setting.

## Rules for working in this repo

- Commits carry no `Co-Authored-By: Claude` line and no "Generated with Claude Code" line. The owner is the sole author.
- Push only when the owner asks.
- Never commit or print API keys, tokens or the serial signing key (it lives outside the repo, in the owner's
  Application Support folder). Never enter keys or sign in on the owner's behalf.
- Do not spend paid credits (ElevenLabs, Anthropic and the like) on tests unless asked.
- Do not download and run third-party tools without asking.
- After a change: build, run the self-test, look at the result on screen, and say plainly what was not checked by hand.

## Unfinished, as of this handover

- FL-style sends: a track feeding several destinations, each with its own level. Needs an engine change.
- A second assistant backend using an OpenAI key. Waiting on the owner's key.
- Usage analytics. Waiting on a choice of service.
- Music generation from inside the app (Suno, ACE). Only reachable through Claude Code today.
- More shape directions for the mixer were discussed and none chosen.
- Smaller lists (Claude panel, Settings) still use system scroll bars.
- The frosted track-name column during a pinch zoom was reported as going solid; one fix was made on a guess and is
  not confirmed.

## Where to start reading

`MainView.swift` (window layout), `TimelineView.swift` and `TimelineHost.swift` (timeline), `Console.swift` and
`Mixer.swift` (mixer and cables), `MixGraph.swift` and `Player.swift` (engine), `Exporter.swift` (formats and loudness),
`Flag.swift` and `Themes.swift` (backdrop and themes), `Library.swift` (sound library), `SelfTest.swift` (what the
engine must do, as tests), `Tools.swift` and `MCP.md` (what Claude can drive).
