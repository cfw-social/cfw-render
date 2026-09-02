# c-music — LEARNINGS

## Active Feedback

- **Host allowlist is load-bearing for licensing.** Only `media.cfw.social` tracks are
  licensed for redistribution/use. Never relax the host check to fetch external audio —
  that re-introduces the exact legal exposure the library was built to avoid.
- **Recipes mux a LOCAL file, not a URL.** `c-ffmpeg` trims/seeks/probes the audio, which
  is fragile over http. Always fetch to disk with this skill first, then pass `AUDIO_PATH`.
- **Always carry `MUSIC_TRACK_ID` through to `attach_output_to_composition`.** CC-BY tracks
  are only legal because the publish path auto-appends attribution off the output's
  `musicTrackId` metadata. Drop the id and a CC-BY track publishes uncredited.

## History

- 2026-06-11 — Skill created. Bridges the `list_music_tracks` MCP (returns R2 `cdnUrl`)
  to the pipeline mux step (needs a local path). Closes the "library exists but nothing
  downloads the track" gap.
