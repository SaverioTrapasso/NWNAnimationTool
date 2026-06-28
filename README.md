# NWNAnimationTool

A Godot tool for posing the Neverwinter Nights IK dummy character and
exporting the pose — as a single static pose or a full multi-keyframe
animation — to an MDL ASCII animation block (`newanim ... doneanim`), ready
to paste into an NWN `.mdl` file.

## Getting started

1. Download [Godot 4.7](https://godotengine.org/download) (the standard build, no .NET needed).
2. Open Godot, choose "Import" and select this repository's `project.godot` file.
3. Press **Play** (top right, or F5).

No build step is needed: GDScript is interpreted directly by the engine.

## Quick usage guide

The window is laid out in three zones: a **top bar** (New/Open/Save), a
**left sidebar** (Tools, Retarget, Animation, Keyframe), and small **icon
buttons centered above the 3D viewport** (Undo, Focus, and the display
toggles). The timeline runs along the bottom.

### Posing

- Click a body part to select it: **cyan** = FK parts (head, torso, pelvis,
  rotated with the 3-axis rotation gizmo), **yellow** = hands/feet (moved
  with the 3-axis translation gizmo, solved as IK with a pole vector for the
  elbow/knee).
- The rotation gizmo's rings and the translation gizmo's arrows are
  deliberately separated (arrows inside, rings outside with a gap) so they
  don't overlap or get misclicked.
- The always-visible **transform panel** (top of the screen, when something
  is selected) shows exact Position/Rotation X/Y/Z values you can type
  directly — handy when the gizmo alone is too fiddly to nail an angle.
- Select the pelvis to also drag the green handle and raise/lower/translate
  the whole body — feet and hands stay anchored to their current world
  position *and* orientation as the body moves or rotates.
- The icon row above the viewport has **Undo**, **Focus** (also Ctrl+Z / F),
  then the display toggles: **Cloak**, **R.Wpn**/**L.Wpn** (placeholder
  blades for posing a grip), **Poles** (show every limb's pole vector at
  once), and **Skel** (the retargeting overlay — see below).
- **Reset pose** (sidebar, under Tools) restores the rig to the imported
  model's original pose.

### Timeline & export

- Set a **Duration** (sidebar, under Animation), pose the rig, and press
  **Set** (under Keyframe) to drop a keyframe at the current playhead time.
  Scrubbing the timeline previews the interpolated pose between keyframes
  (the same way NWN interpolates at runtime, so what you see matches what
  will play in-game).
- **Save** (top bar) exports a `.txt` file with the MDL ASCII block — a
  single pose if you haven't used the timeline, or the full multi-keyframe
  animation otherwise.
- **Open** (top bar) loads a previously exported `.txt` back onto the
  timeline so you can keep editing it.
- **Copy / Paste** (under Keyframe): copy the pose shown at the current
  playhead position, then move the playhead and press Paste to overwrite
  that keyframe with it (creating one if there wasn't already a keyframe
  there).
- **Remove**: deletes the keyframe at the current playhead position. Click
  near a yellow dot on the timeline to snap the playhead exactly onto it
  first (it gets a white ring when selected).
- **Play**: loops playback between 0 and the duration, interpolating poses
  live. Dragging the timeline while playing pauses it.

### Retargeting

Bring in an animation from another rig (e.g. an FF14-style skeleton) and
clone it onto the NWN dummy, bone-by-bone — using the exact same posing
tools as above, not a separate mini-editor.

1. **Load animation** (sidebar, under Retarget): pick the model+animation
   `.glb`/`.gltf` to clone. As soon as it loads, the **Skel** toggle above
   the viewport turns on automatically, showing the source skeleton as a
   red overlay — synced to wherever the main timeline's playhead is, so
   scrubbing the timeline scrubs the overlay too.
2. **Bone configuration** (sidebar): opens a panel mapping each NWN node to
   a source bone name (dropdown per row — rows are always visible, even
   before anything's mapped, so you can use them as a checklist). Also
   holds **Root scale** (how far rootdummy travels relative to the source's
   own root motion — changing it live-rescales the overlay) and **Load
   config** / **Save config** for portable `.cfg` bone-maps (see
   [configs/ff14_retarget_map.cfg](configs/ff14_retarget_map.cfg) for a
   starting point). Before anything is mapped, the overlay shows the
   *entire* source skeleton (fingers, tail, everything) so you have
   something to reference while filling in the table; once at least one row
   is mapped, it narrows down to just the mapped joints.
3. Scrub the timeline to a frame where the overlay is clearly visible, then
   **hand-pose the real rig** (same gizmos as normal posing) to match it.
4. **Lock** (sidebar): records the exact offset between the source bone's
   orientation and your hand-posed orientation, for every mapped node — the
   same idea as a Maya "orient constraint with maintain offset". This is
   what makes the bake numerically robust even when a bone needs a huge
   correction (e.g. a hip bound almost upside-down in the source rig): the
   offset is captured in world space, so it can't introduce mirroring no
   matter how large it is.
5. **Bake**: replays the source animation, maintaining the locked offset
   frame by frame, and drops the result straight onto the timeline — ready
   to preview/play/export like any hand-posed animation. You can load a
   *different* animation that uses the same source rig and press Bake again
   without re-locking, as long as the bone mapping still applies.

## Notes

- The `SDK/` folder (Godot executables) isn't included in this repository
  due to its size: download Godot 4.7 separately as described above.
- The dummy model (`assets/nwn/a_ba.glb`) must use the exact NWN node names
  (`rootdummy`, `torso_g`, `pelvis_g`, etc.) — see [CLAUDE.md](CLAUDE.md)
  for details on the export format.
- `assets/` only holds the NWN dummy itself (`nwn/`) — retargeting sources
  are imported live at runtime, not bundled in the repo. `configs/` holds
  portable bone-map `.cfg` files you can load via "Load config".
