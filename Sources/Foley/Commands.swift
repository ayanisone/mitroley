import AppKit
import QuartzCore
import Foundation

struct CommandError: LocalizedError {
    var message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct CommandResult {
    var json: [String: Any]
    var images: [(label: String, path: String)] = []
}

extension Dictionary where Key == String, Value == Any {
    func num(_ k: String) -> Double? {
        if let d = self[k] as? Double { return d }
        if let i = self[k] as? Int { return Double(i) }
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String { return Double(s) }
        return nil
    }
    func str(_ k: String) -> String? { self[k] as? String }
    func flag(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.boolValue }
        return nil
    }
}

/// One command surface shared by the in-app Claude agent, the local control server and the MCP bridge.
/// Anything Claude can do to a session is defined here once.
@MainActor
final class Commands {
    unowned let store: Store
    private var lastVoices: [Voice] = []
    init(store: Store) { self.store = store }

    // MARK: Tool definitions (JSON Schema)

    private static func tool(_ name: String, _ description: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "input_schema": ["type": "object", "properties": props, "required": required] as [String: Any]]
    }
    private static func p(_ type: String, _ description: String, extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = ["type": type, "description": description]
        for (k, v) in extra { d[k] = v }
        return d
    }
    private static let position: [String: Any] = [
        "type": "object",
        "description": "Room position. x: -1 left … 1 right. y: -1 behind … 1 in front of the listener. z: 0 ear level … 1 overhead.",
        "properties": ["x": ["type": "number"], "y": ["type": "number"], "z": ["type": "number"]],
    ]

    static let tools: [[String: Any]] = [
        tool("get_project", "Returns the whole session: video, storyboard, spaces, scenes, tracks, clips, takes and automation. Call this first."),
        tool("new_session", "Starts a new, empty session and makes it the open one. The previous session is saved and stays on disk.",
             ["name": p("string", "Session name.")], required: ["name"]),
        tool("import_video", "Loads a video file into the session. The timeline takes the video's length and shots are detected automatically.",
             ["path": p("string", "Absolute path to the video file.")], required: ["path"]),
        tool("analyze_video", "Detects shot cuts and returns still frames so you can see what happens in the picture: one frame at the start of every shot plus frames at a regular interval, each labelled with its time. Use it to work out where the action is, which room or place each moment is in, and when on-screen events happen.",
             ["start": p("number", "Only look from this time. Use with end to study one stretch closely, e.g. 4 frames a second inside a shot to follow something moving."),
              "end": p("number", "Only look up to this time."),
              "interval": p("number", "Seconds between sampled frames. Default: about 1 s, widened until the frames fit max_frames."),
              "max_frames": p("integer", "Upper limit on frames returned. Default 24, maximum 40.")]),
        tool("get_frames", "Returns still frames at exact times, for a closer look at a moment (a door closing, a foot landing, a character crossing a doorway).",
             ["times": ["type": "array", "items": ["type": "number"], "description": "Times in seconds. Up to 12."]], required: ["times"]),
        tool("list_space_templates", "Lists the built-in acoustic spaces (Living Room, Cave, Street, Next Room …) with their settings."),
        tool("define_space", "Creates or updates an acoustic space by name. A space is what a place sounds like: its reverb, echo, how dark the reflections are, and how muffled or quiet direct sound becomes there. Start from a template and adjust only what differs.",
             ["name": p("string", "Name shown in the scene lane, e.g. \"Dining room\"."),
              "template": p("string", "Built-in space to start from, e.g. \"Living Room\", \"Cave\", \"Next Room\"."),
              "reverb": p("string", "Reverb character.", extra: ["enum": ReverbKind.allCases.map(\.rawValue)]),
              "wet": p("number", "0…1. How much sound goes into the room's reverb. Furnished room ≈ 0.15, tiled bathroom ≈ 0.4, cave ≈ 0.45, outdoors ≈ 0.03."),
              "size": p("number", "0…1, small room to large, overriding the reverb type's own size."),
              "tone_hz": p("number", "Low-pass on the reverb return, 300…20000. Soft furnishings ≈ 6000, hard bright room ≈ 12000, cave ≈ 4000."),
              "echo": p("number", "0…1. Discrete echo before the reverb, for caves, tunnels, canyons."),
              "echo_time": p("number", "Echo delay in seconds, 0.05…1."),
              "echo_feedback": p("number", "0…0.9. How many times the echo repeats."),
              "muffle_hz": p("number", "Low-pass applied to the direct sound while in this space, 200…20000. 20000 = none. Use for sound heard through a wall, from inside a car, or underwater."),
              "dry_trim_db": p("number", "dB applied to the direct sound while in this space, e.g. -6 when the source is in the next room."),
              "ambience_prompt": p("string", "A sound-effect prompt for this place's background sound."),
              "impulse_response": p("string", "Path to an audio file with an impulse response of a real room. The space then uses it (IR reverb) instead of the built-in reverb; reverb and size no longer apply. Pass an empty string to go back to the built-in reverb.")], required: ["name"]),
        tool("set_scenes", "Replaces the scene lane. Scenes are the time regions that tell every scene-following track which space it is in. Cover the whole timeline without gaps. Split wherever the acoustic space changes, which is not always at a cut: a character walking from one room to another inside one shot needs two scenes with a long transition.",
             ["scenes": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "start": ["type": "number"], "end": ["type": "number"],
                    "name": p("string", "Short label, e.g. \"Kitchen, wide\"."),
                    "space": p("string", "Name of a space defined with define_space or a template name. Omit for no acoustics."),
                    "transition": p("number", "Seconds of crossfade into this scene. 0.1 for a hard cut, 1–3 when the camera or character moves between spaces."),
                    "note": p("string", "What happens, for the humans reading the session."),
                ] as [String: Any],
                "required": ["start", "end", "name"]] as [String: Any]]], required: ["scenes"]),
        tool("add_track", "Adds a track.",
             ["name": p("string", "Track name."),
              "kind": p("string", "What the track holds.", extra: ["enum": TrackKind.allCases.map(\.rawValue)]),
              "space_mode": p("string", "follow = takes on the space of the current scene (foley, fx, usually ambience). fixed = always in one space. dry = no space (music, voice-over).", extra: ["enum": SpaceMode.allCases.map(\.rawValue)]),
              "fixed_space": p("string", "Space name when space_mode is fixed."),
              "spatial": p("boolean", "true = a point source with a room position (an Atmos object). false = a stereo bed."),
              "position": position], required: ["name", "kind"]),
        tool("update_track", "Changes a track's mix settings, or moves it with index. Only the fields you pass change.",
             ["track": p("string", "Track name or id."),
              "name": p("string", "New name."),
              "volume_db": p("number", "Fader in dB, -60…12."),
              "pan": p("number", "-1…1, for stereo-bed tracks."),
              "mute": p("boolean", "Mute."), "solo": p("boolean", "Solo."),
              "space_mode": p("string", "follow, fixed or dry.", extra: ["enum": SpaceMode.allCases.map(\.rawValue)]),
              "fixed_space": p("string", "Space name when space_mode is fixed."),
              "space_amount": p("number", "0…1. How strongly spaces apply to this track."),
              "low_cut_hz": p("number", "High-pass, 20…2000."),
              "high_cut_hz": p("number", "Low-pass, 200…20000."),
              "lfe_send": p("number", "0…1. How much of the track's low end (below 120 Hz) also goes to the sub channel in the 7.1.4 and Atmos exports. Use for thunder, explosions, impacts, heavy landings, deep rumbles; 0.5–1 for the big ones. Leave at 0 for footsteps, voices, light effects and most music."),
              "spatial": p("boolean", "Point source with a room position, or stereo bed."),
              "position": position,
              "duck_under_voice": p("boolean", "Music tracks only. true = find where someone speaks (on voice-over tracks, and in the film's own sound when it is turned up) and write a Volume lane that dips the music under them. false = remove those dips. Off unless asked for."),
              "duck_depth_db": p("number", "How far the music dips, 3…18 dB. 9 by default."),
              "index": p("integer", "Moves the track to this place in the track list, 0 = top (the order get_project lists them in). It joins a group when it lands between two tracks of that group, keeps its own group when it lands at that group's edge, and otherwise leaves its group.")],
             required: ["track"]),
        tool("set_automation", "Writes automation on a track. Without from/to it replaces the whole lane; with from and to it replaces only the keyframes inside that time range and leaves the rest, so you can work scene by scene. Pass an empty list to clear. Parameters: volume (dB added to the fader), highCut (Hz, lower = more muffled or further away), lowCut (Hz, higher = thinner, smaller), send (0…1 how much of the scene's space is heard), x (left-right; on stereo-bed tracks this is the pan), y (depth), z (height). Each keyframe's curve says how the value travels to the next one: omit for a straight line, \"hold\" to stay put and jump at the next keyframe (use at cuts), \"smooth\" to ease in and out (use for moves).",
             ["track": p("string", "Track name or id."),
              "param": p("string", "Which parameter.", extra: ["enum": AutoParam.allCases.map(\.rawValue)]),
              "from": p("number", "Start of the range to replace."),
              "to": p("number", "End of the range to replace."),
              "keyframes": ["type": "array", "items": ["type": "object", "properties": ["time": ["type": "number"], "value": ["type": "number"], "curve": ["type": "string", "enum": ["linear", "hold", "smooth"]]] as [String: Any], "required": ["time", "value"]] as [String: Any]] as [String: Any]],
             required: ["track", "param", "keyframes"]),
        tool("generate_sfx", "Generates a sound effect with ElevenLabs and places it on a track as a clip with several takes to choose from. Waits for the takes. Prompts work best when they describe the sound itself, the material and the perspective, without the room (the space adds the room): \"single leather shoe footstep on a wooden floor, close, dry\". ElevenLabs makes 0.5–30 s; for longer ambience set loop true and any duration.",
             ["track": p("string", "Track name or id."),
              "prompt": p("string", "Description of the sound."),
              "start": p("number", "Timeline position in seconds."),
              "duration": p("number", "Clip length in seconds."),
              "takes": p("integer", "How many alternatives to generate, 1–4. Default 3."),
              "loop": p("boolean", "Seamless loop, tiled to fill the clip. For ambience and steady textures."),
              "prompt_influence": p("number", "0…1. Higher follows the prompt more literally with less variety. Default 0.3."),
              "name": p("string", "Clip name."),
              "fade_in": p("number", "Seconds."), "fade_out": p("number", "Seconds."),
              "gain_db": p("number", "Clip gain in dB.")], required: ["track", "prompt", "start", "duration"]),
        tool("generate_missing", "Generates audio for every cue that has a prompt but no sound yet (placeholders). Cues with identical prompts share one generation. Waits until done.",
             ["takes": p("integer", "Takes per cue, 1–4. Default 2.")]),
        tool("compose_music", "Composes one piece of music for the film with ElevenLabs and places it on a music track. The piece is built from sections that follow the picture, so the music changes where the film does. Write the sections yourself after watching the video: one per scene or group of shots, each with styles that say how the music should feel there (mood, energy, instrumentation: \"tense\", \"sparse\", \"low strings\", \"full orchestra hit\"). Sections must be 3 s to 2 min each; shorter ones are merged with a neighbour. Give genre, mood, instruments and tempo for the whole piece. Never name artists, bands or existing songs. Instrumental unless vocals is true. Costs credits and takes a minute or more. Call it again for another take.",
             ["style": p("string", "Extra overall style terms, comma-separated."),
              "genre": p("string", "Genre, e.g. cinematic orchestral, lo-fi, synthwave, Indian classical fusion."),
              "mood": p("string", "Mood, e.g. hopeful, tense, playful."),
              "instruments": p("string", "Lead instruments, comma-separated."),
              "tempo_bpm": p("integer", "Tempo in BPM. Omit to let the music decide."),
              "avoid": p("string", "What must not be in it, comma-separated, e.g. drums, electric guitar."),
              "vocals": p("boolean", "true = sung, with lyrics. Default false (instrumental)."),
              "lyrics": p("string", "Lyrics, one line per row, when vocals is true. Original words only."),
              "start": p("number", "Score only from this time."), "end": p("number", "Score only up to this time."),
              "sections": ["type": "array", "description": "Sections in order, covering the stretch to score. Omit to use the scene lane as it is.", "items": [
                "type": "object",
                "properties": ["start": ["type": "number"], "end": ["type": "number"],
                               "cue": p("string", "Short label for the section, e.g. \"Storm builds\"."),
                               "styles": ["type": "array", "items": ["type": "string"], "description": "How the music feels here: mood, energy, instrumentation."]] as [String: Any],
                "required": ["start", "end"]] as [String: Any]] as [String: Any],
              "track": p("string", "Music track name or id. Defaults to the first music track, created if needed.")]),
        tool("import_revised_video", "Loads a revised cut of the film that is already in the session. The app compares the two cuts shot by shot, makes a new session for the new cut, and moves every sound, keyframe and scene with its picture. Nothing is regenerated. Returns the stretches that are new or longer and so have no sound yet: work only on those.",
             ["path": p("string", "Absolute path to the revised video file.")], required: ["path"]),
        tool("get_revision", "For a session made from a revised cut: the stretches of picture that are new (\"new\") or where a shot runs longer than before (\"longer\"). Everything outside them already has its sound from the previous cut and should be left alone unless the user asks."),
        tool("set_group", "Puts tracks into a group (one fader, mute and solo for all of them, and they fold away together), or takes them out. The group is created by name if it does not exist.",
             ["tracks": ["type": "array", "items": ["type": "string"], "description": "Track names or ids."] as [String: Any],
              "group": p("string", "Group name, e.g. SFX, Ambience, Music. Omit to remove the tracks from their group."),
              "volume_db": p("number", "Group fader in dB, added to every track in it."),
              "mute": p("boolean", "Mute the whole group."), "solo": p("boolean", "Solo the whole group."),
              "collapsed": p("boolean", "Fold the group's tracks away in the timeline.")], required: ["tracks"]),
        tool("place_steps", "Places footsteps one footfall at a time, so they match the walk on screen. First find the frame of every footfall: step through the walking shot with analyze_video (start, end, interval 0.1 or less) and note the time each foot lands. Then call this with those times. The app records a walk on the surface you describe, cuts it into single steps, and puts a different step on every time, each varied a little in level and pitch. Use this instead of one long footsteps clip. Uses two generations however many steps there are; pass source_clip to cut the steps from a footsteps clip that already exists and spend nothing.",
             ["track": p("string", "Foley track name or id."),
              "times": ["type": "array", "items": ["type": "number"], "description": "Time in seconds of every footfall, in order."] as [String: Any],
              "prompt": p("string", "Shoe and surface, e.g. \"heavy boots on packed snow\", \"bare feet on wet stone\"."),
              "source_clip": p("string", "Id of an existing footsteps clip to cut the steps from, instead of generating."),
              "gain_db": p("number", "Level for all steps, dB."),
              "variation": p("number", "0…1 how much each step differs in level and pitch. Default 0.5."),
              "replace_from": p("number", "With replace_to: first remove the clips on the track that start in this range (the old footsteps)."),
              "replace_to": p("number", "End of the range to clear.")], required: ["track", "times"]),
        tool("original_sound", "Brings the film's own soundtrack into the session so parts of it can be reused. mode \"track\" puts the whole soundtrack on one muted track (instant, free). mode \"stems\" splits it with ElevenLabs into voice, drums, bass, guitar, piano and other, each on its own track in a muted group (costs credits, takes a minute). There is no clean effects-only stem: sound effects mostly land in \"other\", percussive ones in \"drums\".",
             ["mode": p("string", "track or stems.", extra: ["enum": ["track", "stems"]])], required: ["mode"]),
        tool("transcribe_voices", "Listens to the film's own soundtrack and returns every spoken line with its speaker and start and end time. Use it to find voice-over or dialogue in the video. With place true, each line is also put on a voice track as a cue waiting for a voice. Costs a few credits.",
             ["place": p("boolean", "Also place the lines as cues on a voice track. Default false.")]),
        tool("list_voices", "Lists ElevenLabs voices that can speak a line, with accent, gender, age and a description. First the voices in the user's account; with library true, also voices from ElevenLabs' shared library that match. Pick voices that fit the characters on screen: look at who is speaking (age, gender, where they are from) and match accent and age.",
             ["search": p("string", "Words to match in the name or description."),
              "accent": p("string", "Accent, e.g. indian, british, american."),
              "gender": p("string", "male or female."),
              "library": p("boolean", "Also search the shared voice library. A library voice is added to the user's account the first time it speaks.")]),
        tool("speak_line", "Has an ElevenLabs voice say a line and places it on a voice track at a time. Use it to re-record voice-over found with transcribe_voices: same words, same start time. Returns the takes with their length; if a take is longer than the original line, tighten it with update_clip speed (up to about 1.15) or start it slightly earlier. For a group speaking together, call this once per voice with the same text and start, three or four different voices, each a few dB lower, and nudge their starts 20 to 60 ms apart so it sounds like a crowd and not a chorus effect. You cannot hear the result, so tell the user which voices you chose and why.",
             ["text": p("string", "The words to say. Punctuation shapes the delivery."),
              "voice": p("string", "Voice id or exact name from list_voices."),
              "start": p("number", "Timeline position in seconds."),
              "track": p("string", "Voice track name or id. Defaults to the first voice track, created if needed."),
              "takes": p("integer", "Alternatives to generate, 1–3. Default 2."),
              "name": p("string", "Clip name."),
              "gain_db": p("number", "Clip gain in dB.")], required: ["text", "voice", "start"]),
        tool("add_audio_clip", "Places an existing audio file on a track.",
             ["track": p("string", "Track name or id."),
              "file": p("string", "Absolute path to a wav, mp3, m4a or aiff file."),
              "start": p("number", "Timeline position in seconds."),
              "name": p("string", "Clip name."),
              "duration": p("number", "Clip length. Defaults to the file's length."),
              "offset": p("number", "Seconds into the file to start from."),
              "loop": p("boolean", "Tile the file to fill the clip."),
              "fade_in": p("number", "Seconds."), "fade_out": p("number", "Seconds."),
              "gain_db": p("number", "Clip gain in dB.")], required: ["track", "file", "start"]),
        tool("update_clip", "Moves, trims or adjusts a clip, or switches its take. Only the fields you pass change.",
             ["clip": p("string", "Clip id."),
              "track": p("string", "Move the clip to this track (name or id)."),
              "start": p("number", "Seconds."), "duration": p("number", "Seconds."), "offset": p("number", "Seconds into the source."),
              "gain_db": p("number", "dB."), "fade_in": p("number", "Seconds."), "fade_out": p("number", "Seconds."),
              "loop": p("boolean", "Tile the source."), "active_take": p("integer", "Zero-based take index."),
              "speed": p("number", "Playback speed 0.5…2. Below 1 is slower and lower in pitch (heavier, bigger), above 1 faster and higher (lighter, smaller). 1 = as recorded."),
              "fade_in_shape": p("string", "Curve of the fade-in: equalPower (default, smooth for most sounds), linear, sCurve (gentle at both ends), slow (stays quiet, then rises), fast (rises quickly, then eases).", extra: ["enum": FadeShape.allCases.map(\.rawValue)]),
              "fade_out_shape": p("string", "Curve of the fade-out, same choices as fade_in_shape.", extra: ["enum": FadeShape.allCases.map(\.rawValue)]),
              "name": p("string", "Clip name.")], required: ["clip"]),
        tool("crossfade", "Crossfades a clip with its neighbour on the same track: the clip it already overlaps, else the nearest clip whose edge is within 0.05 s of its own (the following clip first). The overlap is centred on the join and limited by the audio each clip has to spare; the first clip fades out while the second fades in. Use it to join two takes or two pieces of ambience without a click or a gap.",
             ["clip": p("string", "Clip id. Either clip of the pair works."),
              "length": p("number", "Seconds of overlap. Defaults to the existing overlap, else 0.1. 0.01–0.05 hides an edit, 0.5–2 blends two beds."),
              "shape": p("string", "equalPower (default, for different sounds), linear (for two copies of the same sound), sCurve.", extra: ["enum": ["equalPower", "linear", "sCurve"]])],
             required: ["clip"]),
        tool("delete_clip", "Removes a clip.", ["clip": p("string", "Clip id.")], required: ["clip"]),
        tool("delete_track", "Removes a track and its clips.", ["track": p("string", "Track name or id.")], required: ["track"]),
        tool("transport", "Controls playback in the app so the person at the Mac can watch and listen.",
             ["action": p("string", "What to do.", extra: ["enum": ["play", "pause", "seek"]]),
              "time": p("number", "Seconds, for seek (optional for play).")], required: ["action"]),
        tool("focus", "Selects something in the app so the person at the Mac sees it in the inspector, and moves the playhead to it. Pass one of clip, track, scene or space.",
             ["clip": p("string", "Clip id."), "track": p("string", "Track name or id."),
              "scene": p("string", "Scene name."), "space": p("string", "Space name.")]),
        tool("measure_takes", "Measures the audio of every take, since you cannot hear it: where the sound actually starts inside the file (onset), where its loudest moment is, its peak and average level in dBFS, and how steady it is. Use it to land hits on their frame (set the clip's offset to the onset so the sound starts when the clip does), to choose between takes, and to set gain_db so levels are balanced. Pass a track to limit the result.",
             ["track": p("string", "Only this track (name or id).")]),
        tool("set_loop", "Marks a section of the timeline to loop during playback, or clears it. Useful to point the person at a moment you changed.",
             ["start": p("number", "Seconds."), "end": p("number", "Seconds."), "clear": p("boolean", "Remove the loop region.")]),
        tool("set_monitor", "Switches live monitoring between plain stereo and the spatial (binaural / Atmos-style) render, and/or sets what the session is mixed for. The format decides which speakers the Room window shows and which export is offered first; every format can still be exported.",
             ["mode": p("string", "stereo or spatial.", extra: ["enum": ["stereo", "spatial"]]),
              "format": p("string", "Session mix format.", extra: ["enum": MixFormat.allCases.map(\.rawValue)])]),
        tool("set_master", "Edits the master effects rack. Nothing is applied to the mix unless an effect is in the rack and on; a new session has an empty rack. Passing any setting of an effect adds that effect. compressor and limiter are linked across every channel (one gain from the loudest channel, applied to all, so the image never shifts and no channel clips) and run live and in every export except stems. surround_reverb gives side, rear and height speakers their own decorrelated copy of each space's reverb in surround exports. trims set surround and height levels in fold-downs. loudness is a meter only. Only the fields you pass change.",
             ["compressor": p("boolean", "Add and switch on, or switch off."),
              "threshold_db": p("number", "-48…0."), "ratio": p("number", "1…12."),
              "attack_ms": p("number", "0.5…120."), "release_ms": p("number", "20…1200."), "makeup_db": p("number", "0…18."),
              "limiter": p("boolean", "Add and switch on, or switch off."),
              "ceiling_dbtp": p("number", "-6…0. True-peak ceiling."), "limiter_release_ms": p("number", "20…800."),
              "surround_reverb": p("boolean", "Add and switch on, or switch off."),
              "surround_spread": p("number", "0…1. How different the surround copies of the reverb are from the front's."),
              "surround_trim_db": p("number", "-12…6. Level of the surround speakers when the 7.1.4 mix is folded to fewer speakers."),
              "height_trim_db": p("number", "-12…6. Level of the height speakers in those folds."),
              "loudness_meter": p("boolean", "Show or hide the loudness meter in the rack."),
              "remove": p("array", "Effects to take out of the rack.", extra: ["items": ["type": "string", "enum": EffectKind.allCases.map(\.rawValue)]])]),
        tool("measure_mix", "Renders the whole session once and returns integrated loudness (LUFS, BS.1770-4) and true peak (dBTP) of the 7.1.4, the 5.1, the stereo fold-down and the laptop-and-phone stereo. Use it to check a mix against a delivery spec such as -14 LUFS, -1 dBTP. It renders the whole session, so it can take a minute or two."),
        tool("export", "Renders the session to a file and returns its path. movie = the video with the stereo mix. stereo and binaural = WAV. stems = a folder with one WAV per track; groupStems = one WAV per group. bed714 = 12-channel 7.1.4 WAV. surround51 = 6-channel 5.1 WAV folded from the 7.1.4. stereoFold = the standard Lo/Ro stereo fold-down of that 5.1 (what a TV does with a surround mix). speakers = stereo for laptop and phone speakers, folded from the 7.1.4 with widened surrounds, a height cue and bass harmonics, -14 LUFS, -1 dBTP, checked in mono. mixdowns = a folder with the 7.1.4, 5.1, stereo fold-down, laptop-and-phone stereo, its mono sum and a text file with the loudness of each. adm = ADM BWF with a 7.1.2 bed and one object per spatial track, for Atmos workflows.",
             ["format": p("string", "Output format.", extra: ["enum": ExportFormat.allCases.map(\.rawValue)]),
              "path": p("string", "Absolute output path. Defaults to the session's Exports folder.")], required: ["format"]),
    ]

    // MARK: Dispatch

    func call(_ name: String, _ a: [String: Any]) async throws -> CommandResult {
        switch name {
        case "get_project":
            return CommandResult(json: describe())
        case "check_keys":
            // Diagnostics only: describes the saved keys without revealing them.
            var out: [String: Any] = ["elevenlabs_saved": Secrets.has(.elevenLabs), "anthropic_saved": Secrets.has(.anthropic)]
            if let k = Secrets.get(.elevenLabs) {
                let v = await ElevenLabs.verify(k)
                out["elevenlabs_ok"] = v.ok
                out["elevenlabs_message"] = v.message
            }
            if let k = Secrets.get(.anthropic), let p = Secrets.problem(k) { out["anthropic_problem"] = p }
            if a.flag("open_settings") == true { store.showSettings = true }
            return CommandResult(json: out)
        case "new_session":
            let name = (a.str("name") ?? "Untitled").replacingOccurrences(of: "/", with: "-")
            store.create(named: name.isEmpty ? "Untitled" : name)
            return CommandResult(json: ["ok": true, "name": store.project.name, "folder": store.folder.path])
        case "import_video":
            guard let path = a.str("path") else { throw CommandError("path is required.") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CommandError("No file at \(path).") }
            try await store.importVideo(url)
            return CommandResult(json: ["ok": true, "duration": store.project.duration, "fps": store.project.fps,
                                        "shots": store.project.scenes.map { ["start": r($0.start), "end": r($0.end), "name": $0.name] }])
        case "analyze_video":
            return try await analyze(a)
        case "get_frames":
            guard store.videoURL != nil else { throw CommandError("There is no video in the session yet.") }
            let times = ((a["times"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }.prefix(12)
            let frames = await store.writeFrames(at: Array(times))
            return CommandResult(json: ["frames": frames.map { ["time": r($0.time), "path": $0.path] }],
                                 images: frames.map { (String(format: "Frame at %.2f s", $0.time), $0.path) })
        case "list_space_templates":
            return CommandResult(json: ["templates": SpaceTemplate.all.map { spaceJSON($0.space) }])
        case "define_space":
            return try defineSpace(a)
        case "set_scenes":
            return try setScenes(a)
        case "add_track":
            guard let name = a.str("name"), let kind = TrackKind(rawValue: a.str("kind") ?? "") else {
                throw CommandError("name and a valid kind are required.")
            }
            let id = store.addTrack(kind: kind, name: name)
            var rest = a
            rest["track"] = id.uuidString
            rest["name"] = nil
            _ = try await updateTrack(rest)
            return CommandResult(json: ["ok": true, "track_id": id.uuidString])
        case "update_track":
            return try await updateTrack(a)
        case "set_automation":
            let ti = try trackIndex(a)
            guard let param = AutoParam(rawValue: a.str("param") ?? "") else { throw CommandError("Unknown param.") }
            let keys = ((a["keyframes"] as? [[String: Any]]) ?? []).compactMap { k -> Keyframe? in
                guard let t = k.num("time"), let v = k.num("value") else { return nil }
                let curve = k.str("curve")
                return Keyframe(time: max(0, t), value: min(param.range.upperBound, max(param.range.lowerBound, v)),
                                curve: curve == "hold" || curve == "smooth" ? curve : nil)
            }
            var total = 0
            store.mutate { p in
                var list = keys
                if let from = a.num("from"), let to = a.num("to"), to > from {
                    list += p.tracks[ti].keys(param).filter { $0.time < from || $0.time > to }
                }
                list.sort { $0.time < $1.time }
                total = list.count
                p.tracks[ti].automation[param.rawValue] = list.isEmpty ? nil : list
                if !list.isEmpty { p.tracks[ti].lane = param }
            }
            return CommandResult(json: ["ok": true, "keyframes_written": keys.count, "keyframes_in_lane": total])
        case "generate_sfx":
            let ti = try trackIndex(a)
            guard let prompt = a.str("prompt"), let start = a.num("start"), let duration = a.num("duration"), duration > 0 else {
                throw CommandError("prompt, start and duration are required.")
            }
            let loop = a.flag("loop") ?? false
            guard Secrets.has(.elevenLabs) else {
                // No key yet: keep the cue with its prompt and timing so it can be generated later in one go.
                let id = store.addCue(prompt: prompt, track: store.project.tracks[ti].id, start: max(0, start), duration: duration,
                                      loop: loop || duration > 30, name: a.str("name"), fadeIn: a.num("fade_in") ?? 0.01,
                                      fadeOut: a.num("fade_out") ?? 0.05, gain: a.num("gain_db") ?? 0)
                return CommandResult(json: ["ok": true, "clip_id": id.uuidString, "placeholder": true,
                                            "note": "No ElevenLabs API key is set in mitroley, so this cue was placed without audio. It will be generated by generate_missing, or by the Generate button in the app, once the key is added in Settings."])
            }
            let id = await store.generate(prompt: prompt, track: store.project.tracks[ti].id, start: max(0, start), duration: duration,
                                          takes: min(4, max(1, Int(a.num("takes") ?? 3))), loop: loop || duration > 30,
                                          influence: a.num("prompt_influence") ?? 0.3, name: a.str("name"),
                                          fadeIn: a.num("fade_in") ?? 0.01, fadeOut: a.num("fade_out") ?? 0.05, gain: a.num("gain_db") ?? 0)
            guard let loc = store.project.locate(clip: id) else { throw CommandError("The clip disappeared.") }
            let clip = store.project.tracks[loc.track].clips[loc.clip]
            if clip.takes.isEmpty { throw CommandError(clip.error ?? "ElevenLabs returned no audio.") }
            return CommandResult(json: ["ok": true, "clip": clipJSON(clip)])
        case "generate_missing":
            guard Secrets.has(.elevenLabs) else { throw CommandError("No ElevenLabs API key is set in mitroley's Settings. \(store.missingCues.count) cues are waiting.") }
            let r = await store.generateMissing(takes: min(4, max(1, Int(a.num("takes") ?? 2))))
            return CommandResult(json: ["ok": true, "generated": r.done, "failed": r.failed, "still_missing": store.missingCues.count])
        case "compose_music":
            guard Secrets.has(.elevenLabs) else { throw CommandError("No ElevenLabs API key is set in mitroley's Settings, so music cannot be composed.") }
            var o = store.project.music ?? MusicOptions()
            if let v = a.str("genre") { o.genre = v }
            if let v = a.str("mood") { o.mood = v }
            if let v = a.str("instruments") { o.instruments = v }
            if let v = a.str("avoid") { o.avoid = v }
            if let v = a.num("tempo_bpm") { o.tempo = min(220, max(40, Int(v))) }
            o.vocals = a.flag("vocals") ?? false
            if let v = a.str("lyrics") { o.lyrics = v }
            o.loopOnly = false
            var sections: [MusicSection]?
            if let list = a["sections"] as? [[String: Any]], !list.isEmpty {
                sections = list.compactMap { s in
                    guard let st = s.num("start"), let en = s.num("end"), en > st else { return nil }
                    return MusicSection(start: st, end: en, cue: s.str("cue") ?? "", styles: (s["styles"] as? [String]) ?? [])
                }
            } else if let st = a.num("start"), let en = a.num("end"), en > st {
                sections = store.project.scenes.filter { $0.end > st && $0.start < en }.sorted { $0.start < $1.start }
                    .map { MusicSection(start: max(st, $0.start), end: min(en, $0.end), cue: $0.name, styles: []) }
            }
            let style = a.str("style") ?? ""
            guard !(style + o.genre + o.mood + o.instruments).isEmpty else { throw CommandError("Give at least a genre, a mood or a style.") }
            var track: UUID?
            if a.str("track") != nil { track = store.project.tracks[try trackIndex(a)].id }
            let id = try await store.composeMusic(style: style, sections: sections, track: track, options: o)
            guard let l = store.project.locate(clip: id) else { throw CommandError("The clip disappeared.") }
            return CommandResult(json: ["ok": true, "clip": clipJSON(store.project.tracks[l.track].clips[l.clip]), "track": store.project.tracks[l.track].name])
        case "import_revised_video":
            guard let path = a.str("path") else { throw CommandError("path is required.") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CommandError("No file at \(path).") }
            let report = try await store.importRevision(url)
            var out = revisionJSON()
            out["ok"] = true; out["session"] = store.project.name; out["folder"] = store.folder.path
            out["sounds_carried_over"] = report.clipsKept; out["sounds_dropped"] = report.clipsRemoved
            return CommandResult(json: out)
        case "get_revision":
            guard store.project.revision != nil else { throw CommandError("This session was not made from a revised cut.") }
            return CommandResult(json: revisionJSON())
        case "set_group":
            let keys = (a["tracks"] as? [String]) ?? []
            var ids: [UUID] = []
            for k in keys { ids.append(store.project.tracks[try trackIndex(["track": k])].id) }
            guard !ids.isEmpty else { throw CommandError("tracks is required.") }
            let gid = store.setGroup(a.str("group"), for: ids)
            if let gid {
                store.editGroup(gid) { g in
                    if let v = a.num("volume_db") { g.volume = min(12, max(-60, v)) }
                    if let v = a.flag("mute") { g.mute = v }
                    if let v = a.flag("solo") { g.solo = v }
                    if let v = a.flag("collapsed") { g.collapsed = v }
                }
            }
            return CommandResult(json: ["ok": true, "groups": groupsJSON()])
        case "place_steps":
            let ti = try trackIndex(a)
            let times = ((a["times"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            guard !times.isEmpty else { throw CommandError("times is required: the time of every footfall.") }
            var replace: ClosedRange<Double>?
            if let f = a.num("replace_from"), let t = a.num("replace_to"), t > f { replace = f...t }
            if let key = a.str("source_clip"), UUID(uuidString: key).flatMap({ store.project.locate(clip: $0) }) == nil {
                throw CommandError("No clip with the id given as source_clip.")
            }
            let n = try await store.placeSteps(track: store.project.tracks[ti].id, times: times, prompt: a.str("prompt") ?? "shoes on a hard floor",
                                               source: UUID(uuidString: a.str("source_clip") ?? ""), gain: a.num("gain_db") ?? 0,
                                               variation: min(1, max(0, a.num("variation") ?? 0.5)), replace: replace)
            return CommandResult(json: ["ok": true, "steps_placed": n, "note": "Each step starts on its time. Check a few against the picture with get_frames."])
        case "original_sound":
            if a.str("mode") == "stems" {
                let names = try await store.splitOriginalSound()
                return CommandResult(json: ["ok": true, "stems": names, "note": "The stems are in a muted group called Original sound. Cut the parts worth keeping out of them and move those to other tracks."])
            }
            let id = try await store.addOriginalSound()
            return CommandResult(json: ["ok": true, "track_id": id.uuidString, "note": "The track is muted. Trim copies of the clip down to the moments worth keeping."])
        case "transcribe_voices":
            let lines = a.flag("place") == true ? try await store.transcribeToTrack() : try await store.transcribe()
            return CommandResult(json: ["lines": lines.map { ["speaker": $0.speaker, "text": $0.text, "start": r($0.start), "end": r($0.end)] },
                                        "note": lines.isEmpty ? "No speech was found." : "Times are where each line is spoken in the film. Look at those moments with get_frames to see who is speaking."])
        case "list_voices":
            var list = try await ElevenLabs.voices(search: a.str("search"))
            if a.flag("library") == true {
                list += try await ElevenLabs.sharedVoices(search: a.str("search"), accent: a.str("accent"), gender: a.str("gender"))
            }
            if let acc = a.str("accent")?.lowercased(), !acc.isEmpty { list = list.filter { $0.owner != nil || $0.accent.lowercased().contains(acc) } }
            if let g = a.str("gender")?.lowercased(), !g.isEmpty { list = list.filter { $0.owner != nil || $0.gender.lowercased() == g } }
            lastVoices = list
            return CommandResult(json: ["voices": list.prefix(60).map { v -> [String: Any] in
                ["id": v.id, "name": v.name, "accent": v.accent, "gender": v.gender, "age": v.age, "about": String(v.about.prefix(160)), "in_account": v.owner == nil]
            }])
        case "speak_line":
            guard let text = a.str("text"), !text.isEmpty, let key = a.str("voice"), let start = a.num("start") else { throw CommandError("text, voice and start are required.") }
            var known = lastVoices
            if !known.contains(where: { $0.id == key || $0.name.caseInsensitiveCompare(key) == .orderedSame }) { known = try await ElevenLabs.voices() }
            guard let voice = known.first(where: { $0.id == key }) ?? known.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw CommandError("No voice \"\(key)\". Call list_voices and use an id from it.")
            }
            let track: UUID
            if a.str("track") != nil { track = store.project.tracks[try trackIndex(a)].id }
            else { track = store.project.tracks.first { $0.kind == .dialogue }?.id ?? store.addTrack(kind: .dialogue, name: "Voice-over") }
            let id = try await store.speak(text, voice: voice, track: track, start: start, takes: min(3, max(1, Int(a.num("takes") ?? 2))),
                                           name: a.str("name"), gain: a.num("gain_db") ?? 0)
            guard let l = store.project.locate(clip: id) else { throw CommandError("The clip disappeared.") }
            return CommandResult(json: ["ok": true, "clip": clipJSON(store.project.tracks[l.track].clips[l.clip]), "track": store.project.tracks[l.track].name])
        case "add_audio_clip":
            let ti = try trackIndex(a)
            guard let file = a.str("file"), let start = a.num("start") else { throw CommandError("file and start are required.") }
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CommandError("No file at \(file).") }
            guard let id = store.importAudio(url, track: store.project.tracks[ti].id, at: max(0, start), name: a.str("name")) else {
                throw CommandError("That file could not be read as audio.")
            }
            var rest = a
            rest["clip"] = id.uuidString
            rest["track"] = nil; rest["start"] = nil; rest["name"] = nil
            return try updateClip(rest)
        case "update_clip":
            return try updateClip(a)
        case "crossfade":
            guard let id = UUID(uuidString: a.str("clip") ?? a.str("clip_id") ?? ""), let l = store.project.locate(clip: id) else { throw CommandError("No clip with that id.") }
            var shape: FadeShape?
            if let v = a.str("shape") {
                guard let s = FadeShape(rawValue: v) else { throw CommandError("Unknown shape \(v). Use equalPower, linear or sCurve.") }
                shape = s
            }
            guard store.project.tracks[l.track].crossfadePartner(of: id) != nil else {
                throw CommandError("That clip has no neighbour on its track to crossfade with. Move the other clip so its edge is within 0.05 s of this one, then try again.")
            }
            guard store.crossfade(id, length: a.num("length").map { max(0.005, $0) }, shape: shape) else {
                throw CommandError("Neither clip has spare audio to overlap. Trim one of them back (shorten the first clip's end or move the second clip's start later), then crossfade.")
            }
            guard let x = store.project.locate(clip: id).flatMap({ store.project.tracks[$0.track].crossfade(involving: id) }) else { throw CommandError("The crossfade could not be made.") }
            return CommandResult(json: ["ok": true, "start": r(x.start), "end": r(x.end), "length": r(x.length),
                                        "first": clipJSON(x.a), "second": clipJSON(x.b)])
        case "delete_clip":
            guard let id = UUID(uuidString: a.str("clip") ?? ""), store.project.locate(clip: id) != nil else { throw CommandError("No clip with that id.") }
            store.mutate { p in if let l = p.locate(clip: id) { p.tracks[l.track].clips.remove(at: l.clip) } }
            return CommandResult(json: ["ok": true])
        case "delete_track":
            let ti = try trackIndex(a)
            store.mutate { $0.tracks.remove(at: ti) }
            return CommandResult(json: ["ok": true])
        case "transport":
            switch a.str("action") {
            case "play":
                if let t = a.num("time") { store.player.seek(t) }
                store.player.play()
            case "pause": store.player.pause()
            case "seek": store.player.seek(a.num("time") ?? 0)
            default: throw CommandError("action must be play, pause or seek.")
            }
            return CommandResult(json: ["ok": true, "time": r(store.player.time), "playing": store.player.isPlaying])
        case "debug_layout":
            guard let sv = Self.timelineScrollView(), let doc = sv.documentView else { return CommandResult(json: ["found": false]) }
            return CommandResult(json: ["flipped": doc.isFlipped, "clip_flipped": sv.contentView.isFlipped,
                                        "origin": [sv.contentView.bounds.origin.x, sv.contentView.bounds.origin.y],
                                        "viewport": [sv.contentView.bounds.width, sv.contentView.bounds.height],
                                        "doc": [doc.frame.width, doc.frame.height],
                                        "fitting": [doc.intrinsicContentSize.width, doc.intrinsicContentSize.height],
                                        "floating": sv.subviews.map { String(describing: type(of: $0)) }])
        case "debug_switch":
            // Not listed as a tool: switches through the cuts of this film and back, and reports how long each switch held the main thread.
            let home = store.folder
            var times: [[String: Any]] = []
            for url in store.versionList + [home] where url != store.folder {
                let t0 = CACurrentMediaTime()
                store.switchVersion(to: url)
                times.append(["to": url.deletingPathExtension().lastPathComponent, "ms": (CACurrentMediaTime() - t0) * 1000])
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            return CommandResult(json: ["switches": times])
        case "debug_resize":
            // Not listed as a tool: resizes the main window back and forth and reports how often the main thread got a turn.
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.frame.width > 900 }) else {
                return CommandResult(json: ["found": false])
            }
            let seconds = a.num("seconds") ?? 4
            let home = w.frame
            let start = CACurrentMediaTime()
            var last = start, worst = 0.0, steps = 0, slow = 0
            while CACurrentMediaTime() - start < seconds {
                let u = (CACurrentMediaTime() - start) / seconds
                let k = CGFloat(0.5 - 0.5 * cos(u * 2 * .pi))
                var f = home
                f.size.width = home.width - 260 * k
                f.size.height = home.height - 160 * k
                f.origin.y = home.maxY - f.size.height
                w.setFrame(f, display: true)
                try await Task.sleep(nanoseconds: 4_000_000)
                let now = CACurrentMediaTime()
                if now - last > 0.02 { slow += 1 }
                worst = max(worst, now - last); last = now; steps += 1
            }
            w.setFrame(home, display: true)
            return CommandResult(json: ["steps": steps, "per_second": Double(steps) / seconds, "worst_ms": worst * 1000, "steps_over_20ms": slow])
        case "debug_scroll":
            // Not listed as a tool: zooms in, scrolls the timeline sideways for a few seconds and reports how often the main thread got a turn.
            let seconds = a.num("seconds") ?? 5
            let before = store.zoom
            store.zoom = a.num("zoom") ?? 6
            try await Task.sleep(nanoseconds: 800_000_000)
            let start = CACurrentMediaTime()
            var last = start, worst = 0.0, steps = 0, slow = 0
            while CACurrentMediaTime() - start < seconds {
                let u = (CACurrentMediaTime() - start) / seconds
                // Moves the scroll view itself, the way a trackpad does, rather than asking SwiftUI to scroll.
                if let sv = Self.timelineScrollView() {
                    let x = CGFloat(3000 * (0.5 - 0.5 * cos(u * 2 * .pi)))
                    sv.contentView.scroll(to: NSPoint(x: x, y: sv.contentView.bounds.origin.y))
                    sv.reflectScrolledClipView(sv.contentView)
                }
                try await Task.sleep(nanoseconds: 4_000_000)
                let now = CACurrentMediaTime()
                if now - last > 0.02 { slow += 1 }
                worst = max(worst, now - last); last = now; steps += 1
            }
            store.zoom = before
            return CommandResult(json: ["steps": steps, "per_second": Double(steps) / seconds, "worst_ms": worst * 1000, "steps_over_20ms": slow])
        case "debug_zoom":
            // Not listed as a tool: drives the pinch drawing for a few seconds and reports how often the main thread got a turn.
            let seconds = a.num("seconds") ?? 4
            let start = CACurrentMediaTime()
            var last = start, worst = 0.0, steps = 0
            let base = Double(1200) / max(1, store.project.duration) * store.zoom
            store.zoomLive.active = true
            while CACurrentMediaTime() - start < seconds {
                let u = (CACurrentMediaTime() - start) / seconds
                store.zoomLive.pps = base * (1 + 5 * (0.5 - 0.5 * cos(u * 2 * .pi)))
                store.zoomLive.x = CGFloat(20 * store.zoomLive.pps) - 300
                try await Task.sleep(nanoseconds: 4_000_000)
                let now = CACurrentMediaTime()
                worst = max(worst, now - last); last = now; steps += 1
            }
            store.zoomLive.active = false
            return CommandResult(json: ["steps": steps, "per_second": Double(steps) / seconds, "worst_ms": worst * 1000])
        case "focus":
            if let id = UUID(uuidString: a.str("clip") ?? ""), let l = store.project.locate(clip: id) {
                store.selection = .clip(id)
                store.player.seek(store.project.tracks[l.track].clips[l.clip].start)
            } else if a.str("track") != nil {
                store.selection = .track(store.project.tracks[try trackIndex(a)].id)
            } else if let name = a.str("scene"), let sc = store.project.scenes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                store.selection = .scene(sc.id)
                store.player.seek(sc.start)
            } else if let name = a.str("space"), let sp = store.project.space(named: name) {
                store.selection = .space(sp.id)
            } else {
                throw CommandError("Nothing matched. Pass a clip id, or a track, scene or space name.")
            }
            store.showClaude = false
            return CommandResult(json: ["ok": true])
        case "measure_takes":
            var only: UUID?
            if a.str("track") != nil { only = store.project.tracks[try trackIndex(a)].id }
            var rows: [[String: Any]] = []
            for t in store.project.tracks where only == nil || t.id == only {
                for c in t.clips.sorted(by: { $0.start < $1.start }) {
                    for (i, take) in c.takes.enumerated() {
                        guard let m = Commands.measure(store.url(for: take)) else { continue }
                        var row: [String: Any] = ["track": t.name, "clip": c.id.uuidString, "name": c.name, "clip_start": r(c.start),
                                                  "take": i, "active": i == c.activeTake]
                        for (k, v) in m { row[k] = (v * 100).rounded() / 100 }
                        rows.append(row)
                    }
                }
            }
            return CommandResult(json: ["takes": rows, "note": "onset and peak_at are seconds into the file. steady_db is the typical level of a 50 ms slice; when it is far below loudest_db the sound is a short hit with silence around it."])
        case "set_loop":
            if a.flag("clear") == true { store.clearLoop() }
            else if let s = a.num("start"), let e = a.num("end"), e > s { store.setLoop(s, e) }
            else { throw CommandError("Pass start and end, or clear.") }
            return CommandResult(json: ["ok": true])
        case "set_monitor":
            let f = a.str("format"), mode = a.str("mode")
            if f == nil && mode == nil { throw CommandError("Pass mode, format or both.") }
            if let f {
                guard let format = MixFormat(rawValue: f) else { throw CommandError("format must be 7.1.4, 5.1, binaural or stereo.") }
                store.setFormat(format)
            }
            if let mode {
                guard let m = MonitorMode(rawValue: mode) else { throw CommandError("mode must be stereo or spatial.") }
                store.player.monitor = m
            }
            return CommandResult(json: ["ok": true, "format": store.project.format.rawValue, "monitor": store.player.monitor.rawValue])
        case "set_master":
            store.mutate { p in
                func set(_ kind: EffectKind, _ key: String, _ arg: String) {
                    guard let v = a.num(arg), let spec = kind.params.first(where: { $0.key == key }) else { return }
                    p.withEffect(kind) { $0.values[key] = min(spec.range.upperBound, max(spec.range.lowerBound, v)) }
                }
                for (kind, arg) in [(EffectKind.compressor, "compressor"), (.limiter, "limiter"), (.surroundReverb, "surround_reverb"), (.loudness, "loudness_meter")] {
                    if let v = a.flag(arg) { p.withEffect(kind) { $0.on = v } }
                }
                set(.compressor, "threshold", "threshold_db"); set(.compressor, "ratio", "ratio"); set(.compressor, "attack", "attack_ms")
                set(.compressor, "release", "release_ms"); set(.compressor, "makeup", "makeup_db")
                set(.limiter, "ceiling", "ceiling_dbtp"); set(.limiter, "release", "limiter_release_ms")
                set(.surroundReverb, "spread", "surround_spread")
                set(.trims, "surround", "surround_trim_db"); set(.trims, "height", "height_trim_db")
                for name in (a["remove"] as? [String]) ?? [] { if let k = EffectKind(rawValue: name) { p.removeEffect(k) } }
            }
            return CommandResult(json: ["ok": true, "master": masterJSON(store.project)])
        case "measure_mix":
            let rows = try await store.measureMix()
            return CommandResult(json: ["formats": rows.map { ["format": $0.name, "lufs": $0.lufs.map { r($0) } ?? NSNull(), "true_peak_dbtp": r($0.truePeak)] as [String: Any] },
                                        "target": "-14 LUFS integrated, -1 dBTP"])
        case "export":
            guard let f = ExportFormat(rawValue: a.str("format") ?? "") else { throw CommandError("Unknown format.") }
            let out = try await store.export(f, to: a.str("path").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
            return CommandResult(json: ["ok": true, "path": out.url.path, "summary": out.summary])
        default:
            throw CommandError("Unknown tool \(name).")
        }
    }

    // MARK: Implementations

    private func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    private func trackIndex(_ a: [String: Any]) throws -> Int {
        guard let key = a.str("track") else { throw CommandError("track is required.") }
        if let id = UUID(uuidString: key), let i = store.project.trackIndex(id) { return i }
        if let i = store.project.tracks.firstIndex(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) { return i }
        throw CommandError("No track named \"\(key)\". Tracks: \(store.project.tracks.map(\.name).joined(separator: ", ")).")
    }

    /// Finds a space by name, creating it from a template of the same name if needed.
    private func spaceID(named name: String) throws -> UUID {
        if let s = store.project.space(named: name) { return s.id }
        if let t = SpaceTemplate.named(name) { return store.addSpace(from: t) }
        throw CommandError("No space named \"\(name)\". Define it first with define_space, or use a template: \(SpaceTemplate.all.map(\.name).joined(separator: ", ")).")
    }

    private func defineSpace(_ a: [String: Any]) throws -> CommandResult {
        guard let name = a.str("name"), !name.isEmpty else { throw CommandError("name is required.") }
        var s: Space
        let existing = store.project.space(named: name)
        if let existing {
            s = existing
        } else if let t = a.str("template").flatMap(SpaceTemplate.named) ?? SpaceTemplate.named(name) {
            s = t.space
            s.id = UUID()
            s.name = name
        } else {
            s = Space(name: name, hue: Double(abs(name.hashValue) % 100) / 100)
        }
        if existing != nil, let t = a.str("template").flatMap(SpaceTemplate.named) {
            let id = s.id, hue = s.hue
            s = t.space; s.id = id; s.hue = hue; s.name = name
        }
        if let v = a.str("reverb"), let k = ReverbKind(rawValue: v) { s.reverb = k }
        if let v = a.num("wet") { s.wet = min(1, max(0, v)) }
        if let v = a.num("size") { s.size = min(1, max(0, v)) }
        if let v = a.num("tone_hz") { s.tone = min(20000, max(300, v)) }
        if let v = a.num("echo") { s.echo = min(1, max(0, v)) }
        if let v = a.num("echo_time") { s.echoTime = min(1, max(0.05, v)) }
        if let v = a.num("echo_feedback") { s.echoFeedback = min(0.9, max(0, v)) }
        if let v = a.num("muffle_hz") { s.muffle = min(20000, max(200, v)) }
        if let v = a.num("dry_trim_db") { s.dryTrim = min(6, max(-40, v)) }
        if let v = a.str("ambience_prompt") { s.ambiencePrompt = v }
        if a.str("impulse_response") == "" { s.ir = nil }
        let final = s
        defer {
            if let path = a.str("impulse_response"), !path.isEmpty {
                store.importIR(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), space: final.id)
            }
        }
        store.mutate { p in
            if let i = p.spaces.firstIndex(where: { $0.id == final.id }) { p.spaces[i] = final } else { p.spaces.append(final) }
        }
        return CommandResult(json: ["ok": true, "space": spaceJSON(final)])
    }

    private func setScenes(_ a: [String: Any]) throws -> CommandResult {
        guard let list = a["scenes"] as? [[String: Any]], !list.isEmpty else { throw CommandError("scenes must be a non-empty list.") }
        var out: [SceneRegion] = []
        for s in list {
            guard let start = s.num("start"), let end = s.num("end"), end > start else { throw CommandError("Every scene needs start < end.") }
            var region = SceneRegion(start: max(0, start), end: min(store.project.duration, end), name: s.str("name") ?? "Scene")
            if let sp = s.str("space"), !sp.isEmpty { region.spaceID = try spaceID(named: sp) }
            region.transition = min(8, max(0.02, s.num("transition") ?? 0.12))
            region.note = s.str("note") ?? ""
            out.append(region)
        }
        out.sort { $0.start < $1.start }
        // Close small gaps and overlaps so crossfades line up.
        for i in 1..<max(1, out.count) where i < out.count { out[i - 1].end = out[i].start }
        store.mutate { $0.scenes = out }
        return CommandResult(json: ["ok": true, "scenes": out.count])
    }

    /// The widest scroll view in the main window: the timeline.
    static func timelineScrollView() -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, (s.documentView?.frame.width ?? 0) > (best?.documentView?.frame.width ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        for w in NSApp.windows { if let c = w.contentView { walk(c) } }
        return best
    }

    private func masterJSON(_ p: Project) -> [[String: Any]] {
        p.effects.map { e in
            var values: [String: Any] = [:]
            for spec in e.kind.params { values[spec.key] = r(e.value(spec.key)) }
            return ["effect": e.kind.rawValue, "on": e.on, "values": values]
        }
    }

    private func updateTrack(_ a: [String: Any]) async throws -> CommandResult {
        let ti = try trackIndex(a)
        let id = store.project.tracks[ti].id
        var fixed: UUID?
        if let name = a.str("fixed_space") { fixed = try spaceID(named: name) }
        store.mutate { p in
            if let v = a.str("name") { p.tracks[ti].name = v }
            if let v = a.num("volume_db") { p.tracks[ti].volume = min(12, max(-60, v)) }
            if let v = a.num("pan") { p.tracks[ti].pan = min(1, max(-1, v)) }
            if let v = a.flag("mute") { p.tracks[ti].mute = v }
            if let v = a.flag("solo") { p.tracks[ti].solo = v }
            if let v = a.str("space_mode"), let m = SpaceMode(rawValue: v) { p.tracks[ti].spaceMode = m }
            if let fixed { p.tracks[ti].fixedSpace = fixed }
            if let v = a.num("space_amount") { p.tracks[ti].send = min(1, max(0, v)) }
            if let v = a.num("low_cut_hz") { p.tracks[ti].lowCut = min(2000, max(20, v)) }
            if let v = a.num("high_cut_hz") { p.tracks[ti].highCut = min(20000, max(200, v)) }
            if let v = a.num("lfe_send") { p.tracks[ti].lfeSend = min(1, max(0, v)) }
            if let v = a.flag("spatial") { p.tracks[ti].spatial = v }
            if let pos = a["position"] as? [String: Any] {
                if let x = pos.num("x") { p.tracks[ti].position.x = min(1, max(-1, x)) }
                if let y = pos.num("y") { p.tracks[ti].position.y = min(1, max(-1, y)) }
                if let z = pos.num("z") { p.tracks[ti].position.z = min(1, max(0, z)) }
            }
            if let v = a.num("index") { p.moveTrack(id, to: Int(v.rounded())) }
        }
        if let on = a.flag("duck_under_voice") {
            guard store.project.tracks.first(where: { $0.id == id })?.kind == .music else { throw CommandError("duck_under_voice is for music tracks.") }
            await store.setDucking(id, on: on, depth: a.num("duck_depth_db"))
        } else if let d = a.num("duck_depth_db"), store.project.tracks.first(where: { $0.id == id })?.duck != nil {
            await store.setDucking(id, on: true, depth: d)
        }
        guard let now = store.project.trackIndex(id) else { throw CommandError("That track no longer exists.") }
        return CommandResult(json: ["ok": true, "index": now, "track": trackJSON(store.project.tracks[now])])
    }

    private func updateClip(_ a: [String: Any]) throws -> CommandResult {
        guard let id = UUID(uuidString: a.str("clip") ?? ""), store.project.locate(clip: id) != nil else { throw CommandError("No clip with that id.") }
        var destination: Int?
        if a.str("track") != nil { destination = try trackIndex(a) }
        store.mutate { p in
            guard var l = p.locate(clip: id) else { return }
            if let d = destination, d != l.track {
                let c = p.tracks[l.track].clips.remove(at: l.clip)
                p.tracks[d].clips.append(c)
                l = (d, p.tracks[d].clips.count - 1)
            }
            var c = p.tracks[l.track].clips[l.clip]
            if let v = a.num("start") { c.start = max(0, v) }
            if let v = a.num("duration"), v > 0.02 { c.duration = v }
            if let v = a.num("offset") { c.offset = max(0, v) }
            if let v = a.num("gain_db") { c.gain = min(24, max(-60, v)) }
            if let v = a.num("fade_in") { c.fadeIn = max(0, v) }
            if let v = a.num("fade_out") { c.fadeOut = max(0, v) }
            if let v = a.str("fade_in_shape").flatMap(FadeShape.init(rawValue:)) { c.fadeInShape = v == .equalPower ? nil : v }
            if let v = a.str("fade_out_shape").flatMap(FadeShape.init(rawValue:)) { c.fadeOutShape = v == .equalPower ? nil : v }
            if let v = a.flag("loop") { c.loop = v }
            if let v = a.num("speed") { c.rate = abs(v - 1) < 0.01 ? nil : min(2, max(0.5, v)) }
            if let v = a.num("active_take"), c.takes.indices.contains(Int(v)) { c.activeTake = Int(v) }
            if let v = a.str("name") { c.name = v }
            p.tracks[l.track].clips[l.clip] = c
        }
        guard let l = store.project.locate(clip: id) else { throw CommandError("The clip disappeared.") }
        return CommandResult(json: ["ok": true, "clip": clipJSON(store.project.tracks[l.track].clips[l.clip])])
    }

    private func analyze(_ a: [String: Any]) async throws -> CommandResult {
        guard let url = store.videoURL, let video = store.project.video else { throw CommandError("There is no video in the session yet. Use import_video first.") }
        let cuts = await VideoAnalysis.detectCuts(url)
        let shots = Store.scenes(from: cuts, duration: video.duration)
        let maxFrames = min(40, max(4, Int(a.num("max_frames") ?? 24)))
        var interval = a.num("interval") ?? 1.0
        var times: [Double] = []
        // Widen the interval until the frame count fits.
        let from = a.num("start") ?? 0, to = a.num("end") ?? video.duration
        if a.num("start") != nil || a.num("end") != nil, a.num("interval") == nil { interval = max(0.1, (to - from) / Double(maxFrames)) }
        for _ in 0..<16 {
            times = []
            for s in shots {
                var t = s.start + min(0.12, (s.end - s.start) / 4)
                while t < s.end - 0.05 {
                    if t >= from && t <= to { times.append(t) }
                    t += interval
                }
            }
            if times.count <= maxFrames { break }
            interval *= 1.35
        }
        if times.count > maxFrames { times = Array(times.prefix(maxFrames)) }
        let frames = await store.writeFrames(at: times, maxSize: 640)
        func shot(_ t: Double) -> Int { (shots.firstIndex { t >= $0.start && t < $0.end } ?? 0) + 1 }
        return CommandResult(
            json: ["duration": r(video.duration), "fps": video.fps, "width": video.width, "height": video.height,
                   "shots": shots.enumerated().map { ["shot": $0 + 1, "start": r($1.start), "end": r($1.end)] },
                   "frames": frames.map { ["time": r($0.time), "shot": shot($0.time), "path": $0.path] },
                   "note": "Cuts are detected from picture changes; dissolves and moves between rooms inside one shot are not cuts. Use get_frames for a closer look."],
            images: frames.map { (String(format: "Shot %d, %.2f s", shot($0.time), $0.time), $0.path) })
    }

    /// Level and timing of one audio file, from the decoded samples.
    nonisolated static func measure(_ url: URL) -> [String: Double]? {
        guard let buf = AudioCache.shared.buffer(url), let ch = buf.floatChannelData, buf.frameLength > 0 else { return nil }
        let n = Int(buf.frameLength), l = ch[0], rt = ch[1]
        var peak: Float = 0, peakAt = 0, sum = 0.0
        for i in 0..<n {
            let v = abs(l[i] + rt[i]) * 0.5
            if v > peak { peak = v; peakAt = i }
            sum += Double(v * v)
        }
        guard peak > 0 else { return ["duration": Double(n) / 48000, "onset": 0, "peak_at": 0, "peak_db": -90, "average_db": -90, "loudest_db": -90, "steady_db": -90] }
        let threshold = max(peak * 0.12, 0.002)
        var onset = 0
        for i in 0..<n where abs(l[i] + rt[i]) * 0.5 > threshold { onset = i; break }
        let block = 2400
        var blocks: [Double] = []
        var i = 0
        while i + block <= n {
            var s = 0.0
            for j in i..<(i + block) { let v = Double(l[j] + rt[j]) * 0.5; s += v * v }
            blocks.append((s / Double(block)).squareRoot())
            i += block
        }
        blocks.sort()
        let rms = (sum / Double(n)).squareRoot()
        return ["duration": Double(n) / 48000, "onset": Double(onset) / 48000, "peak_at": Double(peakAt) / 48000,
                "peak_db": linearToDb(Double(peak)), "average_db": linearToDb(rms),
                "loudest_db": linearToDb(blocks.last ?? rms), "steady_db": linearToDb(blocks.isEmpty ? rms : blocks[blocks.count / 2])]
    }

    // MARK: Describing state

    func groupsJSON() -> [[String: Any]] {
        (store.project.groups ?? []).map { g in
            ["name": g.name, "volume_db": r(g.volume), "mute": g.mute, "solo": g.solo, "collapsed": g.collapsed,
             "tracks": store.project.tracks.filter { $0.groupID == g.id }.map(\.name)]
        }
    }

    func revisionJSON() -> [String: Any] {
        guard let rev = store.project.revision else { return [:] }
        return ["made_from": rev.from, "summary": rev.summary,
                "needs_sound": rev.ranges.map { ["start": r($0.start), "end": r($0.end), "kind": $0.kind] },
                "note": "Only the needs_sound stretches lack sound. Look at them with analyze_video (start, end), give new scenes a space, and add cues there. Leave the rest as it is."]
    }

    func spaceJSON(_ s: Space) -> [String: Any] {
        ["name": s.name, "reverb": s.reverb.rawValue, "wet": r(s.wet), "tone_hz": r(s.tone), "echo": r(s.echo), "echo_time": r(s.echoTime),
         "echo_feedback": r(s.echoFeedback), "muffle_hz": r(s.muffle), "dry_trim_db": r(s.dryTrim), "ambience_prompt": s.ambiencePrompt, "size": s.size.map { r($0) } as Any? ?? NSNull()]
    }

    func clipJSON(_ c: Clip) -> [String: Any] {
        var d: [String: Any] = ["id": c.id.uuidString, "name": c.name, "start": r(c.start), "duration": r(c.duration), "offset": r(c.offset),
                                "gain_db": r(c.gain), "fade_in": r(c.fadeIn), "fade_out": r(c.fadeOut),
                                "fade_in_shape": c.inShape.rawValue, "fade_out_shape": c.outShape.rawValue, "loop": c.loop, "prompt": c.prompt,
                                "active_take": c.activeTake, "speed": r(c.speed),
                                "takes": c.takes.enumerated().map { ["index": $0, "file": store.url(for: $1).path, "duration": r($1.duration)] }]
        if let e = c.error { d["error"] = e }
        if let v = c.voiceName { d["voice"] = v }
        return d
    }

    func trackJSON(_ t: Track) -> [String: Any] {
        var d: [String: Any] = ["id": t.id.uuidString, "name": t.name, "kind": t.kind.rawValue, "volume_db": r(t.volume), "pan": r(t.pan),
                                "mute": t.mute, "solo": t.solo, "space_mode": t.spaceMode.rawValue, "space_amount": r(t.send),
                                "low_cut_hz": r(t.lowCut), "high_cut_hz": r(t.highCut), "lfe_send": r(t.lfeSend), "spatial": t.spatial,
                                "position": ["x": r(t.position.x), "y": r(t.position.y), "z": r(t.position.z)],
                                "clips": t.clips.sorted { $0.start < $1.start }.map(clipJSON)]
        if let s = store.project.space(t.fixedSpace) { d["fixed_space"] = s.name }
        if let g = store.project.group(t.groupID) { d["group"] = g.name }
        var auto: [String: Any] = [:]
        for (k, keys) in t.automation where !keys.isEmpty { auto[k] = keys.map { ["time": r($0.time), "value": r($0.value)] } }
        if !auto.isEmpty { d["automation"] = auto }
        return d
    }

    func describe() -> [String: Any] {
        let p = store.project
        var d: [String: Any] = [
            "name": p.name, "folder": store.folder.path, "duration": r(p.duration), "fps": p.fps,
            "storyboard": p.storyboard, "storyboard_files": p.storyboardFiles,
            "spaces": p.spaces.map(spaceJSON),
            "scenes": p.scenes.sorted { $0.start < $1.start }.map { s -> [String: Any] in
                var o: [String: Any] = ["start": r(s.start), "end": r(s.end), "name": s.name, "space": p.space(s.spaceID)?.name ?? "",
                                        "transition": r(s.transition), "note": s.note]
                if let st = s.status { o["revised"] = st }
                return o
            },
            "tracks": p.tracks.map(trackJSON),
            "monitor": store.player.monitor.rawValue, "mix_format": p.format.rawValue, "master": masterJSON(p), "loop": p.loopRange.map { ["start": r($0.lowerBound), "end": r($0.upperBound)] as [String: Any] } ?? [:], "playhead": r(store.player.time),
            "elevenlabs_key_set": Secrets.has(.elevenLabs), "cues_without_sound": store.missingCues.count,
        ]
        if p.groups != nil { d["groups"] = groupsJSON() }
        if p.revision != nil { d["revision"] = revisionJSON() }
        if let v = p.video, let url = store.videoURL {
            d["video"] = ["path": url.path, "duration": r(v.duration), "fps": v.fps, "width": v.width, "height": v.height]
        }
        return d
    }
}
