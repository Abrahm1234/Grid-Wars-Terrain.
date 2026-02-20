extends Node3D
## GPU hydraulic erosion (Godot 4, RenderingDevice) – OFFLINE bake

# ───────────────── Physics / model knobs (solver units = meters) ─────────────────
@export var dx: float = 1.0                 # meters per texel (X)
@export var dy: float = 1.0                 # meters per texel (Y)
@export var dt: float = 0.10                # seconds per iteration
@export var g: float = 9.81                 # gravity
@export var pipe_A: float = 1.0             # pipe cross-section scale
@export var Ks: float = 0.05                # dissolve (erosion) rate
@export var Kd: float = 0.05                # deposition rate
@export var Kc: float = 1.0                 # carrying capacity constant
@export var Ke: float = 0.001               # evaporation rate
@export var min_slope_sin: float = 0.02     # floor on sin(slope) for capacity
@export var rain_intensity: float = 0.001   # rainfall (height units per second)

# Height units conversion (your displacement/heightmap is 0..1; multiply by this to send meters to the solver)
@export var height_to_meters: float = 1.0

# GPU batching (how many iterations to queue in one submit)
@export var iters_per_submit: int = 256

# Compute source (raw GLSL / SPIR-V is generated at runtime)
@export var compute_path: String = "res://Shaders/hydraulic_erosion.txt"

# ───────────────── RD objects ─────────────────
var rd: RenderingDevice
var shader: RID
var pipeline: RID

# SSBOs
var b_buf: RID       # terrain height (meters)
var d_buf: RID       # water height
var v_buf: RID       # velocity (u,v)
var s_buf_ping: RID  # sediment ping
var s_buf_pong: RID  # sediment pong
var f_buf_ping: RID  # flux ping
var f_buf_pong: RID  # flux pong
var c0_buf: RID      # control multipliers (rain, Ks, Kd, Kc)
var c1_buf: RID      # control multipliers (Ke, pipeA, slope add, mask)

# Uniform sets (set = 0)
var u_ping: RID
var u_pong: RID

# Size / state
var size: Vector2i = Vector2i(256, 256)
var _ping: bool = true
var _ready_for_steps: bool = false

# Control maps
var _c0_img: Image
var _c1_img: Image

# CPU preview image/texture (R channel = height 0..1)
var _img_cpu: Image
var height_tex: ImageTexture
var _last_bake_data: PackedFloat32Array = PackedFloat32Array()

func has_bake_result() -> bool:
	return not _last_bake_data.is_empty()

func debug_state(tag: String) -> void:
	print(
		tag,
		" rd:", rd != null,
		" shader:", (shader.is_valid() if shader else false),
		" pipe:", (pipeline.is_valid() if pipeline else false),
		" ready:", _ready_for_steps,
		" sz:", size,
		" src:", compute_path,
		" exists:", FileAccess.file_exists(compute_path)
	)

func _ready() -> void:
	pass

func _ensure_rd() -> void:
	if rd == null:
		rd = RenderingServer.create_local_rendering_device()

func _dispose_rd() -> void:
	if rd != null:
		for rid in [
			u_ping,
			u_pong,
			b_buf,
			d_buf,
			v_buf,
			s_buf_ping,
			s_buf_pong,
			f_buf_ping,
			f_buf_pong,
			c0_buf,
			c1_buf,
			pipeline,
			shader,
		]:
			if rid is RID and rid.is_valid():
				rd.free_rid(rid)
	rd = null
	shader = RID()
	pipeline = RID()
	b_buf = RID()
	d_buf = RID()
	v_buf = RID()
	s_buf_ping = RID()
	s_buf_pong = RID()
	f_buf_ping = RID()
	f_buf_pong = RID()
	c0_buf = RID()
	c1_buf = RID()
	u_ping = RID()
	u_pong = RID()
	_ready_for_steps = false
	_c0_img = null
	_c1_img = null
	_img_cpu = null
	height_tex = null
	_last_bake_data = PackedFloat32Array()

func _exit_tree() -> void:
	_dispose_rd()

# ───────────────── Public API ─────────────────
func is_ready() -> bool:
	return _ready_for_steps and shader.is_valid() and pipeline.is_valid()

## Convenience: set dx/dy using your world span (meters) and texture resolution.
func set_dxdy_from_world(terrain_size_m: Vector2, tex_w: int, tex_h: int) -> void:
	dx = float(terrain_size_m.x) / max(1.0, float(tex_w))
	dy = float(terrain_size_m.y) / max(1.0, float(tex_h))

func init_from_image(img: Image) -> void:
	_dispose_rd()
	_ensure_rd()
	if img == null or img.is_empty():
		push_error("hydraulic_erosion: init_from_image(): image is null/empty")
		_ready_for_steps = false
		return

	size = Vector2i(img.get_width(), img.get_height())
	_create_buffers_with_image(img)
	_create_shader_and_pipeline()
	if not shader.is_valid() or not pipeline.is_valid():
		push_error("Compute shader failed to compile (see console for details). Aborting bake init.")
		_ready_for_steps = false
		return
	_create_uniform_sets()

	_img_cpu = Image.create(size.x, size.y, false, Image.FORMAT_RF)
	_img_cpu.fill(Color(0, 0, 0))
	height_tex = ImageTexture.create_from_image(_img_cpu)

	_ready_for_steps = true
	debug_state("after init")

func simulate_offline(iterations: int) -> void:
	_ensure_rd()
	debug_state("before run")
	if not is_ready():
		push_warning("hydraulic_erosion: call init_from_image() first (or shader compile failed).")
		return

	var iters: int = max(0, iterations)
	if iters == 0:
		return

	if rain_intensity <= 0.0:
		push_warning("hydraulic_erosion: rain_intensity is 0; with no water there will be no erosion.")

	# Push constants once per submit
	var pc: PackedByteArray = _build_push_constants()
	var groups_x: int = int(ceil(float(size.x) / 8.0))
	var groups_y: int = int(ceil(float(size.y) / 8.0))

	var remaining: int = iters
	while remaining > 0:
		var step_count: int = min(iters_per_submit, remaining)
		remaining -= step_count

		var list_id: int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list_id, pipeline)
		rd.compute_list_set_push_constant(list_id, pc, pc.size())

		for _i in range(step_count):
			var uset: RID = (u_ping if _ping else u_pong)
			rd.compute_list_bind_uniform_set(list_id, uset, 0)
			rd.compute_list_dispatch(list_id, groups_x, groups_y, 1)
			_ping = not _ping

		rd.compute_list_end()
		rd.submit()
		rd.sync()  # wait for completion before next batch

	# Read back b[] (meters) → preview texture 0..1
	var b_bytes: PackedByteArray = rd.buffer_get_data(b_buf)
	_last_bake_data = b_bytes.to_float32_array()
	_apply_readback_to_texture()

	var expected: int = size.x * size.y
	if _last_bake_data.size() != expected:
		push_error("RD readback empty (%d vs %d)." % [_last_bake_data.size(), expected])
		return
	var mn: float = INF
	var mx: float = -INF
	for h in _last_bake_data:
		mn = min(mn, h)
		mx = max(mx, h)
	print("erosion meters min/max: ", mn, " / ", mx)
	print("readback n=", _last_bake_data.size(), " expected=", expected)

func get_height_texture() -> Texture2D:
	return height_tex

func get_height_image() -> Image:
	return _img_cpu if _img_cpu != null else Image.new()

func save_height_png(path: String) -> void:
	if _img_cpu == null or _img_cpu.is_empty():
		push_warning("hydraulic_erosion: nothing to save")
		return
	var err: int = _img_cpu.save_png(path)
	if err != OK:
		push_error("Failed to save height PNG: %s (code %d)" % [path, err])

# ───────────────── Internals: buffers / shader / uniforms ─────────────────
func _create_buffers_with_image(img: Image) -> void:
	_ensure_rd()
	# Make sure we can sample pixels (compressed Images need decompression).
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()

	for rid in [b_buf, d_buf, v_buf, s_buf_ping, s_buf_pong, f_buf_ping, f_buf_pong, c0_buf, c1_buf]:
		if rid is RID and rid.is_valid():
			rd.free_rid(rid)

	_c0_img = null
	_c1_img = null

	var n: int = size.x * size.y

	# b in METERS (0..1 height * height_to_meters)
	var b: PackedFloat32Array = PackedFloat32Array(); b.resize(n)
	var k: int = 0
	for y in range(size.y):
		for x in range(size.x):
			var h01: float = clamp(img.get_pixel(x, y).r, 0.0, 1.0)
			b[k] = h01 * height_to_meters
			k += 1

	# other fields start at 0
	var d: PackedFloat32Array = PackedFloat32Array(); d.resize(n);      d.fill(0.0)
	var v: PackedFloat32Array = PackedFloat32Array(); v.resize(n * 2);  v.fill(0.0)
	var s: PackedFloat32Array = PackedFloat32Array(); s.resize(n);      s.fill(0.0)
	var f: PackedFloat32Array = PackedFloat32Array(); f.resize(n * 4);  f.fill(0.0)

	var b_bytes: PackedByteArray = b.to_byte_array()
	var d_bytes: PackedByteArray = d.to_byte_array()
	var v_bytes: PackedByteArray = v.to_byte_array()
	var s_bytes: PackedByteArray = s.to_byte_array()
	var f_bytes: PackedByteArray = f.to_byte_array()

	b_buf      = rd.storage_buffer_create(b_bytes.size(), b_bytes)
	d_buf      = rd.storage_buffer_create(d_bytes.size(), d_bytes)
	v_buf      = rd.storage_buffer_create(v_bytes.size(), v_bytes)
	s_buf_ping = rd.storage_buffer_create(s_bytes.size(), s_bytes)
	s_buf_pong = rd.storage_buffer_create(s_bytes.size(), s_bytes)
	f_buf_ping = rd.storage_buffer_create(f_bytes.size(), f_bytes)
	f_buf_pong = rd.storage_buffer_create(f_bytes.size(), f_bytes)

	_c0_img = Image.create(size.x, size.y, false, Image.FORMAT_RGBAF)
	_c0_img.fill(Color(1.0, 1.0, 1.0, 1.0))
	_c1_img = Image.create(size.x, size.y, false, Image.FORMAT_RGBAF)
	_c1_img.fill(Color(1.0, 1.0, 0.0, 1.0))
	var c0_bytes: PackedByteArray = _c0_img.get_data()
	var c1_bytes: PackedByteArray = _c1_img.get_data()
	c0_buf = rd.storage_buffer_create(c0_bytes.size(), c0_bytes)
	c1_buf = rd.storage_buffer_create(c1_bytes.size(), c1_bytes)



func _create_shader_and_pipeline() -> void:
	_ensure_rd()
	var compute_code: String = FileAccess.get_file_as_string(compute_path)
	if compute_code.is_empty():
		push_error("Compute file not found or empty: %s" % compute_path)
		return

	var src := RDShaderSource.new()
	src.set_language(RenderingDevice.SHADER_LANGUAGE_GLSL)
	src.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, compute_code)

	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(src)

	# If there are compile messages or bytecode is empty, bail early
	if spirv == null or spirv.get_stage_bytecode(RenderingDevice.SHADER_STAGE_COMPUTE).is_empty():
		push_error("Compute shader failed to compile. Check file: %s" % compute_path)
		return

	shader = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		push_error("shader_create_from_spirv() failed.")
		return

	pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		push_error("compute_pipeline_create() failed.")
		return

# Build an RDUniform for a storage buffer binding
func _mk_uniform(binding: int, buf: RID) -> RDUniform:
	var uu := RDUniform.new()
	uu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uu.binding = binding
	uu.add_id(buf)
	return uu

func _make_uniform_set(read_s: RID, write_s: RID, read_f: RID, write_f: RID) -> RID:
	# Binding layout expected by the compute:
	# 0:b   1:d   2:s_in   3:s_out   4:f_in   5:f_out   6:v   7:c0   8:c1
	var u: Array[RDUniform] = []
	u.append(_mk_uniform(0, b_buf))
	u.append(_mk_uniform(1, d_buf))
	u.append(_mk_uniform(2, read_s))
	u.append(_mk_uniform(3, write_s))
	u.append(_mk_uniform(4, read_f))
	u.append(_mk_uniform(5, write_f))
	u.append(_mk_uniform(6, v_buf))
	u.append(_mk_uniform(7, c0_buf))
	u.append(_mk_uniform(8, c1_buf))
	return rd.uniform_set_create(u, shader, 0)

func _create_uniform_sets() -> void:
	_ensure_rd()
	u_ping = _make_uniform_set(s_buf_ping, s_buf_pong, f_buf_ping, f_buf_pong)
	u_pong = _make_uniform_set(s_buf_pong, s_buf_ping, f_buf_pong, f_buf_ping)

func reset_control_maps() -> void:
	if _c0_img != null:
		_c0_img.fill(Color(1.0, 1.0, 1.0, 1.0))
	if _c1_img != null:
		_c1_img.fill(Color(1.0, 1.0, 0.0, 1.0))

func upload_control_maps() -> void:
	_ensure_rd()
	if rd == null:
		return
	if c0_buf.is_valid() and _c0_img != null:
		var data0: PackedByteArray = _c0_img.get_data()
		rd.buffer_update(c0_buf, 0, data0.size(), data0)
	if c1_buf.is_valid() and _c1_img != null:
		var data1: PackedByteArray = _c1_img.get_data()
		rd.buffer_update(c1_buf, 0, data1.size(), data1)

func world_to_pixel(center_xz: Vector2, origin: Vector2, size_m: Vector2) -> Vector2i:
	if size.x <= 0 or size.y <= 0:
		return Vector2i.ZERO
	var u: float = (center_xz.x - origin.x) / max(size_m.x, 1e-6)
	var v: float = (center_xz.y - origin.y) / max(size_m.y, 1e-6)
	var px: int = clamp(int(round(u * float(size.x - 1))), 0, size.x - 1)
	var py: int = clamp(int(round(v * float(size.y - 1))), 0, size.y - 1)
	return Vector2i(px, py)

func stamp_preset_circle_world(center_xz: Vector2, radius_m: float, feather_m: float, preset: String, origin: Vector2, size_m: Vector2) -> void:
	if _c0_img == null or _c0_img.is_empty():
		return
	var px := world_to_pixel(center_xz, origin, size_m)
	_circle_stamp(px.x, px.y, radius_m, feather_m, preset)

func _circle_stamp(cx: int, cy: int, radius_m: float, feather_m: float, preset: String) -> void:
	if _c0_img == null or _c1_img == null or _c0_img.is_empty():
		return
	radius_m = max(radius_m, 0.0)
	feather_m = clamp(feather_m, 0.0, radius_m)
	var preset_vals: Array[Color] = _preset_values(preset)
	var target_c0: Color = preset_vals[0]
	var target_c1: Color = preset_vals[1]
	var max_x: int = int(ceil(radius_m / max(dx, 1e-6)))
	var max_y: int = int(ceil(radius_m / max(dy, 1e-6)))
	for y in range(max(0, cy - max_y), min(size.y, cy + max_y + 1)):
		var dy_m: float = abs(float(y - cy)) * dy
		if dy_m > radius_m:
			continue
		for x in range(max(0, cx - max_x), min(size.x, cx + max_x + 1)):
			var dx_m: float = abs(float(x - cx)) * dx
			var dist: float = sqrt(dx_m * dx_m + dy_m * dy_m)
			if dist > radius_m:
				continue
			var k: float = 1.0
			if dist > radius_m - feather_m:
				k = 1.0 - (dist - (radius_m - feather_m)) / max(feather_m, 1e-3)
			k = clamp(k, 0.0, 1.0)
			if k <= 0.0:
				continue
			var base0: Color = _c0_img.get_pixel(x, y)
			var base1: Color = _c1_img.get_pixel(x, y)
			_c0_img.set_pixel(x, y, base0.lerp(target_c0, k))
			_c1_img.set_pixel(x, y, base1.lerp(target_c1, k))

func _preset_values(preset_name: String) -> Array[Color]:
	match preset_name:
		"rain_gullies":
			return [Color(2.0, 2.0, 1.0, 1.5), Color(0.5, 1.0, 0.0, 1.0)]
		"alluvial_fan":
			return [Color(1.0, 1.0, 2.0, 0.5), Color(2.0, 1.0, 0.0, 1.0)]
		"river_carve":
			return [Color(3.0, 1.5, 0.5, 2.0), Color(0.6, 0.6, 0.0, 1.0)]
		_:
			return [Color(1.0, 1.0, 1.0, 1.0), Color(1.0, 1.0, 0.0, 1.0)]

# Pack push constants EXACTLY like the compute expects (64 bytes):
# 2×u32 (width,height) + 2×pad + 12 floats:
# [dt, dx, dy, g, pipe_A, Ks, Kd, Kc, Ke, min_slope_sin, rain_intensity, <pad>]
func _build_push_constants() -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(64)
	var bw := StreamPeerBuffer.new()
	bw.data_array = pc
	bw.put_u32(size.x)
	bw.put_u32(size.y)
	bw.put_u32(0)            # pad
	bw.put_u32(0)            # pad
	bw.put_float(dt)
	bw.put_float(dx)
	bw.put_float(dy)
	bw.put_float(g)
	bw.put_float(pipe_A)
	bw.put_float(Ks)
	bw.put_float(Kd)
	bw.put_float(Kc)
	bw.put_float(Ke)
	bw.put_float(min_slope_sin)
	bw.put_float(rain_intensity)
	return bw.data_array

# ───────────────── Readback & preview texture (write as 0..1) ────────────────
func _apply_readback_to_texture() -> void:
	if _img_cpu == null or _last_bake_data.is_empty():
		return
	var n: int = size.x * size.y
	if n <= 0:
		return

	# Convert meters back to 0..1 for the terrain shader
	var inv_scale: float = 1.0 / max(1e-6, height_to_meters)

	var k: int = 0
	for y in range(size.y):
		for x in range(size.x):
			var h_m: float = _last_bake_data[k]
			var h01: float = clamp(h_m * inv_scale, 0.0, 1.0)
			_img_cpu.set_pixel(x, y, Color(h01, 0, 0))
			k += 1

	if height_tex == null:
		height_tex = ImageTexture.create_from_image(_img_cpu)
	else:
		height_tex.update(_img_cpu)
