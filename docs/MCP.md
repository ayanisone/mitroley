# Using mitroley from Claude (MCP)

mitroley is a Model Context Protocol server, so Claude can see the session that is open in the app and work
on it: look at frames of the video, set scenes and spaces, generate and place sounds, mix, measure and export.

## How it is put together

| Piece | What it does |
| --- | --- |
| `mitroley.app` | Defines every tool (`Sources/Foley/Commands.swift`) and runs them on the open session. While it is open it listens on `127.0.0.1` only (port 47810–47815). |
| `mitroley.app/Contents/MacOS/foley-mcp` | A small stdio MCP server. It has no logic of its own: it asks the app for its tool list and forwards each call. This is the command you register with a client. |
| `~/Library/Application Support/mitroley/control.json` | Written by the app at launch: the port and a random token. The bridge reads it; every request must carry the token, which keeps web pages and other users of the Mac out. |

Transport: MCP over stdio (JSON-RPC 2.0) between the client and `foley-mcp`; plain HTTP on loopback between
`foley-mcp` and the app. Nothing listens on the network. The app must be open, with a session, for tools to work.
Everything Claude changes goes through the same undo stack as your own edits.

## Set it up

mitroley has to be on the same Mac as the client. Put the app in `/Applications` (or use the path where you built it).

**Claude Code**

```bash
claude mcp add mitroley -- /Applications/mitroley.app/Contents/MacOS/foley-mcp
```

Inside this repository nothing is needed: `.mcp.json` already registers the app built by `./build.sh`.
The Claude panel in the app (⌘K) also has "Copy Setup Command" with the right path filled in.

**Claude desktop app**: Settings › Developer › Edit Config, and add:

```json
{
  "mcpServers": {
    "mitroley": { "command": "/Applications/mitroley.app/Contents/MacOS/foley-mcp" }
  }
}
```

Restart Claude, open mitroley with a session, and ask Claude to "look at the mitroley session".

**Any other MCP client**: register the same command as a stdio server. No arguments, no environment variables.

## What Claude can do

35 tools. Claude should start with `get_project`, then `analyze_video` to see the picture.

| Area | Tools |
| --- | --- |
| Session and picture | `get_project`, `new_session`, `import_video`, `analyze_video`, `get_frames`, `focus` |
| Revised cuts | `import_revised_video`, `get_revision` |
| Scenes and spaces | `set_scenes`, `define_space` (also loads an impulse response for IR reverb), `list_space_templates` |
| Tracks and clips | `add_track`, `update_track` (also reorders with `index`), `delete_track`, `set_group`, `add_audio_clip`, `update_clip`, `delete_clip`, `crossfade`, `set_automation` |
| Sound and music | `generate_sfx`, `generate_missing`, `measure_takes`, `place_steps`, `original_sound`, `compose_music` |
| Voice | `transcribe_voices`, `list_voices`, `speak_line` |
| Library and presets | `search_library` (your own sounds, by name, shape, tone and length), `set_preset` (a ready-made sound on a track: phone, radio, underwater and more), `carve_for_voice` (lowers only the voice's frequencies in the music) |
| Mix | `set_master` (the master effects rack: compressor, limiter, surround reverb, fold-down trims, loudness meter), `measure_mix` (LUFS and true peak of every format), `set_monitor` (monitoring and session format) |
| Transport and delivery | `transport`, `set_loop`, `export` |

The exact list and every parameter come from the app itself: a client that lists tools always sees what the
installed version supports.

## Keys and cost

Generating sound uses the ElevenLabs key saved in that Mac's mitroley Settings, so it spends that person's
credits. Claude never sees the key. Without a key, everything except generation still works.

## If it does not connect

- "mitroley has not been opened on this Mac yet": open the app once; it writes `control.json` at launch.
- Tools listed but calls fail: the app is closed, or no session is open.
- Two copies of the app open: the bridge talks to whichever launched last.
