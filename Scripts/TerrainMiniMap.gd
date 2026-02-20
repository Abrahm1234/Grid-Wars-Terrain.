@tool
extends Control
class_name TerrainMiniMap

const TRB := preload("res://Scripts/terrain_redblob.gd")

# ---------------- Wiring ----------------
@export var terrain_path: NodePath
@export var camera_or_player_path: NodePath   # Camera3D or Player (Node3D)

# ---------------- Look & placement ----------------
@export var map_resolution: Vector2i = Vector2i(512, 512)   # bake res
@export var map_size_px: int = 220                           # on-screen size
@export_enum("TopLeft","TopRight","BottomLeft","BottomRight") var corner: int = 2
@export var margin: Vector2i = Vector2i(16, 16)
@export_enum("Elevation","Moisture","Biome") var map_type: int = 2
@export var outline: bool = true
@export var outline_color: Color = Color(0, 0, 0, 0.55)

# Direction marker (UI-space, never rotates)
@export var arrow_color: Color = Color(0, 0, 0, 0.9)
@export var arrow_size_px: int = 26

# ---------------- Zoom & follow ----------------
@export var zoom_world_width: float = 1200.0
@export var zoom_min: float = 200.0
@export var zoom_max: float = 20000.0
@export var zoom_step_factor: float = 0.8
@export var show_zoom_buttons: bool = true

# Rotate VIEW (not UI) with the target’s heading
@export var rotate_with_target: bool = true
@export var rotation_smoothing: float = 0.0  # 0=snap, >0 smooth

# Keyboard actions for zoom
@export var zoom_in_action: String = "minimap_zoom_in"
@export var zoom_out_action: String = "minimap_zoom_out"
@export var auto_register_actions: bool = true

# ---------------- Refresh ----------------
@export var regenerate_now: bool = false : set = _set_regen
@export var auto_refresh_seconds: float = 0.0

# ---------------- Internals ----------------
var _rect: ColorRect
var _img_tex: ImageTexture
var _img_size: Vector2i
var _mat: ShaderMaterial
var _acc: float = 0.0
var _btn_in: Button
var _btn_out: Button
var _target_yaw: float = 0.0
var _rot_yaw: float = 0.0

func _ready() -> void:
	_rect = ColorRect.new()
	_rect.color = Color(1, 1, 1, 1)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Make the textured quad draw behind this Control, so our _draw() is on top.
	# (Works in Godot 4; if you're on a minor that lacks the property, the z_index fallback is fine.)
	if _rect.has_method("set_draw_behind_parent"):
		_rect.set_draw_behind_parent(true)
	else:
		_rect.draw_behind_parent = true
		_rect.z_as_relative = false
		_rect.z_index = -1024

	add_child(_rect)

	# Shader that rotates/crops inside the rect (UI stays fixed)
	_mat = ShaderMaterial.new()
	_mat.shader = Shader.new()
	_mat.shader.code = _mini_map_shader()
	_rect.material = _mat

	if show_zoom_buttons:
		_btn_in = Button.new(); _btn_in.text = "+"
		_btn_out = Button.new(); _btn_out.text = "−"
		for b in [_btn_in, _btn_out]:
			b.focus_mode = Control.FOCUS_NONE
			b.custom_minimum_size = Vector2(22, 22)
			add_child(b)
		_btn_in.pressed.connect(_on_zoom_in)
		_btn_out.pressed.connect(_on_zoom_out)

	if auto_register_actions:
		_ensure_zoom_actions()

	_apply_layout()
	_regen()
	set_process(true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_RESIZED:
		_apply_layout()

func _process(dt: float) -> void:
	# keyboard zoom
	if Input.is_action_just_pressed(zoom_in_action):  _on_zoom_in()
	if Input.is_action_just_pressed(zoom_out_action): _on_zoom_out()

	# optional periodic re-bake
	if auto_refresh_seconds > 0.0:
		_acc += dt
		if _acc >= auto_refresh_seconds:
			_acc = 0.0
			_regen()

	_update_view_params(dt)
	queue_redraw()

func _draw() -> void:
	# frame
	if outline:
		draw_rect(Rect2(Vector2.ZERO, size), outline_color, false, 2.0)
	# direction arrow (always points up = player forward)
	var c := size * 0.5
	var s: float = float(arrow_size_px)
	var p0 := c + Vector2(0, -s * 0.60)     # tip
	var p1 := c + Vector2(-s * 0.45, s*0.45)
	var p2 := c + Vector2( s * 0.45, s*0.45)
	draw_colored_polygon([p0, p1, p2], arrow_color)
	draw_polyline([p0, p1, p2, p0], Color(0,0,0,0.65), 2.0)

# ---------------- Layout ----------------
func _apply_layout() -> void:
	var s := Vector2(map_size_px, map_size_px)
	size = s
	custom_minimum_size = s

	match corner:
		0: anchor_left=0; anchor_top=0; anchor_right=0; anchor_bottom=0; offset_left=margin.x; offset_top=margin.y; offset_right=margin.x+s.x; offset_bottom=margin.y+s.y
		1: anchor_left=1; anchor_top=0; anchor_right=1; anchor_bottom=0; offset_left=-margin.x-s.x; offset_top=margin.y; offset_right=-margin.x; offset_bottom=margin.y+s.y
		2: anchor_left=0; anchor_top=1; anchor_right=0; anchor_bottom=1; offset_left=margin.x; offset_top=-margin.y-s.y; offset_right=margin.x+s.x; offset_bottom=-margin.y
		_: anchor_left=1; anchor_top=1; anchor_right=1; anchor_bottom=1; offset_left=-margin.x-s.x; offset_top=-margin.y-s.y; offset_right=-margin.x; offset_bottom=-margin.y

	if _rect:
		_rect.position = Vector2.ZERO
		_rect.size = s

	if show_zoom_buttons and _btn_in and _btn_out:
		var pad := 4.0
		var w := _btn_in.custom_minimum_size.x
		var h := _btn_in.custom_minimum_size.y
		_btn_in.position = Vector2(size.x - pad - w, pad);           _btn_in.size = Vector2(w, h)
		_btn_out.position = Vector2(size.x - pad - w*2 - pad, pad);  _btn_out.size = Vector2(w, h)

# ---------------- Generate map image ----------------
func _set_regen(v: bool) -> void:
	if v: _regen()
	regenerate_now = false

func _regen() -> void:
	var t := _get_terrain()
	if t == null:
		push_warning("[TerrainMiniMap] Set 'Terrain Path' to your Node with GPUTerrainLOD.gd.")
		return

	var weights := _coerce_weights(t)
	var world_seed := _derive_seed_runtime(t, weights)

	var fields: Dictionary = TRB.gen_fields(
		map_resolution, world_seed,
		float(t.seed_noise_frequency), float(t.moisture_frequency),
		weights, float(t.elevation_exponent), float(t.elevation_fudge),
		int(t.island_mode), float(t.island_mix)
	)

	var img: Image = (
		_rf_to_rgba(fields["elev"]) if map_type == 0
		else _rf_to_rgba(fields["moist"]) if map_type == 1
		else TRB.make_biome_map(fields["elev"], fields["moist"])
	)

	if _img_tex == null:
		_img_tex = ImageTexture.create_from_image(img)
	else:
		_img_tex.update(img)
	_img_size = img.get_size()

	_mat.set_shader_parameter("map_tex", _img_tex)
	_update_view_params(0.0)

# ---------------- Update view (center / zoom / angle) ----------------
func _update_view_params(dt: float) -> void:
	if _img_tex == null or _img_size == Vector2i.ZERO:
		return
	var t := _get_terrain()
	var target := (get_node_or_null(camera_or_player_path) as Node3D)
	if t == null or target == null:
		return

	# Use the safe, property-based rect:
	var world: Rect2 = _get_world_rect(t)

	# zoom span in UV (square)
	var min_side: float = min(world.size.x, world.size.y)
	var span_uv: float = clampf(zoom_world_width / max(1.0, min_side), 0.01, 1.0)

	# center in UV from world XZ
	var xz: Vector2 = Vector2(target.global_position.x, target.global_position.z)
	var center_uv: Vector2 = _world_to_uv(xz, world)

	# facing angle -> rotate the sampled content so UP = forward
	if rotate_with_target:
		var yaw := target.global_transform.basis.get_euler().y
		_target_yaw = -yaw
	if rotation_smoothing <= 0.0:
		_rot_yaw = _target_yaw
	else:
		var k: float = clampf(rotation_smoothing * dt, 0.0, 1.0)
		_rot_yaw = lerp_angle(_rot_yaw, _target_yaw, k)

	# push uniforms to shader
	_mat.set_shader_parameter("center_uv", center_uv)
	_mat.set_shader_parameter("span_uv", span_uv)
	_mat.set_shader_parameter("angle", _rot_yaw)

func _on_zoom_in() -> void:
	zoom_world_width = max(zoom_min, zoom_world_width * zoom_step_factor)
	_update_view_params(0.0)

func _on_zoom_out() -> void:
	zoom_world_width = min(zoom_max, zoom_world_width / zoom_step_factor)
	_update_view_params(0.0)

# ---------------- Helpers ----------------
func _get_terrain() -> Node:
	return get_node_or_null(terrain_path) if terrain_path != NodePath() else null

func _props(o: Object) -> Dictionary:
	var d: Dictionary = {}
	for p in o.get_property_list(): d[p.name] = true
	return d

func _coerce_weights(t: Object) -> PackedFloat32Array:
	var w: Variant = null
	if "octave_weights" in _props(t):
		w = t.octave_weights
	if w == null:
		return PackedFloat32Array([1.0, 0.5, 0.25, 0.125, 0.0625])
	if w is PackedFloat32Array:
		return (w as PackedFloat32Array)
	if w is Array:
		var pf := PackedFloat32Array()
		for v in (w as Array):
			pf.append(float(v))
		return pf
	return PackedFloat32Array([1.0, 0.5, 0.25])

func _derive_seed_runtime(t: Object, weights: PackedFloat32Array) -> int:
	if "use_fixed_seed" in _props(t) and bool(t.use_fixed_seed): return int(t.fixed_seed)
	var sig := "%f|%f|%s|%f|%f|%d|%f" % [
		float(t.seed_noise_frequency), float(t.moisture_frequency), str(weights),
		float(t.elevation_exponent), float(t.elevation_fudge),
		int(t.island_mode), float(t.island_mix)
	]
	return int(hash(sig) & 0x7fffffff)

func _rf_to_rgba(img_rf: Image) -> Image:
	var sz := img_rf.get_size()
	var out := Image.create(sz.x, sz.y, false, Image.FORMAT_RGBA8)
	for y in range(sz.y):
		for x in range(sz.x):
			var v: float = clampf(img_rf.get_pixel(x, y).r, 0.0, 1.0)
			out.set_pixel(x, y, Color(v, v, v, 1.0))
	return out

# --- replace the whole function ---
func _get_world_rect(t: Object) -> Rect2:
	# Always compute from exported properties so this works in the editor too,
	# even when 't' is a PlaceholderScriptInstance.
	if t == null:
		return Rect2(Vector2(-500, -500), Vector2(1000, 1000))

	# Safely read exported values if they exist, otherwise use sane defaults.
	var has_chunk := ("chunk_size" in _props(t)) and ("grid_size" in _props(t))
	var sx: float = (float(t.chunk_size) * float(t.grid_size)) if has_chunk else 1000.0
	var sz: float = (float(t.chunk_size) * float(t.grid_size)) if has_chunk else 1000.0

	# World rect centered at (0,0) in XZ, width=sx, height=sz
	var world_size := Vector2(sx, sz)
	return Rect2(-world_size * 0.5, world_size)


func _world_to_uv(xz: Vector2, world: Rect2) -> Vector2:
	var uv := (xz - world.position) / world.size
	return Vector2(clampf(uv.x, 0.0, 1.0), clampf(uv.y, 0.0, 1.0))

func _ensure_zoom_actions() -> void:
	if not InputMap.has_action(zoom_in_action):
		InputMap.add_action(zoom_in_action)
		var e := InputEventKey.new(); e.physical_keycode = KEY_EQUAL
		var e2 := InputEventKey.new(); e2.physical_keycode = KEY_KP_ADD
		InputMap.action_add_event(zoom_in_action, e); InputMap.action_add_event(zoom_in_action, e2)
	if not InputMap.has_action(zoom_out_action):
		InputMap.add_action(zoom_out_action)
		var m := InputEventKey.new(); m.physical_keycode = KEY_MINUS
		var m2 := InputEventKey.new(); m2.physical_keycode = KEY_KP_SUBTRACT
		InputMap.action_add_event(zoom_out_action, m); InputMap.action_add_event(zoom_out_action, m2)

# CanvasItem shader that rotates/crops the source texture around center_uv by angle,
# showing a square window of size span_uv (in source UVs).
func _mini_map_shader() -> String:
	return """
shader_type canvas_item;

uniform sampler2D map_tex : source_color;
uniform vec2  center_uv = vec2(0.5, 0.5);
uniform float span_uv   = 0.25;   // width in source UVs (height = width)
uniform float angle     = 0.0;    // radians

void fragment(){
	vec2 q = UV - vec2(0.5);   // keep UI fixed
	q *= span_uv;              // scale to world span

	// rotate q by 'angle' (UP = forward)
	float c = cos(angle);
	float s = sin(angle);
	vec2 rq = vec2(c * q.x - s * q.y,  s * q.x + c * q.y);

	vec2 src = center_uv + rq;

	// clamp: dim when out of bounds
	bvec2 lo = lessThan(src, vec2(0.0));
	bvec2 hi = greaterThan(src, vec2(1.0));
	if (any(lo) || any(hi)) {
		COLOR = vec4(0.06, 0.08, 0.06, 1.0);
	} else {
		COLOR = texture(map_tex, src);
	}
}
"""
