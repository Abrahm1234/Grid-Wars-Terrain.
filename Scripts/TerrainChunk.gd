extends Node3D
class_name TerrainChunk

var lod_meshes: Array[MeshInstance3D] = []
var current_lod := -1
var chunk_size := 0.0
var lod_resolutions: PackedInt32Array
var shared_material: ShaderMaterial
var _skirt_depth := 2.0
var _max_height := 20.0   # from shader's height_scale

var _fade_tween: Tween

func setup(_chunk_size: float, _lod_res: PackedInt32Array, _material: ShaderMaterial) -> void:
	setup_internal(_chunk_size, _lod_res, _material, 2.0)

func setup_with_skirt(_chunk_size: float, _lod_res: PackedInt32Array, _material: ShaderMaterial, skirt_depth: float = 2.0) -> void:
	setup_internal(_chunk_size, _lod_res, _material, skirt_depth)

func setup_internal(_chunk_size: float, _lod_res: PackedInt32Array, _material: ShaderMaterial, skirt_depth: float) -> void:
	chunk_size = _chunk_size
	lod_resolutions = _lod_res
	shared_material = _material
	_skirt_depth = skirt_depth

	if shared_material:
		var hs_param: Variant = shared_material.get_shader_parameter("height_scale")
		if hs_param is float:
			_max_height = hs_param
		elif hs_param is int:
			_max_height = float(hs_param)

	lod_meshes.clear()

	for res in lod_resolutions:
		var grid := _make_grid_with_skirt(chunk_size, res, _skirt_depth, _max_height)
		var mi := MeshInstance3D.new()
		mi.mesh = grid
		mi.material_override = shared_material
		mi.visible = false
		mi.extra_cull_margin = (_max_height * 1.2) + _skirt_depth
		mi.set_instance_shader_parameter("lod_fade", 1.0)
		add_child(mi)
		lod_meshes.append(mi)

	set_lod(0)

func set_lod(level: int) -> void:
	level = clamp(level, 0, lod_meshes.size() - 1)
	if level == current_lod: return

	var prev := current_lod
	current_lod = level

	if _fade_tween: _fade_tween.kill()
	_fade_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	var mi_in := lod_meshes[level]
	mi_in.visible = true
	mi_in.set_instance_shader_parameter("lod_fade", 0.0)
	_fade_tween.tween_method(func(v): mi_in.set_instance_shader_parameter("lod_fade", v), 0.0, 1.0, 0.15)

	if prev >= 0:
		var mi_out := lod_meshes[prev]
		_fade_tween.tween_method(func(v): mi_out.set_instance_shader_parameter("lod_fade", 1.0 - v), 0.0, 1.0, 0.15)
		_fade_tween.tween_callback(Callable(mi_out, "set_visible").bind(false))
		_fade_tween.tween_callback(func(): mi_out.set_instance_shader_parameter("lod_fade", 1.0))

func _make_grid_with_skirt(size: float, res: int, skirt_depth: float = 2.0, max_height: float = 20.0) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var uvs   := PackedVector2Array()
	var uv2s  := PackedVector2Array()   # UV2.x = 1.0 for skirt verts
	var indices := PackedInt32Array()

	var steps := res
	var step := size / steps
	var half := size * 0.5

	# top surface
	for z in range(steps + 1):
		for x in range(steps + 1):
			var vx := -half + x * step
			var vz := -half + z * step
			verts.append(Vector3(vx, 0.0, vz))
			uvs.append(Vector2(float(x) / steps, float(z) / steps))
			uv2s.append(Vector2(0.0, 0.0)) # not skirt

	for z in range(steps):
		for x in range(steps):
			var i0 :=  (z    ) * (steps + 1) + x
			var i1 :=  (z    ) * (steps + 1) + x + 1
			var i2 :=  (z + 1) * (steps + 1) + x
			var i3 :=  (z + 1) * (steps + 1) + x + 1
			indices.append_array([i0, i1, i2,  i1, i3, i2])

	# border ring indices of the top grid
	var border: Array[int] = []
	for x in range(steps + 1): border.append(x)
	for z in range(1, steps): border.append(z * (steps + 1) + steps)
	for x in range(steps, -1, -1): border.append(steps * (steps + 1) + x)
	for z in range(steps - 1, 0, -1): border.append(z * (steps + 1))

	# duplicate ring downward -> skirt, flag UV2.x = 1.0
	var base := verts.size()
	for i in border:
		var v := verts[i]
		verts.append(Vector3(v.x, v.y - skirt_depth, v.z))
		uvs.append(uvs[i])                  # reuse UV for sampling
		uv2s.append(Vector2(1.0, 0.0))      # mark as skirt

	# vertical quads around edge
	for j in range(border.size()):
		var iA: int = border[j]
		var iB: int = border[(j + 1) % border.size()]
		var kA := base + j
		var kB := base + ((j + 1) % border.size())
		indices.append_array([iA, kA, iB,  iB, kA, kB])

	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s         # send skirt flag to shader
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	mesh.custom_aabb = AABB(Vector3(-half, -skirt_depth, -half), Vector3(size, max_height + skirt_depth, size))
	return mesh
