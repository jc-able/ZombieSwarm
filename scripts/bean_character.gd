extends CharacterBody3D

@export var walk_speed := 8.0
@export var run_speed := 18.0
@export var jump_velocity := 10.0
@export var gravity_strength := 30.0
@export var mouse_sensitivity := 0.003
@export var cam_distance := 10.0
@export var cam_height := 4.0

var _yaw := 0.0
var _pitch := 0.15
var _body_pivot: Node3D
var _camera: Camera3D


func _ready():
	collision_mask = 7  # Detect terrain (layer 1) + obstacles (layer 2) + railings (layer 3)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# ── Bean visual (rotates to face movement) ────────────────────────────
	_body_pivot = Node3D.new()
	_body_pivot.name = "BodyPivot"
	add_child(_body_pivot)

	# Body capsule
	var body_mesh := MeshInstance3D.new()
	body_mesh.name = "Body"
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.45
	capsule.height = 1.8
	body_mesh.mesh = capsule
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.92, 0.78, 0.55)
	body_mesh.material_override = body_mat
	body_mesh.position = Vector3(0, 0.9, 0)
	_body_pivot.add_child(body_mesh)

	# Eyes (so you can see which way the bean faces)
	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(0.1, 0.1, 0.1)
	for eye_x in [-0.15, 0.15]:
		var eye := MeshInstance3D.new()
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = 0.08
		eye_mesh.height = 0.16
		eye.mesh = eye_mesh
		eye.material_override = eye_mat
		eye.position = Vector3(eye_x, 1.55, -0.38)
		_body_pivot.add_child(eye)

	# ── Collision shape ───────────────────────────────────────────────────
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.45
	shape.height = 1.8
	col.shape = shape
	col.position = Vector3(0, 0.9, 0)
	add_child(col)

	# ── Third-person camera ───────────────────────────────────────────────
	_camera = Camera3D.new()
	_camera.name = "ThirdPersonCam"
	_camera.current = true
	_camera.fov = 70.0
	_camera.far = 2000.0
	add_child(_camera)


func _unhandled_input(event: InputEvent):
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch += event.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, -0.3, 0.8)

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float):
	# ── Gravity ───────────────────────────────────────────────────────────
	if not is_on_floor():
		velocity.y -= gravity_strength * delta

	# ── Jump ──────────────────────────────────────────────────────────────
	if Input.is_key_pressed(KEY_SPACE) and is_on_floor():
		velocity.y = jump_velocity

	# ── Movement ──────────────────────────────────────────────────────────
	var input_dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir.y -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1
	input_dir = input_dir.normalized()

	var speed := run_speed if Input.is_key_pressed(KEY_SHIFT) else walk_speed
	var cam_basis := Basis(Vector3.UP, _yaw)
	var direction := cam_basis * Vector3(input_dir.x, 0, input_dir.y)

	if direction.length() > 0.01:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		var target_angle := atan2(direction.x, direction.z)
		_body_pivot.rotation.y = lerp_angle(_body_pivot.rotation.y, target_angle, 10.0 * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, speed * 5.0 * delta)
		velocity.z = move_toward(velocity.z, 0, speed * 5.0 * delta)

	move_and_slide()

	# ── Camera orbit ──────────────────────────────────────────────────────
	var target := global_position + Vector3(0, 1.2, 0)
	var cam_offset := Vector3(
		sin(_yaw) * cos(_pitch) * cam_distance,
		sin(_pitch) * cam_distance + cam_height,
		cos(_yaw) * cos(_pitch) * cam_distance
	)
	_camera.global_position = target + cam_offset
	_camera.look_at(target, Vector3.UP)
