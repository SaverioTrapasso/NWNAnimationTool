# NWNAnimationTool

A Godot tool for posing the Neverwinter Nights IK dummy character and
exporting the pose as an MDL ASCII animation block (`newanim ... doneanim`),
ready to paste into an NWN `.mdl` file.

## Getting started

1. Download [Godot 4.7](https://godotengine.org/download) (the standard build, no .NET needed).
2. Open Godot, choose "Import" and select this repository's `project.godot` file.
3. Press **Play** (top right, or F5).

No build step is needed: GDScript is interpreted directly by the engine.

## Quick usage guide

- Click a body part to select it: **cyan** = FK parts (head, torso, pelvis,
  rotated with the 3-axis gizmo), **yellow** = hands/feet (dragged in IK,
  with pole vectors for elbows/knees).
- Select the pelvis to also drag the green handle and raise/lower the
  whole body.
- "Show all pole vectors" shows every limb's pole vector at once, handy for
  reviewing the overall pose.
- "Hide cloak/tabard" and "Show weapons" are convenience visual toggles.
- "Reset pose" restores the rig to the imported model's original pose.
- Type an animation name and press **Save** to export a `.txt` file with
  the MDL ASCII block.

## Notes

- The `SDK/` folder (Godot executables) isn't included in this repository
  due to its size: download Godot 4.7 separately as described above.
- The dummy model (`assets/a_ba.glb`) must use the exact NWN node names
  (`rootdummy`, `torso_g`, `pelvis_g`, etc.) — see [CLAUDE.md](CLAUDE.md)
  for details on the export format.
