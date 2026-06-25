## Two-bone IK solver (root -> mid -> end), with a pole vector controlling
## the bend direction (elbow/knee). Operates on the existing Node3D
## hierarchy directly: root_node.basis / mid_node.basis are local rotations
## relative to their parent, which is exactly what gets exported as the
## NWN orientationkey for that node.
class_name IKSolver

## Solves the chain in place by mutating root_node.basis and mid_node.basis.
static func solve_two_bone(root_node: Node3D, mid_node: Node3D, end_node: Node3D, target_pos: Vector3, pole_pos: Vector3) -> void:
	var local_axis_root: Vector3 = mid_node.position.normalized()
	var local_axis_mid: Vector3 = end_node.position.normalized()
	var upper_len: float = mid_node.position.length()
	var lower_len: float = end_node.position.length()
	if upper_len < 0.0001 or lower_len < 0.0001:
		return

	var root_pos: Vector3 = root_node.global_position
	# Captured before any rotation is applied, so the end effector's world
	# orientation can be preserved against the parent chain rotating under it.
	var old_end_global_basis: Basis = end_node.global_basis

	var to_target: Vector3 = target_pos - root_pos
	var max_reach: float = upper_len + lower_len - 0.001
	var dist: float = clamp(to_target.length(), 0.001, max_reach)
	var dir_to_target: Vector3 = to_target.normalized() if to_target.length() > 0.0001 else Vector3.FORWARD

	var pole_offset: Vector3 = pole_pos - root_pos
	var pole_dir: Vector3 = pole_offset - dir_to_target * pole_offset.dot(dir_to_target)
	if pole_dir.length() < 0.0001:
		pole_dir = dir_to_target.cross(Vector3.UP)
		if pole_dir.length() < 0.0001:
			pole_dir = dir_to_target.cross(Vector3.RIGHT)
	pole_dir = pole_dir.normalized()

	var bend_axis: Vector3 = dir_to_target.cross(pole_dir)
	if bend_axis.length() < 0.0001:
		bend_axis = Vector3.UP
	bend_axis = bend_axis.normalized()

	var cos_a: float = (upper_len * upper_len + dist * dist - lower_len * lower_len) / (2.0 * upper_len * dist)
	var angle_a: float = acos(clamp(cos_a, -1.0, 1.0))
	var upper_dir_world: Vector3 = dir_to_target.rotated(bend_axis, angle_a)

	var mid_pos_new: Vector3 = root_pos + upper_dir_world * upper_len
	var clamped_target_pos: Vector3 = root_pos + dir_to_target * dist
	var lower_dir_world: Vector3 = (clamped_target_pos - mid_pos_new).normalized()

	# Apply root rotation: rotate root's current segment direction onto the desired world direction.
	var root_parent: Node3D = root_node.get_parent()
	var root_parent_basis: Basis = root_parent.global_basis if root_parent is Node3D else Basis()
	var desired_local_dir_root: Vector3 = (root_parent_basis.inverse() * upper_dir_world).normalized()
	var current_dir_root: Vector3 = (root_node.basis * local_axis_root).normalized()
	var q_root := Quaternion(current_dir_root, desired_local_dir_root)
	root_node.basis = Basis(q_root) * root_node.basis

	# Mid's parent is root_node itself, whose global_basis now reflects the update above.
	var desired_local_dir_mid: Vector3 = (root_node.global_basis.inverse() * lower_dir_world).normalized()
	var current_dir_mid: Vector3 = (mid_node.basis * local_axis_mid).normalized()
	var q_mid := Quaternion(current_dir_mid, desired_local_dir_mid)
	mid_node.basis = Basis(q_mid) * mid_node.basis

	# Keep the hand/foot's world-space orientation fixed (it shouldn't
	# inherit the bicep/forearm's rotation): re-derive its local basis so
	# that, combined with mid_node's NEW global basis, it reproduces the
	# exact same global orientation it had before this solve step. Any
	# manual rotation the user applies via the gizmo updates that reference
	# orientation for the next frame, since it changes end_node's basis
	# directly between solve calls.
	end_node.basis = mid_node.global_basis.inverse() * old_end_global_basis
