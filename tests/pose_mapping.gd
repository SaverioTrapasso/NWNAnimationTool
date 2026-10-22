extends SceneTree

const Mapper = preload("res://scripts/ai_pose_applier.gd")
var errors: Array[String] = []
func check(value: bool, label: String) -> void:
	if not value: errors.append(label); push_error(label)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var app = load("res://scenes/Main.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var rig = app.get_node("Rig")
	var points: Array[Vector3] = []
	points.resize(33)
	points.fill(Vector3.ZERO)
	points[23] = Vector3(-.15,1,0); points[24] = Vector3(.15,1,0)
	points[11] = Vector3(-.2,1.5,.15); points[12] = Vector3(.2,1.5,-.15)
	points[7] = Vector3(-.1,1.8,0); points[8] = Vector3(.1,1.8,0)
	points[25] = Vector3(-.15,.5,0); points[26] = Vector3(.15,.5,0)
	points[27] = Vector3(-.15,.1,0); points[28] = Vector3(.15,.1,0)
	points[29] = Vector3(-.15,0,-.1); points[30] = Vector3(.15,0,-.1)
	points[31] = Vector3(-.15,0,.15); points[32] = Vector3(.15,0,.15)
	var landmarks: Array = []
	for point in points: landmarks.append({"x":-point.x,"y":-point.y,"z":point.z,"visibility":1.0})
	var data = Mapper.compute(landmarks,rig,1.0,Vector3.ZERO)
	var image_points := landmarks.duplicate(true)
	for i in image_points.size():
		image_points[i].image_x = float(i % 5) / 10.0
		image_points[i].image_y = float(i) / 40.0
	image_points[13].visibility = .3
	var side = Mapper.side_image_landmarks(image_points)
	var factor: float = (side[15].x-side[11].x)/(image_points[15].image_x-image_points[11].image_x)
	check(abs((side[15].y-side[11].y)-(image_points[15].image_y-image_points[11].image_y)*factor)<.0001,"Side mode retains image proportions in X and Y")
	check(side[15].z==image_points[15].z,"Side mode keeps estimated depth")
	check(Mapper.compute(side,rig,1.0,Vector3.ZERO,Quaternion.IDENTITY,{},true,Transform3D.IDENTITY,.25).ik_targets.has("left_arm"),"Side mode includes partially hidden elbow")
	check(not Mapper.compute(side,rig,1.0,Vector3.ZERO).ik_targets.has("left_arm"),"Default confidence stays conservative")
	var turn := Quaternion(Vector3.FORWARD, .17)
	var source := Transform3D(Basis(Vector3.UP,.4).scaled(Vector3.ONE*1.2),Vector3(.1,.2,.3))
	var preview := Mapper.landmark_positions(landmarks,1.3,Vector3.UP,turn,true,source,.5)
	var transformed = Mapper.compute(landmarks,rig,1.3,Vector3.UP,turn,{},true,source)
	check(preview[28].distance_to(transformed.ik_targets.right_leg.target + Vector3.UP*.5)<.0001,"Preview foot matches IK including tilt, scale, source transform and foot offset")
	check(preview[24].distance_to(Mapper.landmark_positions(landmarks,1.3,Vector3.UP,turn,true,source)[24])<.0001,"Feet offset does not move pelvis overlay")
	for name in data.fk_rotations: app.rig_controller.find_node(name).quaternion = data.fk_rotations[name]
	var torso = app.rig_controller.find_node("torso_g")
	var expected := (points[12]-points[11]).normalized()
	check(torso.global_basis.orthonormalized().x.distance_to(expected)<.001,"Torso follows shoulders independently of hips")
	check(app.rig_controller.find_node("head_g").global_basis.orthonormalized().x.distance_to(Vector3.RIGHT)<.001,"Head uses updated torso orientation")
	var repeated = Mapper.compute(landmarks,rig,1.0,Vector3.ZERO)
	for name in repeated.fk_rotations: app.rig_controller.find_node(name).quaternion = repeated.fk_rotations[name]
	check(torso.global_basis.orthonormalized().x.distance_to(expected)<.001,"Repeated image application does not accumulate rotation")
	for basis in data.end_world_bases.values(): check(abs(basis.determinant()-1.0)<.001,"End basis is a proper rotation, not reflection")
	check(not data.end_world_bases.has("rhand_g"),"Degenerate hand landmarks are ignored")
	var collapsed: Array[Vector3] = []
	collapsed.resize(33); collapsed.fill(Vector3.ZERO)
	check(Mapper._foot_conv_basis(collapsed, landmarks.map(func(_v):return 1.0),30,32,26,28)==null,"Degenerate feet are ignored")
	var ratios := Mapper.estimate_scale(landmarks,rig)
	landmarks[11].x = 1000.0
	landmarks[11].visibility = 0.0
	check(is_finite(Mapper.estimate_scale(landmarks,rig)) and ratios>0,"Occluded shoulder does not explode scale")
	print("POSE_MAPPING failures=",errors.size())
	quit(0 if errors.is_empty() else 1)
