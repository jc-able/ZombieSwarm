extends CharacterBody3D

var running := false
var run_speed := 7.0  # m/s — fast zombie sprint
var run_direction := Vector3(0, 0, -1)

var _gravity := 30.0
var _model_pivot: Node3D
var _anim_player: AnimationPlayer
var _arrow: Node3D
var _anim_name := ""


func _ready():
	collision_mask = 7  # Detect terrain (layer 1) + obstacles (layer 2) + railings (layer 3)

	# ── Collision capsule ─────────────────────────────────────────────────
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 1.7
	col.shape = shape
	col.position = Vector3(0, 0.85, 0)
	add_child(col)

	# ── Model pivot (rotates to face run direction) ───────────────────────
	_model_pivot = Node3D.new()
	_model_pivot.name = "ModelPivot"
	add_child(_model_pivot)

	# ── Load and instantiate the zombie FBX ───────────────────────────────
	var zombie_scene := load("res://ZombieFastRun_FBX.fbx") as PackedScene
	if zombie_scene:
		var model := zombie_scene.instantiate()
		_model_pivot.add_child(model)

		# Find AnimationPlayer
		_anim_player = _find_anim_player(model)
		if _anim_player:
			var anims := _anim_player.get_animation_list()
			print("Zombie animations: ", anims)
			# Prefer "mixamo_com" animation (the actual run cycle)
			for a in anims:
				if a == "mixamo_com":
					_anim_name = a
					break
			# Fallback: pick any non-RESET, non-"Take 001" animation
			if _anim_name == "":
				for a in anims:
					if a != "RESET" and a != "Take 001":
						_anim_name = a
						break
			# Last resort: first non-RESET
			if _anim_name == "":
				for a in anims:
					if a != "RESET":
						_anim_name = a
						break
			print("Zombie using animation: ", _anim_name)

		# Auto-scale: use recursive AABB to measure actual model bounds
		var height := _measure_height_recursive(model)
		print("Zombie raw height: ", height)
		if height > 0.01:
			var target := 1.8
			var sf := target / height
			if absf(sf - 1.0) > 0.1:
				model.scale = Vector3.ONE * sf
				print("Zombie scaled by: ", sf)
		else:
			# Fallback: Mixamo models are typically ~1.0 unit tall, scale to 1.8
			model.scale = Vector3.ONE * 1.8
			print("Zombie height detection failed, using fallback scale 1.8")

	# ── Direction arrow (visible during setup) ────────────────────────────
	_build_arrow()
	_update_facing()


# ── Public API ────────────────────────────────────────────────────────────────

func set_direction(dir: Vector3):
	run_direction = Vector3(dir.x, 0, dir.z).normalized()
	_update_facing()


func rotate_direction(angle: float):
	run_direction = run_direction.rotated(Vector3.UP, angle)
	_update_facing()


func start_running():
	running = true
	if _arrow:
		_arrow.visible = false
	if _anim_player and _anim_name != "":
		# Ensure the animation loops
		var anim := _anim_player.get_animation(_anim_name)
		if anim:
			anim.loop_mode = Animation.LOOP_LINEAR
		_anim_player.play(_anim_name)
		print("Playing animation: ", _anim_name)


func stop_running():
	running = false
	velocity = Vector3.ZERO
	if _arrow:
		_arrow.visible = true
	if _anim_player:
		_anim_player.stop()


# ── Physics ───────────────────────────────────────────────────────────────────

func _physics_process(delta: float):
	if not is_on_floor():
		velocity.y -= _gravity * delta

	if running:
		velocity.x = run_direction.x * run_speed
		velocity.z = run_direction.z * run_speed
	else:
		velocity.x = 0
		velocity.z = 0

	move_and_slide()


# ── Internal helpers ──────────────────────────────────────────────────────────

func _update_facing():
	if run_direction.length() > 0.01 and _model_pivot:
		_model_pivot.rotation.y = atan2(run_direction.x, run_direction.z)


func _build_arrow():
	_arrow = Node3D.new()
	_arrow.name = "DirectionArrow"
	_model_pivot.add_child(_arrow)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0.15, 0.15, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	# Shaft — points in +Z direction (run direction in pivot local space)
	var shaft := MeshInstance3D.new()
	var shaft_mesh := BoxMesh.new()
	shaft_mesh.size = Vector3(0.15, 0.08, 3.0)
	shaft.mesh = shaft_mesh
	shaft.material_override = mat
	shaft.position = Vector3(0, 0.05, 2.5)
	_arrow.add_child(shaft)

	# Arrowhead (diamond) at tip
	var head := MeshInstance3D.new()
	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.6, 0.08, 0.6)
	head.mesh = head_mesh
	head.material_override = mat
	head.position = Vector3(0, 0.05, 4.2)
	head.rotation.y = PI / 4.0
	_arrow.add_child(head)


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var result := _find_anim_player(child)
		if result:
			return result
	return null


func _measure_height_recursive(node: Node) -> float:
	var max_y := 0.0
	_scan_meshes(node, max_y)
	return max_y


func _scan_meshes(node: Node, max_y: float) -> float:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			var aabb := mi.mesh.get_aabb()
			# Walk up the node hierarchy to accumulate scale and position
			var accumulated_scale := 1.0
			var accumulated_y := 0.0
			var current: Node = mi
			while current and current is Node3D:
				var n3d := current as Node3D
				accumulated_y += n3d.position.y * accumulated_scale
				accumulated_scale *= n3d.scale.y if n3d.scale.y != 0 else 1.0
				current = current.get_parent()
				# Stop at the CharacterBody3D (our root)
				if current is CharacterBody3D:
					break
			var top := accumulated_y + (aabb.position.y + aabb.size.y) * accumulated_scale
			max_y = maxf(max_y, top)
	for child in node.get_children():
		max_y = _scan_meshes(child, max_y)
	return max_y
