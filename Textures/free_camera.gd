extends Camera3D

@export var capture_mouse_on_ready: bool = true
@export var mouse_sensitivity: float = 0.0025
@export_range(-89.0, 0.0, 0.1) var min_pitch_deg: float = -85.0
@export_range(0.0, 89.0, 0.1) var max_pitch_deg: float = 85.0

@export var move_speed: float = 10.0
@export var sprint_multiplier: float = 3.0
@export var accel: float = 18.0
@export var decel: float = 22.0

@export var enable_fly_vertical: bool = true
@export var toggle_mouse_key: Key = KEY_ESCAPE
@export var make_current_on_ready: bool = true

# Muzzle flash (assign in Inspector by dragging your muzzle flash instance here)
@export var muzzle_flash_path: NodePath
@export var muzzle_flash_button: MouseButton = MOUSE_BUTTON_RIGHT

var _yaw: float = 0.0
var _pitch: float = 0.0
var _vel: Vector3 = Vector3.ZERO
var _muzzle_flash: Node = null


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x

	if make_current_on_ready:
		make_current()

	if capture_mouse_on_ready:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	_muzzle_flash = get_node_or_null(muzzle_flash_path)


func _unhandled_input(event: InputEvent) -> void:
	# Toggle mouse capture
	if event is InputEventKey:
		var ek := event as InputEventKey
		if ek.pressed and ek.keycode == toggle_mouse_key:
			if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# If mouse isn't captured, don't look or fire
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return

	# Mouse look
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * mouse_sensitivity
		_pitch -= mm.relative.y * mouse_sensitivity
		_pitch = clamp(_pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
		rotation = Vector3(_pitch, _yaw, 0.0)
		return

	# Right mouse = play muzzle flash
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == muzzle_flash_button:
			_trigger_muzzle_flash()
			return


func _physics_process(delta: float) -> void:
	var wish := Vector3.ZERO

	# Prefer custom actions; fallback to default ui_* actions.
	var forward := _axis(&"move_forward", &"ui_up")
	var back := _axis(&"move_backward", &"ui_down")
	var left := _axis(&"move_left", &"ui_left")
	var right := _axis(&"move_right", &"ui_right")

	var x := right - left
	var z := back - forward

	wish += global_transform.basis.x * x
	wish += -global_transform.basis.z * (-z)

	if enable_fly_vertical:
		var up := _axis(&"move_up", &"")
		var down := _axis(&"move_down", &"")
		wish += global_transform.basis.y * (up - down)

	if wish.length() > 0.0001:
		wish = wish.normalized()

	var spd := move_speed
	var sprint_pressed := Input.is_key_pressed(KEY_SHIFT)
	if InputMap.has_action(&"move_sprint"):
		sprint_pressed = sprint_pressed or Input.is_action_pressed(&"move_sprint")

	if sprint_pressed:
		spd *= sprint_multiplier

	var target_vel := wish * spd
	var rate := accel if wish.length() > 0.0 else decel
	_vel = _vel.lerp(target_vel, 1.0 - exp(-rate * delta))

	global_position += _vel * delta


func _axis(primary: StringName, fallback: StringName) -> float:
	var v := 0.0
	if primary != &"" and InputMap.has_action(primary):
		v = Input.get_action_strength(primary)
	elif fallback != &"" and InputMap.has_action(fallback):
		v = Input.get_action_strength(fallback)
	return v


func _trigger_muzzle_flash() -> void:
	if _muzzle_flash == null:
		return

	# Preferred: your muzzle flash scene has a script with a `play()` method.
	if _muzzle_flash.has_method("play"):
		_muzzle_flash.call("play")
		return

	# Fallback: restart any GPUParticles3D found under the muzzle flash node.
	_restart_particles_recursive(_muzzle_flash)


func _restart_particles_recursive(n: Node) -> void:
	if n is GPUParticles3D:
		var p := n as GPUParticles3D
		p.emitting = false
		p.restart()
		p.emitting = true

	for child: Node in n.get_children():
		_restart_particles_recursive(child)
