# Animation Workshop and NWN1 MDL banks

Open **Workshop** above the viewport for document undo/redo, recovery, timeline labels, a pose library and side-by-side animation comparisons.

## Local setup

Use **Workshop → Settings / local folders** to configure optional inputs:

- The folder containing your `F1`, `F2`, and `F3` pose directories.
- An NWN installation's `data` folder and a folder containing custom supermodels.
- Python 3.10+ (leave empty to search PATH).
- A supported `nwnmdlcomp` executable for binary model import/export.
- A local reference-library folder and an optional default idle animation block.

Settings, recovery files, personal poses and working model sessions are kept in
Godot's per-user application-data directory. No personal paths are required in source.
The MDL helper uses Python's standard library; it does not require MediaPipe or NumPy.

**Import NWN1 reference library** reads your own KEY/BIF archives and extracts local
humanoid guards, idle clips and 2H attacks/parries. It sets `pause1` as the default
idle pose. Game resources are not redistributed with the application. Until a local
idle file is configured, the original model's rest pose remains the default.

The compiler adapter currently supports the EE-aware Windows `nwnmdlcomp` build
with SHA-256 `0e32070c3e00a07a5f9e93b7e4a63a40dd5486b974900bbb8a0d2f4424c612bb`.
It verifies this hash before patching the legacy fallback-directory string in a
temporary copy. Compiler binaries are not included. Other compiler builds/platforms
need a separately validated adapter; ASCII block editing does not need a compiler.
The validation helpers are adapted from SWLOR_NWN tooling, with its MIT notice
retained in `mdl_bank/vendor/LICENSE-SWLOR.txt`.

## Editing and recovery

- **Undo / Redo** restore the pose and animation document, including keys, names,
  duration and playhead. Shortcuts: Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z.
- **Save project / Open project** use `.nwap` files. Autosave runs every 30 seconds
  after edits; **Recover autosave** restores the latest recovery document.
- Drag a timeline dot to move one key. Shift+drag moves it and subsequent keys.
  Changing **Duration** scales key times proportionally.
- Select a key in Workshop to label it or enter its time. Key labels belong to the
  project, not the NWN animation format.
- Pose-memory slots show the saved animation name above their Save/Load buttons.
  There are seven session-only slots. Save captures a pose; Open stores an animation from
  Pose Library; Load applies its first pose without replacing the working timeline.

## Preview helpers

- **Forward axis + target dummy** displays NWN +Y as Godot -Z.
- **Blade-tip trail** shows the weapon tip's path for manual inspection; it is not
  a body-collision detector.
- **DoubleStaff** previews two blades and a central grip. **Lightsaber hilt** adds
  a simple geometric hilt, centered in the hand mesh without changing bone tracks.
- Arrange both hands first, then enable **Keep left hand on right-hand grip**.
  The left hand follows the captured grip offset within the arm's IK reach.
- Place a foot on the ground before enabling its pin. Locks assist pose editing;
  playback still uses saved keys. Press **Set** to save an edited pose.
- The pose library offers thumbnails, filtering and personal pose storage.
  **Compare** shares playback and camera framing between the current animation
  and a reference. Match phases for different durations, or compare equal seconds.

## Full MDL workflow

1. **File → Open MDL bank** accepts a full ASCII or binary NWN1 model.
2. Select a local animation and choose **Load selected**.
3. Edit and save timeline keys. Open **File → MDL bank / Export compiled model**
   to save the current edit into the working bank or switch clips.
4. **Export compiled MDL** saves the complete binary model, an ASCII source
   sidecar and a validation report. Retain the model's original resource filename;
   choose a different directory for a separate copy. Existing binary output is
   backed up before replacement.

Only changed transform channels are merged into the selected animation. Other
clips, geometry, supermodel links, events and unsupported node channels are retained.
Duration changes retime that clip's events and remaining controller tracks too.
The result is decompiled and audited before the destination MDL is replaced.
Missing supermodels or failed validation stop export with an error.

Preview uses the tool's humanoid mannequin, not arbitrary MDL geometry. Models
without local clips require opening their animation supermodel. New resource names,
HAK deployment, server scripts and in-game combat-slot assignment are outside this
editor workflow. `.nwap` projects do not embed full banks: export the bank before
ending the session. Ordinary **Save animation** still exports a single ASCII block.

## Verification

```sh
python -m unittest discover -s tests -v
godot --headless --editor --import --quit
godot --headless --script res://tests/workshop_smoke.gd
```

The Python tests use synthetic models and require no game installation. The Godot
smoke test exercises counted keys, case-insensitive nodes, signed rotations,
position-only timestamps, undo/redo, named pose slots, centered hilts and foot pins.
Full binary validation additionally requires a supported compiler and locally
available model dependencies. In-game behavior must still be checked in NWN1.

Known standard male/female animation supermodels automatically select the matching preview mannequin, avoiding female neck offsets being applied to male geometry. Custom skeleton proportions remain outside the humanoid preview support.

### Joint selection and skeleton
Click an upper arm, forearm, hand, thigh, calf, or foot to rotate that joint.
Shift-click adds/removes parts from the selection; rotation rings and numeric rotation fields affect the selected roots without applying the same rotation twice to a selected descendant. Click empty space to clear selection. Alt-click a limb retains the previous whole-limb IK controls.
Skel displays the native NWN node hierarchy through the mannequin, even without an imported motion source, and follows the current pose.

Individual joints and Shift selections expose XYZ translation arrows and numeric Position fields. Image/video pose extraction requires MediaPipe and OpenCV in the configured Pose Python interpreter; the scripts are bundled in exported builds. Video extraction uses timestamped tracking.

Translation arrows on limb segments use the original whole-limb IK behavior: they move the hand/foot target while keeping all bone offsets fixed. Individual segment rotation remains available. Head and torso translation is disabled to prevent disconnected geometry.

Limb translation arrows share the selected rotation pivot. Dragging uses a fixed start pose and the stored IK pole to avoid drift. Arrow keys nudge X/Z by 0.01 units; Page Up/Down nudge Y. Typing in UI fields is unaffected, and nudges support Undo.

All / Ctrl+A selects the selectable body parts and moves/rotates the rig root once. Text fields retain their normal Ctrl+A behavior.

An optional local game-hilt preview reads `user://saberstaff/saberstaff.json` (`nodes` from the MDL node parser plus a `resource` name) and adjacent PNG textures named after the MDL bitmaps. Geometry uses original hierarchy transforms, scale and weapon attachment, with no palm-centering offset. Emitter previews use source textures, transforms and sizes as static additive cards; they do not simulate the full NWN particle lifecycle. Without local data, the procedural staff preview remains available. No game model or texture is included in the repository.

Single sabers in R.Wpn and L.Wpn load `user://lightsaber/lightsaber.json` with the same format. The complete b/m/t model parts supply emitter nodes; hidden guide geometry (`render 0`) is excluded while its transforms still position child emitters. DoubleStaff continues to use the separate saberstaff data.

Workshop > Add pose folder opens a directory picker. Custom folders are remembered across restarts; the library lists TXT/MDL animations from subfolders, supports Refresh and name filtering, and Preview animation opens and plays a selected clip. Full MDL banks open the clip-selection dialog first.

Optional local hand part 008 previews read the male/female left/right model JSON files from user://hands008. They replace only hand mesh geometry before pick-collider creation, preserving bone transforms and weapon attachments. Mannequin selection colors are retained; library thumbnails use the same meshes. No hand assets are committed.

## Additional viewport controls

Front, Back, Side Left and Side Right provide orthographic views. The compact second
row exposes Hilt, Target, Trail, Clear trail, Free R hand, T-pose, L grip and foot pins;
hover for full descriptions. Free R hand holds the weapon in world space during
editing. Set a key to retain the resulting attachment offset. T-pose supports Undo
and leaves existing keys unchanged. Numeric transforms appear above Pose Memory;
All selects the whole body, and Rotation Y = 180 turns it around.

Both hand menus offer independent local model previews, including rifle, pistol,
staff, spear, katar, shield, training sabers/staves, vibroknife, 2H Sword and DoubleStaff.
Shield uses the left forearm. The separate DoubleStaff switch has been removed.
These entries require corresponding local `user://<model>/<model>.json` files and
textures; they are not included in the repository. Standard saber/staff previews use
`user://lightsaber/lightsaber.json` and `user://saberstaff/saberstaff.json`.
Emitter-only models are accepted, with the same static-card preview limitations.

For multi-clip GLB imports, preview and Bake consistently prefer the longest non-RESET
clip with tracks rather than an alphabetically first short reference clip. This is
an automatic selection heuristic, not a guarantee of correct motion retargeting.
