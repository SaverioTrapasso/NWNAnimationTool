extends SceneTree
const Reducer = preload("res://scripts/pose_reducer.gd")
func _initialize() -> void:
	var keys: Array = []
	for i in 97:
		var pose := Transform3D.IDENTITY
		pose.origin.x = 1.0 if i == 37 else 0.0
		keys.append({"time":i*.1,"transforms":{"rootdummy":pose}})
	var reduced := Reducer.reduce_keys(keys,12)
	assert(reduced.size() <= 12)
	assert(reduced.front().time == keys.front().time and reduced.back().time == keys.back().time)
	assert(reduced.any(func(key):return key.time == keys[37].time))
	assert(keys.size() == 97)
	reduced[0].time = -1
	assert(keys[0].time == 0)
	for i in 97:
		keys[i].transforms.rootdummy = Transform3D(Basis(Vector3.UP,.7 if i==53 else 0.0),Vector3.ZERO)
	reduced = Reducer.reduce_keys(keys,8)
	assert(reduced.any(func(key):return key.time == keys[53].time))
	print("POSE_REDUCER_OK endpoints, position peak, rotation peak, independent copies")
	quit()
