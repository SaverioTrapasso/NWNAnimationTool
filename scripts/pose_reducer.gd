extends RefCounted

# Split the interval with the largest interpolation error, retaining endpoints.
static func reduce_keys(keys: Array, limit: int) -> Array:
	limit = maxi(2, limit)
	if keys.size() <= limit: return keys.duplicate(true)
	var selected: Array[int] = [0, keys.size()-1]
	while selected.size() < limit:
		var worst := -1.0
		var pick := -1
		for interval in range(selected.size()-1):
			var a: int = selected[interval]
			var b: int = selected[interval+1]
			var duration: float = keys[b].time - keys[a].time
			if duration <= 0: continue
			for i in range(a+1,b):
				var weight: float = (keys[i].time-keys[a].time)/duration
				var error := 0.0
				for bone in keys[i].transforms:
					if not keys[a].transforms.has(bone) or not keys[b].transforms.has(bone): continue
					var left: Transform3D = keys[a].transforms[bone]
					var right: Transform3D = keys[b].transforms[bone]
					var actual: Transform3D = keys[i].transforms[bone]
					var rotation := left.basis.get_rotation_quaternion().slerp(right.basis.get_rotation_quaternion(),weight)
					error = maxf(error, actual.origin.distance_to(left.origin.lerp(right.origin,weight))/.01)
					error = maxf(error, actual.basis.get_rotation_quaternion().angle_to(rotation)/deg_to_rad(5))
				if error > worst:
					worst = error
					pick = i
		if pick < 0 or worst < .0001: break
		selected.append(pick)
		selected.sort()
	var result: Array = []
	for index in selected: result.append(keys[index].duplicate(true))
	return result
