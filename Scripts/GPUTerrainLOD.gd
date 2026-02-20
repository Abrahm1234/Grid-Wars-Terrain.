@tool
extends Node3D

# ----------------------------- Terrain & LOD -----------------------------
@export var chunk_size: float = 2000.0
@export var grid_size: int = 25
@export var height_scale: float = 3000.0

@export var lod_resolutions: PackedInt32Array = PackedInt32Array([256, 128, 64])
@export var lod_distances: PackedFloat32Array = PackedFloat32Array([])
@export var lod_hysteresis: float = 0.10

# ----------------------------- Visuals -----------------------------------
@export var normal_sample: float = 0.6
@export var skirt_depth: float = 2.0
@export var albedo_tex: Texture2D
@export var albedo_tiling: float = 0.15
@export var triplanar_sharpness: float = 4.0
@export var triplanar_hard: bool = false
@export var use_top_side_split: bool = true
@export var top_side_threshold: float = 0.55
@export var show_biome_map: bool = true
@export var use_biome_textures: bool = false
@export var biome_texture_array: Texture2DArray
@export var biome_texture_tiling: float = 0.25
@export_range(1, 8, 1) var biome_layers_per_biome: int = 3
@export var biome_blend_width: float = 0.32
@export var biome_layer_assignments: PackedInt32Array = PackedInt32Array([])

# Optional: helper node that builds a ShaderMaterial for TerrainDisplace.gdshader
@export var surface_binder_path: NodePath

# ----------------------------- Bake / Erosion ----------------------------
@export var do_offline_erosion: bool = true
@export var erosion_iterations: int = 2000
@export var load_if_exists: bool = true
@export var auto_save_height_png: bool = true
@export var save_height_path: String = "user://maps/height_baked.png"
@export var erosion_zones: Array[ErosionZoneConfig] = []

@export var er_dt: float = 0.10
@export var er_rain: float = 0.001
@export var er_evap: float = 0.001
@export var er_Ks: float = 0.05
@export var er_Kd: float = 0.05
@export var er_Kc: float = 1.0
@export var er_min_sin: float = 0.02
@export var er_pipe_A: float = 1.0
@export var er_iters_per_submit: int = 256
@export var auto_stamp_enabled := true
@export_range(10.0, 10000.0, 10.0) var river_A_min := 800.0
@export_range(0.0, 2.0, 0.01) var river_slope_min := 0.02
@export_range(0.0, 2.0, 0.01) var river_slope_max := 0.25
@export_range(100.0, 20000.0, 10.0) var fan_A_min := 3000.0
@export_range(0.0, 2.0, 0.01) var fan_steep_min := 0.35
@export_range(0.0, 2.0, 0.01) var fan_gentle_max := 0.12
@export_range(0.0, 2.0, 0.01) var gully_slope_min := 0.50
@export_range(0.0, 1000.0, 1.0) var gully_A_max := 80.0
@export_range(0.0, 1.0, 0.01) var gully_moist_max := 0.35
@export var auto_river_radius_m := 24.0
@export var auto_river_feather_m := 12.0
@export var auto_fan_radius_m := 160.0
@export var auto_fan_feather_m := 60.0
@export var auto_gully_radius_m := 22.0
@export var auto_gully_feather_m := 10.0

# ----------------------------- Red-blob generation -----------------------
@export var seed_noise_size: Vector2i = Vector2i(1024, 1024)
@export var seed_noise_frequency: float = 2.0
@export var moisture_frequency: float = 2.0
@export var octave_weights: PackedFloat32Array = PackedFloat32Array([1.0, 0.5, 0.25, 0.125, 0.0625])
@export var elevation_exponent: float = 5.0
@export var elevation_fudge: float = 1.2
@export var island_mode: int = 1
@export var island_mix: float = 0.5
@export var use_fixed_seed: bool = true
@export var fixed_seed: int = 12345

# Camera (optional; falls back to viewport camera)
@export var camera_path: NodePath

# ----------------------------- State -------------------------------------
var shared_material: ShaderMaterial
var chunks: Array = []                 # holds TerrainChunk instances
var cam: Camera3D
var _height_image: Image
var _moist_image: Image
var _biome_color_image: Image
var _biome_index_image: Image
var _biome_color_texture: Texture2D
var _biome_index_texture: Texture2D
var _rng_seed_used: int = 0
var _effective_layers_per_biome: int = 1

# Local preloads (short aliases to avoid class_name shadow warnings)
const TRB := preload("res://Scripts/terrain_redblob.gd")
const MAX_SHADER_BIOMES := 16
const SHADER_PATH := "res://Shaders/TerrainDisplace.gdshader"

# ========================================================================
# Public helpers
# ========================================================================
func get_seed() -> int:
	return fixed_seed if use_fixed_seed else int(randi())

func get_world_rect() -> Rect2:
	var total := Vector2(chunk_size * grid_size, chunk_size * grid_size)
	return Rect2(-total * 0.5, total)

func get_map_resolution() -> Vector2i:
	if _height_image and not _height_image.is_empty():
		return Vector2i(_height_image.get_width(), _height_image.get_height())
	return seed_noise_size

func get_texel_world_size() -> Vector2:
	var res := get_map_resolution()
	var sz := get_world_rect().size
	return Vector2(sz.x / max(1, res.x - 1), sz.y / max(1, res.y - 1))

# ========================================================================
# Lifecycle
# ========================================================================
func _ready() -> void:
	_ensure_camera()
	_ensure_lod_distances()

	shared_material = _create_shader_material()
	_apply_common_uniforms(shared_material)
	_apply_biome_uniforms(shared_material)

	# Load/bake heightmap (optional)
	var baked_tex: Texture2D = null
	if do_offline_erosion and load_if_exists and FileAccess.file_exists(save_height_path):
		var img := Image.new()
		if img.load(save_height_path) == OK:
			_height_image = img
			baked_tex = ImageTexture.create_from_image(img)

	if do_offline_erosion and baked_tex == null:
		baked_tex = _bake_hydraulic_erosion()

	if baked_tex:
		shared_material.set_shader_parameter("heightmap", baked_tex)
		_generate_biome_layers()
		_apply_biome_uniforms(shared_material)

	# Build chunk grid
	var half := (grid_size - 1) * 0.5
	for gx in range(grid_size):
		for gz in range(grid_size):
			var cx := (gx - half) * chunk_size
			var cz := (gz - half) * chunk_size
			var chunk := TerrainChunk.new()      # uses class_name from TerrainChunk.gd
			add_child(chunk)
			chunk.position = Vector3(cx, 0.0, cz)
			chunk.setup_with_skirt(chunk_size, lod_resolutions, shared_material, skirt_depth)
			chunks.append(chunk)

	set_process(true)

func _process(_dt: float) -> void:
	if cam == null:
		_ensure_camera()
		if cam == null:
			return

	# typed locals to avoid Variant inference
	for c in chunks:
		var tc: TerrainChunk = c
		var d: Vector3 = cam.global_transform.origin - tc.global_transform.origin
		var dist: float = sqrt(d.x * d.x + d.z * d.z)

		# Select LOD band
		var target: int = 0
		for i in range(lod_distances.size() - 1):
			if dist >= lod_distances[i] and dist < lod_distances[i + 1]:
				target = i
				break

		# Hysteresis
		var cur: int = tc.current_lod
		if cur >= 0 and target != cur:
			if target > cur:
				if dist < lod_distances[target] * (1.0 + lod_hysteresis):
					target = cur
			else:
				if dist > lod_distances[cur] * (1.0 - lod_hysteresis):
					target = cur

		tc.set_lod(target)

# ========================================================================
# Material / shader wiring
# ========================================================================
func _create_shader_material() -> ShaderMaterial:
	# Generate red-blob fields
	var rng_seed := get_seed()
	_rng_seed_used = rng_seed
	var fields := TRB.gen_fields(
		seed_noise_size, rng_seed,
		seed_noise_frequency, moisture_frequency,
		octave_weights, elevation_exponent, elevation_fudge,
		island_mode, island_mix
	)
	_height_image = fields["elev"]
	_moist_image  = fields["moist"]
	_generate_biome_layers()

	# If a TerrainSurfaceBinder node is provided, let it create the material
	var binder := _get_surface_binder()
	if binder and binder.has_method("create_material_from_images"):
		var mat_from_binder: ShaderMaterial = binder.create_material_from_images(
			_height_image, _moist_image, get_world_rect(), height_scale, show_biome_map
		)
		_apply_biome_uniforms(mat_from_binder)
		return mat_from_binder

	# Fallback: direct material
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_PATH)

	# Push heightmap
	if _height_image and not _height_image.is_empty():
		mat.set_shader_parameter("heightmap", ImageTexture.create_from_image(_height_image))

	_apply_biome_uniforms(mat)

	return mat

func _apply_common_uniforms(mat: ShaderMaterial) -> void:
	var r := get_world_rect()
	mat.set_shader_parameter("height_scale", height_scale)
	mat.set_shader_parameter("terrain_size", r.size)
	mat.set_shader_parameter("terrain_origin", r.position)
	mat.set_shader_parameter("skirt_depth", skirt_depth)
	mat.set_shader_parameter("normal_sample", normal_sample)
	mat.set_shader_parameter("albedo_tiling", albedo_tiling)
	mat.set_shader_parameter("triplanar_sharpness", max(1.0, triplanar_sharpness))
	mat.set_shader_parameter("triplanar_hard", triplanar_hard)
	mat.set_shader_parameter("use_top_side_split", use_top_side_split)
	mat.set_shader_parameter("top_side_threshold", clamp(top_side_threshold, 0.0, 1.0))

# ========================================================================
# Biome helpers
# ========================================================================
func _should_use_biome_textures() -> bool:
	return use_biome_textures and biome_texture_array != null

func _generate_biome_layers() -> void:
	if _height_image == null or _moist_image == null:
		_biome_color_image = null
		_biome_index_image = null
		_biome_color_texture = null
		_biome_index_texture = null
		return

	var layers := TRB.make_biome_layers(_height_image, _moist_image)
	_biome_color_image = layers.get("color", null)
	_biome_index_image = layers.get("index", null)

	if _biome_color_image is Image:
		_biome_color_texture = ImageTexture.create_from_image(_biome_color_image)
	else:
		_biome_color_texture = null

	if _biome_index_image is Image:
		_biome_index_texture = ImageTexture.create_from_image(_biome_index_image)
	else:
		_biome_index_texture = null

func _apply_biome_uniforms(mat: ShaderMaterial) -> void:
	if mat == null:
		return

	if _biome_color_texture != null:
		mat.set_shader_parameter("biome_map", _biome_color_texture)
	if _biome_index_texture != null:
		mat.set_shader_parameter("biome_index_map", _biome_index_texture)
		mat.set_shader_parameter("biome_index_linear", _biome_index_texture)
	mat.set_shader_parameter("biome_blend_width", clampf(biome_blend_width, 0.0, 0.5))

	var biome_total: int = TRB.get_biome_count()
	var requested_step: int = max(1, biome_layers_per_biome)
	_effective_layers_per_biome = requested_step
	mat.set_shader_parameter("use_top_side_split", use_top_side_split)
	mat.set_shader_parameter("top_side_threshold", clamp(top_side_threshold, 0.0, 1.0))
	var biome_tex_active := _should_use_biome_textures() and _biome_index_texture != null
	var layer_count := 0
	if biome_tex_active:
		layer_count = biome_texture_array.get_layers()
		if layer_count <= 0:
			biome_tex_active = false
		else:
			var required_layers: int = requested_step * biome_total
			if layer_count < required_layers:
				push_warning("Biome texture array has %d layers but %d biomes x %d layers/biome need %d. Falling back to 1 layer per biome." % [
					layer_count, biome_total, requested_step, required_layers
				])
				_effective_layers_per_biome = 1
			if layer_count < biome_total:
				push_warning("Biome texture array has %d layers but %d biomes are defined. Some biomes will share textures." % [
					layer_count, biome_total
				])
	if not biome_tex_active:
		_effective_layers_per_biome = min(_effective_layers_per_biome, requested_step)
	mat.set_shader_parameter("biome_layers_per_biome", float(_effective_layers_per_biome))
	var show_overlay := show_biome_map and not biome_tex_active and _biome_color_texture != null

	mat.set_shader_parameter("use_biome_textures", biome_tex_active)
	mat.set_shader_parameter("use_biome_map", show_overlay)
	mat.set_shader_parameter("biome_texture_tiling", biome_texture_tiling)
	mat.set_shader_parameter("biome_count", float(biome_total))

	if biome_tex_active:
		mat.set_shader_parameter("biome_texture_array", biome_texture_array)
		mat.set_shader_parameter("biome_texture_count", float(layer_count))
		mat.set_shader_parameter("biome_layer_table", _build_biome_layer_table(layer_count))
	else:
		mat.set_shader_parameter("biome_texture_count", 0.0)
		mat.set_shader_parameter("biome_layer_table", _build_biome_layer_table(0))

	var allow_albedo := albedo_tex != null and not show_overlay and not biome_tex_active
	mat.set_shader_parameter("use_albedo", allow_albedo)
	if albedo_tex:
		mat.set_shader_parameter("albedo_tex", albedo_tex)

func _build_biome_layer_table(layer_count: int) -> PackedFloat32Array:
	var table := PackedFloat32Array()
	var biome_order: Array = TRB.get_biome_order()
	var max_layer: int = max(0, layer_count - 1)

	for i in range(MAX_SHADER_BIOMES):
		var value := 0.0
		if i < biome_order.size():
			var assignment := _get_layer_assignment(i, max_layer)
			value = float(assignment)
		table.append(value)

	return table

func _get_layer_assignment(index: int, max_layer: int) -> int:
	var layer := 0
	if biome_layer_assignments.size() > index:
		layer = biome_layer_assignments[index]
	else:
		var step: int = max(1, _effective_layers_per_biome)
		layer = index * step

	return clamp(layer, 0, max_layer)

# ========================================================================
# Erosion bake (optional)
# ========================================================================
func _bake_hydraulic_erosion() -> Texture2D:
	print("ENTER _bake_hydraulic_erosion, iters=", erosion_iterations)
	if _height_image == null or _height_image.is_empty():
		return null

	var er := preload("res://Scripts/Hydraulic Erosion Simulation Research Paper/hydraulic_erosion.gd").new()
	add_child(er)

	er.height_to_meters = height_scale
	er.init_from_image(_height_image)
	if not er.is_ready():
		push_warning("Erosion: compute not ready (shader/device). Keeping procedural height.")
		er.queue_free()
		return null
	var ws := get_texel_world_size()
	er.dx = ws.x
	er.dy = ws.y

	er.dt = er_dt
	er.rain_intensity = er_rain
	er.Ke = er_evap
	er.Ks = er_Ks
	er.Kd = er_Kd
	er.Kc = er_Kc
	er.min_slope_sin = er_min_sin
	er.iters_per_submit = er_iters_per_submit
	er.pipe_A = er_pipe_A

	er.reset_control_maps()
	_auto_stamp_erosion(er)
	if not erosion_zones.is_empty():
		var rect := get_world_rect()
		for zone in erosion_zones:
			if zone is ErosionZoneConfig and zone.enabled:
				er.stamp_preset_circle_world(zone.center_xz, zone.radius_m, zone.feather_m, zone.preset, rect.position, rect.size)
	er.upload_control_maps()
	print("ER call — iters:", erosion_iterations)
	er.simulate_offline(erosion_iterations)
	if not er.has_bake_result():
		print("ER: no bake data (skip swap)")
		push_warning("Erosion bake produced no data; keeping procedural height.")
		er.queue_free()
		return null
	var tex: Texture2D = er.get_height_texture()
	if tex == null:
		push_warning("Erosion returned null texture; keeping procedural height.")
		er.queue_free()
		return null
	if shared_material is ShaderMaterial:
		var mat: ShaderMaterial = shared_material
		mat.set_shader_parameter("heightmap", tex)
	_height_image = er.get_height_image()
	if auto_save_height_png:
		_ensure_user_dir(save_height_path)
		er.save_height_png(save_height_path)

	er.queue_free()
	return tex

func _px_to_world(p: Vector2i) -> Vector2:
	var r: Rect2 = get_world_rect()
	var res: Vector2i = get_map_resolution()
	var u: float = float(p.x) / max(1, res.x - 1)
	var v: float = float(p.y) / max(1, res.y - 1)
	return Vector2(r.position.x + u * r.size.x, r.position.y + v * r.size.y)

func _calc_slope_tan(img: Image, dx: float, dy: float) -> Image:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var src: Image = img
	if src.is_compressed():
		src = src.duplicate()
		src.decompress()
	var data: PackedFloat32Array = src.get_data().to_float32_array()
	var out: Image = Image.create(w, h, false, Image.FORMAT_RF)
	var buffer: PackedFloat32Array = PackedFloat32Array()
	buffer.resize(w * h)
	for y in range(h):
		var ym: int = max(y - 1, 0)
		var yp: int = min(y + 1, h - 1)
		var row: int = y * w
		var rowm: int = ym * w
		var rowp: int = yp * w
		for x in range(w):
			var xm: int = max(x - 1, 0)
			var xp: int = min(x + 1, w - 1)
			var dzdx: float = (data[row + xp] - data[row + xm]) / (2.0 * dx)
			var dzdy: float = (data[rowp + x] - data[rowm + x]) / (2.0 * dy)
			buffer[row + x] = sqrt(dzdx * dzdx + dzdy * dzdy)
	out.set_data(w, h, false, Image.FORMAT_RF, buffer.to_byte_array())
	return out

func _calc_flow_accum_d8(img: Image) -> Image:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var src: Image = img
	if src.is_compressed():
		src = src.duplicate()
		src.decompress()
	var heights: PackedFloat32Array = src.get_data().to_float32_array()
	var count: int = w * h
	var direction: PackedInt32Array = PackedInt32Array()
	direction.resize(count)
	direction.fill(-1)
	var accum: PackedFloat32Array = PackedFloat32Array()
	accum.resize(count)
	accum.fill(1.0)
	var offsets: Array[Vector2i] = [
		Vector2i(-1, 0),
		Vector2i(1, 0),
		Vector2i(0, -1),
		Vector2i(0, 1),
		Vector2i(-1, -1),
		Vector2i(1, -1),
		Vector2i(-1, 1),
		Vector2i(1, 1),
	]
	for y in range(h):
		for x in range(w):
			var idx: int = y * w + x
			var best_h: float = heights[idx]
			var best: int = -1
			for o in offsets:
				var nx: int = x + o.x
				var ny: int = y + o.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var neighbor_idx: int = ny * w + nx
				if heights[neighbor_idx] < best_h:
					best_h = heights[neighbor_idx]
					best = neighbor_idx
			direction[idx] = best
	var order: Array[int] = []
	order.resize(count)
	for i in range(count):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		return heights[a] > heights[b])
	for idx in order:
		var downstream: int = direction[idx]
		if downstream >= 0:
			accum[downstream] += accum[idx]
	var out_buffer: PackedFloat32Array = accum
	var out: Image = Image.create(w, h, false, Image.FORMAT_RF)
	out.set_data(w, h, false, Image.FORMAT_RF, out_buffer.to_byte_array())
	return out

func _trace_downhill_d8(img: Image, start_world: Vector2, max_steps: int) -> Array[Vector2]:
	var width: int = img.get_width()
	var height: int = img.get_height()
	var rect: Rect2 = get_world_rect()
	var res: Vector2i = get_map_resolution()
	var u: float = clampf((start_world.x - rect.position.x) / rect.size.x, 0.0, 1.0)
	var v: float = clampf((start_world.y - rect.position.y) / rect.size.y, 0.0, 1.0)
	var x: int = int(round(u * float(res.x - 1)))
	var y: int = int(round(v * float(res.y - 1)))
	var path: Array[Vector2] = []
	for _i in range(max_steps):
		path.append(_px_to_world(Vector2i(x, y)))
		var best_x: int = x
		var best_y: int = y
		var best_h: float = img.get_pixel(x, y).r
		for j in range(-1, 2):
			for i in range(-1, 2):
				if i == 0 and j == 0:
					continue
				var nx: int = clampi(x + i, 0, width - 1)
				var ny: int = clampi(y + j, 0, height - 1)
				var h2: float = img.get_pixel(nx, ny).r
				if h2 < best_h:
					best_h = h2
					best_x = nx
					best_y = ny
		if best_x == x and best_y == y:
			break
		x = best_x
		y = best_y
	return path

func _stamp_polyline(er: Node, pts: Array[Vector2], radius_m: float, feather_m: float, preset: String) -> void:
	var r := get_world_rect()
	for p in pts:
		er.stamp_preset_circle_world(p, radius_m, feather_m, preset, r.position, r.size)

func _auto_stamp_erosion(er: Node) -> void:
	if not auto_stamp_enabled:
		return
	if _height_image == null or _height_image.is_empty():
		return
	var ws: Vector2 = get_texel_world_size()
	var slope: Image = _calc_slope_tan(_height_image, ws.x, ws.y)
	var A: Image = _calc_flow_accum_d8(_height_image)
	var moist: Image = _moist_image
	var biome: Image = _biome_index_image
	var have_moist: bool = moist != null and not moist.is_empty()
	var have_biome: bool = biome != null and not biome.is_empty()

	# Rivers: seeds = local A maxima with moderate slope
	var seeds: Array[Vector2] = []
	var w: int = A.get_width()
	var h: int = A.get_height()
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			var a := A.get_pixel(x, y).r
			if a < river_A_min:
				continue
			var s := slope.get_pixel(x, y).r
			if s < river_slope_min or s > river_slope_max:
				continue
			# optional gates
			if have_moist and moist.get_pixel(x, y).r < 0.35:
				continue
			if have_biome:
				var id: int = int(round(biome.get_pixel(x, y).r))
				if id == TRB.Biome.OCEAN or id == TRB.Biome.SNOW:
					continue
			var is_max := true
			for j in range(-1, 2):
				for i in range(-1, 2):
					if i == 0 and j == 0:
						continue
					if A.get_pixel(x + i, y + j).r > a:
						is_max = false
			if is_max:
				seeds.append(_px_to_world(Vector2i(x, y)))

	for s in seeds:
		var path: Array[Vector2] = _trace_downhill_d8(_height_image, s, 1600)
		if path.size() >= 32:
			_stamp_polyline(er, path, auto_river_radius_m, auto_river_feather_m, "river_carve")

	# Fans: big A and slope break
	var fan_pts: Array[Vector2] = []
	for y in range(2, h - 2):
		for x in range(2, w - 2):
			if A.get_pixel(x, y).r < fan_A_min:
				continue
			var s0 := slope.get_pixel(x, y).r
			var s1 := slope.get_pixel(x + 2, y).r
			if s0 > fan_steep_min and s1 < fan_gentle_max:
				fan_pts.append(_px_to_world(Vector2i(x + 3, y)))
	for wp in fan_pts:
		er.stamp_preset_circle_world(wp, auto_fan_radius_m, auto_fan_feather_m, "alluvial_fan", get_world_rect().position, get_world_rect().size)

	# Gullies: steep, low A, dry
	for y in range(h):
		for x in range(w):
			var a2 := A.get_pixel(x, y).r
			if a2 > gully_A_max:
				continue
			var s2 := slope.get_pixel(x, y).r
			if s2 < gully_slope_min:
				continue
			if have_moist and moist.get_pixel(x, y).r > gully_moist_max:
				continue
			var wp2: Vector2 = _px_to_world(Vector2i(x, y))
			er.stamp_preset_circle_world(wp2, auto_gully_radius_m, auto_gully_feather_m, "rain_gullies", get_world_rect().position, get_world_rect().size)

# ========================================================================
# Internals
# ========================================================================
func _ensure_camera() -> void:
	if camera_path != NodePath():
		var n := get_node_or_null(camera_path)
		if n is Camera3D:
			cam = n
		return
	cam = get_viewport().get_camera_3d()

func _ensure_lod_distances() -> void:
	var ok := lod_distances.size() == 4
	if ok:
		ok = lod_distances[1] > 0.0 and lod_distances[2] > lod_distances[1]
	if not ok:
		var r1 := chunk_size * 0.9
		var r2 := chunk_size * 1.8
		lod_distances = PackedFloat32Array([0.0, r1, r2, 1.0e9])

func _ensure_user_dir(path: String) -> void:
	var dir := path.get_base_dir()
	var da := DirAccess.open("user://")
	if da:
		da.make_dir_recursive(dir.replace("user://", ""))

func _get_surface_binder() -> Node:
	if surface_binder_path == NodePath():
		return null
	return get_node_or_null(surface_binder_path)
