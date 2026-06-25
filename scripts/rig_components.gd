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
	return list

## Maps every node name in every component chain to its component id.
static func node_to_component_map() -> Dictionary:
	var map := {}
	for comp in definitions():
		for node_name in comp.chain:
			map[node_name] = comp.id
	return map
