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
- "Show all pole vectors" shows every limb's pole vector at once, handy for
  reviewing the overall pose.
- "Hide cloak/tabard" and "Show right/left hand weapon" are convenience
  visual toggles (the weapon is just a placeholder blade for posing a grip).
- "Reset pose" restores the rig to the imported model's original pose.
- **Undo** (button, or Ctrl+Z) steps back through the last edits.
- **Focus** (button, or F) centers the camera on the current selection.

### Timeline & export

- Set a **Duration**, pose the rig, and press **Save to timeline** to drop a
  keyframe at the current playhead time. Scrubbing the timeline previews the
  interpolated pose between keyframes (the same way NWN interpolates at
  runtime, so what you see matches what will play in-game).
- **Save** exports a `.txt` file with the MDL ASCII block — a single pose if
  you haven't used the timeline, or the full multi-keyframe animation
  otherwise.
- **Open** loads a previously exported `.txt` back onto the timeline so you
  can keep editing it.
- **Copy / Paste**: copy the pose shown at the current playhead position,
  then move the playhead and press Paste to overwrite that keyframe with it
  (creating one if there wasn't already a keyframe there).
- **Remove**: deletes the keyframe at the current playhead position. Click
  near a yellow dot on the timeline to snap the playhead exactly onto it
  first (it gets a white ring when selected).
- **Play**: loops playback between 0 and the duration, interpolating poses
  live. Dragging the timeline while playing pauses it.

## Notes

- The `SDK/` folder (Godot executables) isn't included in this repository
  due to its size: download Godot 4.7 separately as described above.
- The dummy model (`assets/a_ba.glb`) must use the exact NWN node names
  (`rootdummy`, `torso_g`, `pelvis_g`, etc.) — see [CLAUDE.md](CLAUDE.md)
  for details on the export format.
