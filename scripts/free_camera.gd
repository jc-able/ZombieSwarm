extends Camera3D

@export var move_speed: float = 80.0
@export var fast_speed: float = 250.0
@export var mouse_sensitivity: float = 0.002

var _yaw: float = 0.0
var _pitch: float = -0.30


func _unhandled_input(event: InputEvent):
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, -PI / 2.0, PI / 2.0)
		rotation = Vector3(_pitch, _yaw, 0)

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float):
	var dir := Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		dir.z += 1
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		dir.x += 1
	if Input.is_key_pressed(KEY_SPACE):
		dir.y += 1
	if Input.is_key_pressed(KEY_SHIFT):
		dir.y -= 1

	dir = dir.normalized()

	var speed := fast_speed if Input.is_key_pressed(KEY_CTRL) else move_speed
	var velocity := (basis * dir) * speed
	position += velocity * delta
