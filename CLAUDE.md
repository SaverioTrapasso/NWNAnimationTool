# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

A Godot 4.7 desktop tool for posing the Neverwinter Nights (NWN) IK dummy character model and exporting
the pose as a NWN MDL ASCII animation block (`newanim ... doneanim`). The user manipulates body parts
(hands, feet, head, torso, etc.) in a 3D viewport and exports the resulting transforms in NWN's animation
format so it can be merged into an NWN `.mdl` file.

This is currently a fresh, mostly-empty Godot project — no GDScript/C# source exists yet, only engine
scaffolding and the Godot editor executables in `SDK/`. Treat early work here as greenfield architecture,
not as discovery of existing patterns.

## Commands

- Run the editor: `SDK/Godot_v4.7-stable_win64.exe --editor --path .`
- Run the project (game/tool window): `SDK/Godot_v4.7-stable_win64.exe --path .`
- Run headless (e.g. for scripted checks): `SDK/Godot_v4.7-stable_win64_console.exe --headless --path .`
- There is no separate build step (GDScript is interpreted by the engine); if C# is introduced later,
  building requires the .NET-enabled Godot build (not present in `SDK/` currently — confirm before using C#).
- No test framework or lint config exists yet. If tests are added, prefer GDScript via GUT or GdUnit and
  document the run command here once chosen.

## Engine configuration notes (`project.godot`)

- Rendering method is `mobile` with the D3D12 rendering driver on Windows, and Jolt is the 3D physics
  engine — keep new 3D nodes/shaders compatible with the mobile renderer's feature set.
- `config/features` targets Godot `4.7` + `Mobile` preset.

## Architecture (planned)

The core domain concept is the NWN node hierarchy, not a generic skeleton: nodes like `rootdummy`,
`torso_g`, `pelvis_g`, `rbicep_g`, `rforearm_g`, `rhand_g`, `lthigh_g`, `lshin_g`, `lfoot_g`, etc. form a
parent chain that mirrors NWN's MDL animation format exactly (see the export format below). Any rig
representation in Godot must preserve these exact node names and parent relationships, since they are
written verbatim into the exported animation block.

Planned pieces:

1. **Character asset import** — the IK dummy is supplied by the user as glTF/GLB, with a Godot
   `Skeleton3D` whose bone names match the NWN node names above. This file is provided externally, not
   generated in this repo.
2. **Viewport interaction / selection** — mouse picking in the 3D viewport to select a body component
   (bone). Selection drives which part is currently being posed.
3. **Posing**
   - Pelvis, torso, neck/head: forward kinematics (FK) — direct bone rotation, no special solver.
   - Hands and feet: inverse kinematics (IK) with pole vectors for the elbow/knee joints (i.e. a two-bone
     IK chain: bicep→forearm→hand, thigh→shin→foot), so dragging a hand/foot target also bends the
     elbow/knee plausibly.
4. **Side panel UI** — text field for the animation name, and a Save button. The animation name field
   feeds the `newanim <name> a_ba_non_combat` line; the parent animation is always the fixed NWN asset
   `a_ba_non_combat`.
5. **Exporter** — serializes the current pose of every relevant node to the NWN MDL ASCII format on Save.

### Export format (NWN MDL ASCII)

Output is a single static pose (one keyframe at time `0.0`, `length 1.0`, `transtime 0.25`), structured as:

```
newanim <user-entered name> a_ba_non_combat
  length 1.0
  transtime 0.25
  animroot rootdummy
    node dummy a_ba_non_combat
        parent NULL
    endnode
    node trimesh rootdummy
        parent a_ba_non_combat
        positionkey
            0.0 <x> <y> <z>
        endlist
        orientationkey
            0.0 0.0 0.0 0.0 0.0
        endlist
    endnode
    node trimesh <bone_name>
        parent <parent_bone_name>
        orientationkey
            0.0 <x> <y> <z> <angle>
        endlist
    endnode
    ... (one node block per posed bone, in the fixed NWN hierarchy order)
doneanim <user-entered name> a_ba_non_combat
```

Key points for the exporter:

- Orientation keys are axis-angle (`x y z angle`), not quaternions — converting from Godot's quaternion
  rotations to this `x y z angle` form is required.
- `rootdummy` carries a `positionkey` in addition to its `orientationkey`; other nodes only emit
  `orientationkey`.
- Node order and the full bone list (including non-deforming dummies like `rhand`, `lforearm`, `Impact`)
  must match NWN's fixed skeleton structure, not just the bones the user actually moved — unmoved bones
  still need an entry if NWN's format requires the full hierarchy (verify against the sample block before
  trimming any nodes).
- Each node's `<bone_name>` and `<parent_bone_name>` must exactly match the NWN naming convention (e.g.
  `torso_g`, `rbicep_g`, `rforearm_g`, `rhand_g`, `pelvis_g`, `lthigh_g`, `lshin_g`, `lfoot_g`) — these are
  fixed identifiers from the NWN model format, not arbitrary Godot node names.
