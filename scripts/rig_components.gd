## Shared definition of the NWN dummy's selectable components.
## Each component is a chain of node names (matching the NWN MDL node names
## exactly) from the root of the chain down to its IK end-effector, if any.
class_name RigComponents

const PICK_LAYER := 2 # physics layer used for selection raycasts only

class ComponentDef:
	var id: String
	var chain: Array[String] # node names from root to tip, in NWN hierarchy order
	var is_ik: bool # true for limbs (two-bone IK with pole vector), false for FK-only

	func _init(p_id: String, p_chain: Array[String], p_is_ik: bool) -> void:
		id = p_id
		chain = p_chain
		is_ik = p_is_ik

static func definitions() -> Array[ComponentDef]:
	var list: Array[ComponentDef] = []
	list.append(ComponentDef.new("head", ["head_g"], false))
	list.append(ComponentDef.new("torso", ["torso_g"], false))
	list.append(ComponentDef.new("pelvis", ["pelvis_g"], false))
	list.append(ComponentDef.new("right_arm", ["rbicep_g", "rforearm_g", "rhand_g"], true))
	list.append(ComponentDef.new("left_arm", ["lbicep_g", "lforearm_g", "lhand_g"], true))
	list.append(ComponentDef.new("right_leg", ["rthigh_g", "rshin_g", "rfoot_g"], true))
	list.append(ComponentDef.new("left_leg", ["lthigh_g", "lshin_g", "lfoot_g"], true))
	# "rhand"/"lhand" are the weapon-attachment dummies NWN parents under
	# rhand_g/lhand_g (no mesh of their own) -- selectable and FK-rotatable
	# on their own so a weapon's orientation can be keyed independently of
	# the hand that's holding it.
	list.append(ComponentDef.new("right_weapon", ["rhand"], false))
	list.append(ComponentDef.new("left_weapon", ["lhand"], false))
	# "lforearm" is NWN's shield-attachment dummy (no mesh of its own),
	# parented under lforearm_g -- same idea as rhand/lhand above.
	list.append(ComponentDef.new("shield", ["lforearm"], false))
	# Individual FK joints override limb picking; Alt-click retains whole-limb IK.
	for side in ["right", "left"]:
		var prefix := "r" if side == "right" else "l"
		for part in [["upper_arm", "bicep_g"], ["forearm", "forearm_g"], ["hand", "hand_g"], ["thigh", "thigh_g"], ["calf", "shin_g"], ["foot", "foot_g"]]:
			list.append(ComponentDef.new(side + "_" + part[0], [prefix + part[1]], false))
	return list

## Maps every node name in every component chain to its component id.
static func node_to_component_map() -> Dictionary:
	var map := {}
	for comp in definitions():
		for node_name in comp.chain:
			map[node_name] = comp.id
	return map
