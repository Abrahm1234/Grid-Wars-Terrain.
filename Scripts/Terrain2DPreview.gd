@tool
extends Control
class_name Terrain2DPreview

const TRB := preload("res://Scripts/terrain_redblob.gd")

# ---------------- Scene references ----------------
@export var terrain_path: NodePath
@export var camera_or_player_path: NodePath

# ---------------- Input & visibility ----------------
@export var toggle_action: String = "toggle_map"
@export var auto_register_actions: bool = true
@export var start_hidden_in_game: bool = true

# ---------------- Preview source ----------------
@export_group("Preview Source")
@export var preview_texture: Texture2D
@export var auto_find_terrain: bool = true
@export var refresh_interval: float = 0.25

# Editor preview settings
@export var resolution: Vector2i = Vector2i(256, 256)
@export_enum("Elevation","Moisture","Biome") var map_type: int = 2
@export var generate_now: bool = false : set = _set_generate_now

# ---------------- Marker ----------------
@export_group("Marker")
@export var show_marker: bool = true
@export var marker_color: Color = Color(0.0, 0.0, 0.0, 0.9)
@export var marker_size_px: int = 18
@export var outline: bool = true
@export var outline_color: Color = Color(0, 0, 0, 0.35)
@export var follow_camera_when_still: bool = true
@export var still_heading_speed: float = 6.0

# ---------------- Appearance ----------------
@export_group("Appearance")
@export var brightness: float = 0.25 : set = _set_brightness
@export var contrast: float = 1.10 : set = _set_contrast
@export var saturation: float = 1.00 : set = _set_saturation
@export var border_color: Color = Color.BLACK

# ---------------- Zoom ----------------
@export_group("Zoom")
@export var zoom_in_action: String = "map_zoom_in"
@export var zoom_out_action: String = "map_zoom_out"
@export var zoom_reset_action: String = "map_zoom_reset"
@export var zoom_factor: float = 1.0 : set = _set_zoom
@export var zoom_step: float = 1.25
@export var zoom_min: float = 1.0
@export var zoom_max: float = 12.0
@export var zoom_follow_target: bool = true

# ---------------- Internals ----------------
var _rect: TextureRect
var _overlay: Control
var _tex: Texture2D
var _terrain: Node
var _target: Node3D
var _prev_xz: Vector2 = Vector2.INF
@export var move_eps: float = 0.02
var _last_move_angle: float = 0.0

var _center_uv: Vector2 = Vector2(0.5, 0.5)
var _marker_angle: float = 0.0
var _accum: float = 0.0

var _post_mat: ShaderMaterial
var _last_sig: String = ""

# Overlay draws outline + arrow above the texture
class ArrowOverlay:
	extends Control
	var cb_get_rect: Callable
	var cb_get_center_uv: Callable
	var cb_get_angle: Callable
	var cb_get_show_marker: Callable
	var cb_get_marker_color: Callable
	var cb_get_marker_size: Callable
	var cb_get_outline: Callable
	var cb_get_outline_color: Callable

	func _draw() -> void:
		var r: Rect2 = cb_get_rect.call()

		# outline
		if cb_get_outline.call():
			draw_rect(r, Color(0, 0, 0, 0), false, 1.0, true)
			draw_rect(r.grow(1.0), cb_get_outline_color.call(), false, 1.0, true)

		# arrow
		if cb_get_show_marker.call():
			var uv: Vector2 = cb_get_center_uv.call()
			var p: Vector2 = r.position + uv * r.size
			var s: float = float(max(8, int(cb_get_marker_size.call())))
			var tip:   Vector2 = Vector2( 0.0, -0.60 * s)
			var left:  Vector2 = Vector2(-0.50 * s,  0.45 * s)
			var right: Vector2 = Vector2( 0.50 * s,  0.45 * s)
			var rot: Transform2D = Transform2D(float(cb_get_angle.call()), p)
			var pts: PackedVector2Array = PackedVector2Array([rot * tip, rot * left, rot * right])
			draw_colored_polygon(pts, cb_get_marker_color.call())

# ------------------------------------------------------------------------------

func _ready() -> void:
	clip_contents = true

	# --- texture underlay ---
	_rect = TextureRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rect.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.z_as_relative = false
	_rect.z_index = 0  # keep shader quad underneath overlay
	add_child(_rect)

	_attach_post_material()

	# --- overlay (arrow + outline) ---
	_overlay = ArrowOverlay.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overlay.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.z_as_relative = false
	_overlay.z_index = RenderingServer.CANVAS_ITEM_Z_MAX - 1  # stay within valid z range
	_overlay.cb_get_rect          = Callable(self, "_map_content_rect")
	_overlay.cb_get_center_uv     = Callable(self, "_get_draw_center_uv")
	_overlay.cb_get_angle         = Callable(self, "_get_marker_angle")
	_overlay.cb_get_show_marker   = Callable(self, "_get_show_marker")
	_overlay.cb_get_marker_color  = Callable(self, "_get_marker_color")
	_overlay.cb_get_marker_size   = Callable(self, "_get_marker_size")
	_overlay.cb_get_outline       = Callable(self, "_get_outline")
	_overlay.cb_get_outline_color = Callable(self, "_get_outline_color")
	add_child(_overlay)

	# input actions
	if auto_register_actions:
		_ensure_action(toggle_action, KEY_M)
		_ensure_action(zoom_in_action, KEY_EQUAL)
		_ensure_action(zoom_out_action, KEY_MINUS)
		_ensure_action(zoom_reset_action, KEY_0)

	# visibility rule
	if not Engine.is_editor_hint():
		visible = not start_hidden_in_game

	# links
	_terrain = get_node_or_null(terrain_path)
	_target  = get_node_or_null(camera_or_player_path)
	_ensure_references()

	_tex = preview_texture
	_rect.texture = _tex

	set_process(true) # also runs in editor
	_update_layout()
	_update_zoom_uniforms()
	_update_post_uniforms()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		call_deferred("_update_layout")

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed(toggle_action):
		visible = not visible
		queue_redraw()
		if _overlay: _overlay.queue_redraw()
		return

	# zoom hotkeys
	if e.is_action_pressed(zoom_in_action):
		_set_zoom(clampf(zoom_factor * zoom_step, zoom_min, zoom_max)); return
	if e.is_action_pressed(zoom_out_action):
		_set_zoom(clampf(zoom_factor / zoom_step, zoom_min, zoom_max)); return
	if e.is_action_pressed(zoom_reset_action):
		_set_zoom(1.0); return

	# wheel zoom (optional)
	if e is InputEventMouseButton and visible:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_set_zoom(clampf(zoom_factor * zoom_step, zoom_min, zoom_max))
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_set_zoom(clampf(zoom_factor / zoom_step, zoom_min, zoom_max))

func _process(dt: float) -> void:
	_ensure_references()

	# periodic refresh
	_accum += dt
	if _accum >= refresh_interval:
		_accum = 0.0
		_try_grab_terrain_texture()
		# editor fallback
		if Engine.is_editor_hint() and (_tex == null or not is_instance_valid(_tex)):
			_regen_editor_preview()

	# marker + follow center
	if visible and _terrain != null and _target != null:
		var world_rect: Rect2 = _get_world_rect(_terrain)
		var xz: Vector2 = Vector2(_target.global_position.x, _target.global_position.z)
		_center_uv = _world_to_uv(xz, world_rect)

		var dir: Vector2 = Vector2.ZERO
		if _prev_xz != Vector2.INF:
			dir = xz - _prev_xz
		if dir.length() > move_eps:
			var ang := _angle_from_dir_xz(dir)
			_last_move_angle = ang
			_marker_angle = lerp_angle(_marker_angle, ang, 0.3)
		else:
			if follow_camera_when_still and _target != null:
				var forward: Vector3 = -_target.global_transform.basis.z
				var heading := _angle_from_dir_xz(Vector2(forward.x, forward.z))
				var t := clampf(still_heading_speed * dt, 0.0, 1.0)
				_marker_angle = lerp_angle(_marker_angle, heading, t)
			else:
				_marker_angle = _last_move_angle

		_prev_xz = xz
		if zoom_follow_target and zoom_factor > 1.0:
			_update_zoom_uniforms()
		queue_redraw()
		if _overlay:
			_overlay.queue_redraw()
	else:
		_prev_xz = Vector2.INF

func _draw() -> void:
	if _rect != null and _rect.texture != _tex:
		_rect.texture = _tex
	if _overlay:
		_overlay.queue_redraw()

# ---------------- layout & mapping ----------------

func _update_layout() -> void:
	if _rect == null: return
	queue_redraw()
	if _overlay:
		_overlay.queue_redraw()

func _map_content_rect() -> Rect2:
	var ctrl_size: Vector2 = size
	if ctrl_size.x <= 0.0 or ctrl_size.y <= 0.0:
		return Rect2(Vector2.ZERO, Vector2.ZERO)

	if _rect == null or _rect.texture == null:
		return Rect2(Vector2.ZERO, ctrl_size)

	var tex_size: Vector2 = _rect.texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return Rect2(Vector2.ZERO, ctrl_size)

	match _rect.stretch_mode:
		TextureRect.STRETCH_KEEP_ASPECT, TextureRect.STRETCH_KEEP_ASPECT_CENTERED:
			var fit_scale: float = min(ctrl_size.x / tex_size.x, ctrl_size.y / tex_size.y)
			var draw_size: Vector2 = tex_size * fit_scale
			var origin: Vector2 = (ctrl_size - draw_size) * 0.5
			return Rect2(origin, draw_size)
		TextureRect.STRETCH_KEEP_ASPECT_COVERED:
			var cover_scale: float = max(ctrl_size.x / tex_size.x, ctrl_size.y / tex_size.y)
			var draw_size_cov: Vector2 = tex_size * cover_scale
			var origin_cov: Vector2 = (ctrl_size - draw_size_cov) * 0.5
			return Rect2(origin_cov, draw_size_cov)
		_:
			return Rect2(Vector2.ZERO, ctrl_size)

func _get_draw_center_uv() -> Vector2:
	if zoom_follow_target and zoom_factor > 1.0:
		return Vector2(0.5, 0.5)
	return _center_uv
func _get_marker_angle() -> float: return _marker_angle
func _get_show_marker() -> bool:   return show_marker
func _get_marker_color() -> Color: return marker_color
func _get_marker_size() -> int:    return marker_size_px
func _get_outline() -> bool:       return outline
func _get_outline_color() -> Color: return outline_color

func _get_yaw(n: Node3D) -> float:
	return n.global_transform.basis.get_euler().y

func _angle_from_dir_xz(dir: Vector2) -> float:
	if dir.length_squared() == 0.0:
		return _marker_angle
	var d := dir.normalized()
	return atan2(d.x, -d.y)

func _world_to_uv(xz: Vector2, world: Rect2) -> Vector2:
	if world.size.x == 0.0 or world.size.y == 0.0:
		return Vector2(0.5, 0.5)
	var u: float = (xz.x - world.position.x) / world.size.x
	var v: float = (xz.y - world.position.y) / world.size.y
	return Vector2(clamp(u, 0.0, 1.0), clamp(v, 0.0, 1.0))

# ---------------- terrain info & texture pickup ----------------

func _get_world_rect(t: Object) -> Rect2:
	if t != null and t.has_method("get_world_rect") and not Engine.is_editor_hint():
		return t.call("get_world_rect")
	var props: Dictionary = _props_with_values(t)
	var has_chunk: bool = props.has("chunk_size") and props.has("grid_size")
	var sx: float
	var sz: float
	if has_chunk:
		sx = float(props["chunk_size"]) * float(props["grid_size"])
		sz = float(props["chunk_size"]) * float(props["grid_size"])
	else:
		sx = 1000.0
		sz = 1000.0
	var half: Vector2 = Vector2(sx, sz) * 0.5
	return Rect2(-half, Vector2(sx, sz))

func _props_with_values(o: Object) -> Dictionary:
	var d: Dictionary = {}
	if o == null: return d
	for p in o.get_property_list():
		if not (p is Dictionary) or not p.has("name"):
			continue
		var prop_name: String = p["name"]
		if o.has_method("get"):
			var v: Variant = o.get(prop_name)
			if v != null:
				d[prop_name] = v
	return d

func _find_terrain_node() -> Node:
	var root: Node = get_tree().current_scene
	if root == null: return null
	for c in root.get_children():
		if c == null: continue
		var pr: Dictionary = _props_with_values(c)
		if pr.has("seed_noise_frequency") or pr.has("octave_weights") or pr.has("chunk_size"):
			return c
	return null

func _try_grab_terrain_texture() -> void:
	if preview_texture != null:
		_tex = preview_texture
		if _rect: _rect.texture = _tex
		return
	if Engine.is_editor_hint():
		return
	if _terrain == null: return
	var props: Dictionary = _props_with_values(_terrain)
	var mat: ShaderMaterial = null
	if props.has("shared_material") and props["shared_material"] is ShaderMaterial:
		mat = props["shared_material"]
	elif props.has("material") and props["material"] is ShaderMaterial:
		mat = props["material"]
	if mat != null:
		var vparam: Variant = mat.get_shader_parameter("biome_map")
		if vparam == null:
			vparam = mat.get_shader_parameter("heightmap")
		if vparam is Texture2D:
			_tex = vparam as Texture2D
			if _rect: _rect.texture = _tex
			queue_redraw()
			if _overlay: _overlay.queue_redraw()

# ---------------- Editor preview (CPU fallback) ----------------

func _set_generate_now(v: bool) -> void:
	if v:
		_ensure_references()
		_regen_editor_preview()
	generate_now = false

func _signature() -> String:
	var t: Object = _terrain
	if t == null:
		return "%dx%d|%d|no-terrain" % [resolution.x, resolution.y, map_type]
	var weights: PackedFloat32Array = _coerce_weights(t)
	var world_seed: int = _derive_preview_seed(t, weights)
	var pr: Dictionary = _props_with_values(t)
	return "%dx%d|%d|%f|%f|%s|%f|%f|%d|%f|%d" % [
		resolution.x, resolution.y, map_type,
		float(pr.get("seed_noise_frequency", 1.0)),
		float(pr.get("moisture_frequency", 1.0)),
		str(weights),
		float(pr.get("elevation_exponent", 1.0)),
		float(pr.get("elevation_fudge", 0.0)),
		int(pr.get("island_mode", 0)),
		float(pr.get("island_mix", 0.0)),
		world_seed
	]

func _regen_editor_preview() -> void:
	if not Engine.is_editor_hint():
		return
	_ensure_references()
	if _terrain == null and auto_find_terrain:
		_terrain = _find_terrain_node()
	if _terrain == null:
		return

	var sig: String = _signature()
	if sig == _last_sig and _tex != null:
		return
	_last_sig = sig

	var pr: Dictionary = _props_with_values(_terrain)
	var weights: PackedFloat32Array = _coerce_weights(_terrain)
	var world_seed: int = _derive_preview_seed(_terrain, weights)

	var res: Vector2i = resolution
	if res.x < 2 or res.y < 2:
		res = Vector2i(2, 2)

	var fields: Dictionary = TRB.gen_fields(
		res, world_seed,
		float(pr.get("seed_noise_frequency", 1.0)),
		float(pr.get("moisture_frequency", 1.0)),
		weights,
		float(pr.get("elevation_exponent", 1.0)),
		float(pr.get("elevation_fudge", 0.0)),
		int(pr.get("island_mode", 0)),
		float(pr.get("island_mix", 0.0))
	)

	var show_img: Image = (
		_rf_to_rgba(fields["elev"]) if map_type == 0
		else _rf_to_rgba(fields["moist"]) if map_type == 1
		else TRB.make_biome_map(fields["elev"], fields["moist"])
	)

	var new_tex: ImageTexture = ImageTexture.create_from_image(show_img)
	_tex = new_tex
	if _rect: _rect.texture = _tex
	queue_redraw()
	if _overlay: _overlay.queue_redraw()

func _rf_to_rgba(img_rf: Image) -> Image:
	var sz: Vector2i = img_rf.get_size()
	var out_img: Image = Image.create(sz.x, sz.y, false, Image.FORMAT_RGBA8)
	for y in range(sz.y):
		for x in range(sz.x):
			var v: float = clamp(float(img_rf.get_pixel(x, y).r), 0.0, 1.0)
			out_img.set_pixel(x, y, Color(v, v, v, 1.0))
	return out_img

func _coerce_weights(t: Object) -> PackedFloat32Array:
	var pr: Dictionary = _props_with_values(t)
	var w: Variant = pr.get("octave_weights", null)
	if w == null:
		return PackedFloat32Array([1.0, 0.5, 0.25, 0.125, 0.0625])
	if w is PackedFloat32Array:
		return (w as PackedFloat32Array) if (w as PackedFloat32Array).size() > 0 else PackedFloat32Array([1.0, 0.5, 0.25])
	if w is Array:
		var pf: PackedFloat32Array = PackedFloat32Array()
		for v in (w as Array):
			pf.append(float(v))
		return pf
	return PackedFloat32Array([1.0, 0.5, 0.25])

func _seed_sig_str(t: Object, weights: PackedFloat32Array) -> String:
	var pr: Dictionary = _props_with_values(t)
	return "%f|%f|%s|%f|%f|%d|%f" % [
		float(pr.get("seed_noise_frequency", 1.0)),
		float(pr.get("moisture_frequency", 1.0)),
		str(weights),
		float(pr.get("elevation_exponent", 1.0)),
		float(pr.get("elevation_fudge", 0.0)),
		int(pr.get("island_mode", 0)),
		float(pr.get("island_mix", 0.0))
	]

func _derive_preview_seed(t: Object, weights: PackedFloat32Array) -> int:
	var pr: Dictionary = _props_with_values(t)
	if pr.has("use_fixed_seed") and bool(pr["use_fixed_seed"]):
		return int(pr.get("fixed_seed", 1))
	var h: int = hash(_seed_sig_str(t, weights))
	return int(h & 0x7fffffff)

# ---------------- Appearance + Zoom material ----------------

func _attach_post_material() -> void:
	if _post_mat == null:
		var sh: Shader = Shader.new()
		sh.code = """
shader_type canvas_item;

// Tuning
uniform float u_brightness : hint_range(-1.0, 2.0) = 0.25;
uniform float u_contrast   : hint_range(0.2, 2.5)  = 1.10;
uniform float u_saturation : hint_range(0.0, 2.0)  = 1.00;

// Zoom
uniform float u_zoom = 1.0;          // >= 1.0
uniform vec2  u_center = vec2(0.5);  // UV to center on when zoomed

// Border outside the sampled area (no stretching)
uniform vec4 u_border_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	vec2 uv = UV;

	if (u_zoom > 1.0001) {
		// Zoom around u_center without stretching
		uv = (UV - vec2(0.5)) / u_zoom + u_center;
	}

	// If outside the texture area, fill with border color
	bool inside = all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
	if (!inside) {
		COLOR = u_border_color;
	} else {
		vec4 c = texture(TEXTURE, uv);

		// Saturation
		float y = dot(c.rgb, vec3(0.299, 0.587, 0.114));
		c.rgb = mix(vec3(y), c.rgb, u_saturation);

		// Contrast around 0.5
		c.rgb = (c.rgb - 0.5) * u_contrast + 0.5;

		// Brightness
		c.rgb += u_brightness;

		COLOR = vec4(c.rgb, c.a);
	}
}
"""
		_post_mat = ShaderMaterial.new()
		_post_mat.shader = sh
	if _rect:
		_rect.material = _post_mat
		_update_post_uniforms()
		_update_zoom_uniforms()

func _update_post_uniforms() -> void:
	if _post_mat:
		_post_mat.set_shader_parameter("u_brightness", brightness)
		_post_mat.set_shader_parameter("u_contrast", contrast)
		_post_mat.set_shader_parameter("u_saturation", saturation)
		_post_mat.set_shader_parameter("u_border_color", border_color)

func _update_zoom_uniforms() -> void:
	if not _post_mat: return
	_post_mat.set_shader_parameter("u_zoom", max(1.0, zoom_factor))
	var center_for_shader: Vector2 = Vector2(0.5, 0.5)
	if zoom_factor > 1.0 and zoom_follow_target:
		center_for_shader = _center_uv
	_post_mat.set_shader_parameter("u_center", center_for_shader)
	if _overlay:
		_overlay.queue_redraw()

func _set_brightness(v: float) -> void:
	brightness = v
	_update_post_uniforms()

func _set_contrast(v: float) -> void:
	contrast = v
	_update_post_uniforms()

func _set_saturation(v: float) -> void:
	saturation = v
	_update_post_uniforms()

func _set_zoom(v: float) -> void:
	var nv: float = clampf(v, zoom_min, zoom_max)
	if is_equal_approx(nv, zoom_factor):
		return
	zoom_factor = nv
	_update_zoom_uniforms()
	queue_redraw()

# ---------------- Utilities ----------------

func _ensure_action(action_name: String, default_key: Key) -> void:
	if InputMap.has_action(action_name):
		return
	InputMap.add_action(action_name)
	var e: InputEventKey = InputEventKey.new()
	e.physical_keycode = default_key
	InputMap.action_add_event(action_name, e)

func _ensure_references() -> void:
	if _terrain != null and not is_instance_valid(_terrain):
		_terrain = null
	if _terrain == null:
		if terrain_path != NodePath():
			_terrain = get_node_or_null(terrain_path)
		elif auto_find_terrain:
			_terrain = _find_terrain_node()
	if _target != null and not is_instance_valid(_target):
		_target = null
	if _target == null and camera_or_player_path != NodePath():
		_target = get_node_or_null(camera_or_player_path)
