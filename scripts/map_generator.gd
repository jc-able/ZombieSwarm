extends Node3D

# ══════════════════════════════════════════════════════════════════════════════
# SCALE REFERENCE: 1 unit ≈ 1 meter
# Car ≈ 4.5m long, Golden Gate Bridge ≈ 2700m long / 27m wide
# Bridge here: 250m long (fits ~55 cars end-to-end), 28m wide (6 lanes)
# ══════════════════════════════════════════════════════════════════════════════

# ── Mountain geometry ─────────────────────────────────────────────────────────
const MTN_X := 250.0  # Mountain center X offset (500m apart)

# Each layer: [size_x, size_y, size_z, center_y]
const MTN_LAYERS: Array = [
	[350, 30, 350, 15.0],    # Base
	[310, 25, 310, 42.5],    # Mid
	[280, 20, 280, 65.0],    # Upper
	[260, 12, 260, 81.0],    # Top
	[250, 3, 250, 88.5],     # Plateau
]
const PLATEAU_Y := 90.0  # Surface height (top of plateau)

# ── Bridge geometry ──────────────────────────────────────────────────────────
const BRIDGE_LENGTH := 250.0
const BRIDGE_WIDTH := 28.0
const BRIDGE_Z_POS: Array = [-50.0, 50.0]

# ── City street layout (city-local coords) ───────────────────────────────────
const STREET_WIDTH := 12.0
const STREET_EW_Z: Array = [-80.0, -50.0, 0.0, 50.0, 80.0]
const STREET_NS_X: Array = [-80.0, -50.0, 0.0, 50.0, 80.0]
const STREET_LENGTH := 240.0

# ── Car dimensions (realistic) ───────────────────────────────────────────────
const CAR_EW := Vector3(4.5, 1.5, 2.0)  # East-west oriented
const CAR_NS := Vector3(2.0, 1.5, 4.5)  # North-south oriented

# ── Palette ──────────────────────────────────────────────────────────────────
const C_MTN := Color(0.45, 0.35, 0.25)
const C_PLAT := Color(0.3, 0.50, 0.2)
const C_BRIDGE := Color(0.6, 0.6, 0.6)
const C_TOWER := Color(0.75, 0.27, 0.07)  # International Orange
const C_ROAD := Color(0.15, 0.15, 0.15)
const C_GROUND := Color(0.25, 0.20, 0.15)

const C_BLDG: Array = [
	Color(0.78, 0.78, 0.82),
	Color(0.55, 0.52, 0.48),
	Color(0.68, 0.63, 0.58),
	Color(0.82, 0.78, 0.72),
	Color(0.52, 0.56, 0.62),
	Color(0.45, 0.42, 0.55),
	Color(0.72, 0.68, 0.55),
]

const C_CAR: Array = [
	Color(0.85, 0.10, 0.10),
	Color(0.10, 0.20, 0.85),
	Color(0.92, 0.92, 0.92),
	Color(0.12, 0.12, 0.12),
	Color(0.90, 0.80, 0.10),
	Color(0.10, 0.60, 0.20),
	Color(0.60, 0.10, 0.60),
]

var _mat_cache := {}

# ── Mode state ───────────────────────────────────────────────────────────────
var _god_mode := false
var _drone_active := false
var _pre_drone_god := false  # Was god mode active before drone?
var _bean: CharacterBody3D
var _fly_cam: Camera3D
var _hud_label: Label

# ── Zombie state ─────────────────────────────────────────────────────────────
var _active_zombie = null
var _zombie_running := false
var _drone_cam: Camera3D = null
const ZombieController = preload("res://scripts/zombie_controller.gd")

# ── Swarm state ──────────────────────────────────────────────────────────────
var _swarm: Node3D = null
const ZombieSwarm = preload("res://scripts/zombie_swarm.gd")


func _ready():
	_build_ground()
	_build_mountain(Vector3(-MTN_X, 0, 0), "Mountain_West")
	_build_mountain(Vector3(MTN_X, 0, 0), "Mountain_East")
	_build_bridges()
	_build_city(Vector3(-MTN_X, PLATEAU_Y, 0), "City_West")
	_build_city(Vector3(MTN_X, PLATEAU_Y, 0), "City_East")
	_build_hud()

	# Mode switching setup
	_bean = get_node("Bean")
	_fly_cam = get_node("FlyCamera")

	# Drone camera (created once, reused)
	_drone_cam = Camera3D.new()
	_drone_cam.name = "DroneCam"
	_drone_cam.fov = 70.0
	_drone_cam.far = 2000.0
	add_child(_drone_cam)

	# Create persistent swarm node and bake map data after physics is ready
	var swarm_node := Node3D.new()
	swarm_node.name = "ZombieSwarm"
	swarm_node.set_script(ZombieSwarm)
	add_child(swarm_node)
	_swarm = swarm_node
	_swarm.bake_map_data.call_deferred()

	_activate_bean_mode()


func _unhandled_input(event: InputEvent):
	if not (event is InputEventKey and event.pressed):
		return

	var key: int = event.keycode

	# ── Tab: Bean ↔ God (exits drone first) ───────────────────────────────
	if key == KEY_TAB:
		if _drone_active:
			_deactivate_drone()
		_god_mode = !_god_mode
		if _god_mode:
			_activate_god_mode()
		else:
			_activate_bean_mode()

	# ── Z: Spawn zombie at bean position ──────────────────────────────────
	elif key == KEY_Z:
		_spawn_zombie()

	# ── Left / Right: Rotate zombie direction (before running) ────────────
	elif key == KEY_LEFT and _active_zombie and not _zombie_running:
		_active_zombie.rotate_direction(deg_to_rad(5.0))
		_update_hud()
	elif key == KEY_RIGHT and _active_zombie and not _zombie_running:
		_active_zombie.rotate_direction(deg_to_rad(-5.0))
		_update_hud()

	# ── Enter: Start zombie running ───────────────────────────────────────
	elif key == KEY_ENTER and _active_zombie and not _zombie_running:
		_zombie_running = true
		_active_zombie.start_running()
		_update_hud()

	# ── F: Toggle drone view ─────────────────────────────────────────────
	elif key == KEY_F and _active_zombie:
		if _drone_active:
			_deactivate_drone()
		else:
			_activate_drone()

	# ── S: Spawn zombie swarm ────────────────────────────────────────────
	elif key == KEY_S and not event.is_command_or_control_pressed():
		var count := 2000 if event.shift_pressed else 500
		_spawn_swarm(count)

	# ── Backspace: Clear swarm ───────────────────────────────────────────
	elif key == KEY_BACKSPACE and _swarm and _swarm._instance_count > 0:
		_clear_swarm()


func _process(_delta: float):
	# ── Update drone camera to follow zombie from front-aerial ────────────
	if _drone_active and _active_zombie and is_instance_valid(_active_zombie):
		var zpos: Vector3 = _active_zombie.global_position
		var zdir: Vector3 = _active_zombie.run_direction
		# Camera 12m ahead of zombie, 8m up — looking back at its face
		var cam_pos := zpos + zdir * 12.0 + Vector3(0, 8.0, 0)
		_drone_cam.global_position = cam_pos
		_drone_cam.look_at(zpos + Vector3(0, 1.2, 0), Vector3.UP)


# ── Zombie spawning ──────────────────────────────────────────────────────────

func _spawn_zombie():
	# Remove old zombie
	if _active_zombie and is_instance_valid(_active_zombie):
		if _drone_active:
			_deactivate_drone()
		_active_zombie.queue_free()
		_active_zombie = null

	_zombie_running = false

	# Create new zombie CharacterBody3D
	var zombie := CharacterBody3D.new()
	zombie.name = "Zombie"
	zombie.set_script(ZombieController)
	add_child(zombie)
	# Set position AFTER adding to tree to avoid global_transform error
	zombie.global_position = _bean.global_position + Vector3(0, 0.5, 0)
	_active_zombie = zombie

	# Face the zombie in the bean's camera yaw direction
	var yaw: float = _bean._yaw
	var dir := Vector3(sin(yaw), 0, cos(yaw))
	_active_zombie.call_deferred("set_direction", dir)

	_update_hud()


# ── Swarm spawning ───────────────────────────────────────────────────────────

func _spawn_swarm(count: int):
	# Clear previous instances (keeps baked map data)
	if _swarm and is_instance_valid(_swarm):
		_swarm.clear_swarm()

	# Spawn at bean position, facing bean's camera direction
	var yaw: float = _bean._yaw
	var dir := Vector3(-sin(yaw), 0, -cos(yaw))
	_swarm.spawn_swarm(_bean.global_position, dir, count)

	_update_hud()


func _clear_swarm():
	if _swarm and is_instance_valid(_swarm):
		_swarm.clear_swarm()
	_update_hud()


# ── Mode activation ──────────────────────────────────────────────────────────

func _activate_god_mode():
	_fly_cam.global_position = _bean.global_position + Vector3(0, 50, 50)
	_fly_cam._pitch = -0.30
	_fly_cam._yaw = 0.0
	_fly_cam.rotation = Vector3(-0.30, 0, 0)
	_fly_cam.current = true
	_fly_cam.set_process(true)
	_fly_cam.set_process_unhandled_input(true)
	_bean.set_physics_process(false)
	_bean.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_hud()


func _activate_bean_mode():
	var bean_cam: Camera3D = _bean.get_node("ThirdPersonCam")
	bean_cam.current = true
	_bean.set_physics_process(true)
	_bean.set_process_unhandled_input(true)
	_fly_cam.set_process(false)
	_fly_cam.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_hud()


func _activate_drone():
	if not _active_zombie:
		return
	_pre_drone_god = _god_mode
	_drone_active = true
	_drone_cam.current = true
	# Disable both bean and fly cam input
	_bean.set_physics_process(false)
	_bean.set_process_unhandled_input(false)
	_fly_cam.set_process(false)
	_fly_cam.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_update_hud()


func _deactivate_drone():
	_drone_active = false
	# Restore previous mode
	if _pre_drone_god:
		_god_mode = true
		_activate_god_mode()
	else:
		_god_mode = false
		_activate_bean_mode()


# ── HUD ──────────────────────────────────────────────────────────────────────

func _update_hud():
	if not _hud_label:
		return

	if _drone_active:
		_hud_label.text = "[DRONE VIEW] F: Exit Drone | Tab: Bean/God Mode"
		return

	var zombie_hint := ""
	if _active_zombie and not _zombie_running:
		zombie_hint = "\nLeft/Right: Rotate Zombie | Enter: Start Running | F: Drone"
	elif _active_zombie and _zombie_running:
		zombie_hint = " | F: Drone View"

	var swarm_hint := "\nS: Swarm (500) | Shift+S: Swarm (2000)"
	if _swarm and _swarm._instance_count > 0:
		swarm_hint += " | Backspace: Clear Swarm"

	if _god_mode:
		_hud_label.text = "[GOD MODE] WASD: Fly | Mouse: Look | Space/Shift: Up/Down | Ctrl: Fast | Tab: Bean | Z: Zombie" + zombie_hint + swarm_hint
	else:
		_hud_label.text = "[BEAN MODE] WASD: Move | Mouse: Look | Space: Jump | Shift: Run | Tab: God | Z: Zombie" + zombie_hint + swarm_hint


# ── Shared material cache for performance ────────────────────────────────────
func _get_mat(color: Color) -> StandardMaterial3D:
	if not _mat_cache.has(color):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		_mat_cache[color] = mat
	return _mat_cache[color]


# ── Helper: create a StaticBody3D box with mesh + collision ──────────────────
# col_layer: 1 = terrain (ground, mountains, bridges), 2 = obstacles (buildings, cars)
func _box(parent: Node3D, pos: Vector3, size: Vector3, color: Color, nname: String, col_layer: int = 1) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = nname
	body.position = pos
	body.collision_layer = col_layer
	parent.add_child(body)

	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _get_mat(color)
	body.add_child(mi)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	return body


# ── Ground plane ─────────────────────────────────────────────────────────────
func _build_ground():
	_box(self, Vector3(0, -5, 0), Vector3(800, 10, 800), C_GROUND, "Ground")


# ── Stepped mountain ─────────────────────────────────────────────────────────
func _build_mountain(center: Vector3, mtn_name: String):
	var mtn := Node3D.new()
	mtn.name = mtn_name
	mtn.position = center
	add_child(mtn)

	for i in range(MTN_LAYERS.size()):
		var L = MTN_LAYERS[i]
		var color := C_MTN if i < MTN_LAYERS.size() - 1 else C_PLAT
		_box(mtn, Vector3(0, L[3], 0), Vector3(L[0], L[1], L[2]), color, "Layer_%d" % i)


# ── Two Golden-Gate-style bridges ────────────────────────────────────────────
func _build_bridges():
	var bridges := Node3D.new()
	bridges.name = "Bridges"
	add_child(bridges)

	var half_w := BRIDGE_WIDTH / 2.0

	for i in range(BRIDGE_Z_POS.size()):
		var bz: float = BRIDGE_Z_POS[i]
		var b := Node3D.new()
		b.name = "Bridge_%d" % i
		bridges.add_child(b)

		# ── Deck ──────────────────────────────────────────────────────────
		_box(b, Vector3(0, PLATEAU_Y - 1.0, bz),
			Vector3(BRIDGE_LENGTH, 2.0, BRIDGE_WIDTH), C_BRIDGE, "Deck")

		# ── Road surface ──────────────────────────────────────────────────
		_box(b, Vector3(0, PLATEAU_Y + 0.15, bz),
			Vector3(BRIDGE_LENGTH - 4, 0.3, BRIDGE_WIDTH - 4), C_ROAD, "Road")

		# ── Center lane line ──────────────────────────────────────────────
		_box(b, Vector3(0, PLATEAU_Y + 0.32, bz),
			Vector3(BRIDGE_LENGTH - 6, 0.04, 0.3), Color(0.9, 0.8, 0.1), "CenterLine")

		# ── Railings (layer 3 — swarm ignores, player/zombie still collide) ──
		_box(b, Vector3(0, PLATEAU_Y + 1.5, bz - half_w - 0.75),
			Vector3(BRIDGE_LENGTH, 3.0, 1.5), C_TOWER, "Railing_L", 3)
		_box(b, Vector3(0, PLATEAU_Y + 1.5, bz + half_w + 0.75),
			Vector3(BRIDGE_LENGTH, 3.0, 1.5), C_TOWER, "Railing_R", 3)

		# ── Support pillars (outside the roadway, beyond railings) ───
		for px in [-40.0, 0.0, 40.0]:
			var pillar_h := PLATEAU_Y - 1.0
			_box(b, Vector3(px, pillar_h / 2.0, bz - half_w - 2.5),
				Vector3(4, pillar_h, 4), C_BRIDGE, "PillarL_%d" % int(px + 100), 2)
			_box(b, Vector3(px, pillar_h / 2.0, bz + half_w + 2.5),
				Vector3(4, pillar_h, 4), C_BRIDGE, "PillarR_%d" % int(px + 100), 2)

		# ── Tower structures (Golden Gate style, legs outside roadway) ──
		for tx in [-70.0, 70.0]:
			var tower_top := PLATEAU_Y + 65.0
			var tower_h := tower_top
			_box(b, Vector3(tx, tower_h / 2.0, bz - half_w - 2.5),
				Vector3(6, tower_h, 6), C_TOWER, "TwrL_%d" % int(tx + 100), 2)
			_box(b, Vector3(tx, tower_h / 2.0, bz + half_w + 2.5),
				Vector3(6, tower_h, 6), C_TOWER, "TwrR_%d" % int(tx + 100), 2)
			_box(b, Vector3(tx, tower_top - 4, bz),
				Vector3(6, 8, 26), C_TOWER, "TopBeam_%d" % int(tx + 100), 2)
			_box(b, Vector3(tx, PLATEAU_Y + 30, bz),
				Vector3(5, 5, 24), C_TOWER, "MidBeam_%d" % int(tx + 100), 2)

		# ── Cars on the bridge ───────────────────────────────────────────
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("bridge_%d" % i)
		for k in range(25):
			var cx := rng.randf_range(-110, 110)
			var lane := rng.randf_range(-8.0, 8.0)
			var cc: Color = C_CAR[rng.randi() % C_CAR.size()]
			_box(b, Vector3(cx, PLATEAU_Y + 1.05, bz + lane),
				CAR_EW, cc, "BrCar_%d" % k, 2)


# ── City generator ───────────────────────────────────────────────────────────
func _build_city(center: Vector3, city_name: String):
	var city := Node3D.new()
	city.name = city_name
	city.position = center
	add_child(city)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(city_name)

	# ── Streets ───────────────────────────────────────────────────────────
	var streets := Node3D.new()
	streets.name = "Streets"
	city.add_child(streets)

	for si in range(STREET_EW_Z.size()):
		_box(streets, Vector3(0, 0.15, STREET_EW_Z[si]),
			Vector3(STREET_LENGTH, 0.3, STREET_WIDTH), C_ROAD, "EW_%d" % si)

	for si in range(STREET_NS_X.size()):
		_box(streets, Vector3(STREET_NS_X[si], 0.15, 0),
			Vector3(STREET_WIDTH, 0.3, STREET_LENGTH), C_ROAD, "NS_%d" % si)

	# ── Compute building block regions ────────────────────────────────────
	var x_bounds := _block_edges(STREET_NS_X, 120.0)
	var z_bounds := _block_edges(STREET_EW_Z, 120.0)

	var bldgs := Node3D.new()
	bldgs.name = "Buildings"
	city.add_child(bldgs)

	var bidx := 0
	for xi in range(0, x_bounds.size(), 2):
		var x0: float = x_bounds[xi]
		var x1: float = x_bounds[xi + 1]
		for zi in range(0, z_bounds.size(), 2):
			var z0: float = z_bounds[zi]
			var z1: float = z_bounds[zi + 1]
			var bw := x1 - x0
			var bd := z1 - z0
			if bw < 6 or bd < 6:
				continue

			var num := rng.randi_range(3, 6)
			for _j in range(num):
				# Height distribution: some low, some mid, some tall
				var roll := rng.randf()
				var h: float
				if roll < 0.30:
					h = rng.randf_range(8.0, 20.0)
				elif roll < 0.60:
					h = rng.randf_range(22.0, 45.0)
				elif roll < 0.85:
					h = rng.randf_range(48.0, 80.0)
				else:
					h = rng.randf_range(85.0, 130.0)

				var max_w := minf(bw - 3, 28.0)
				var max_d := minf(bd - 3, 28.0)
				if max_w < 5.0:
					max_w = 5.0
				if max_d < 5.0:
					max_d = 5.0

				var w := rng.randf_range(5.0, max_w)
				var d := rng.randf_range(5.0, max_d)

				# Position within block (clamped so building stays inside)
				var px := _rand_clamped(rng, x0 + w / 2.0, x1 - w / 2.0)
				var pz := _rand_clamped(rng, z0 + d / 2.0, z1 - d / 2.0)
				var c: Color = C_BLDG[rng.randi() % C_BLDG.size()]
				_box(bldgs, Vector3(px, h / 2.0, pz), Vector3(w, h, d), c, "B_%d" % bidx, 2)
				bidx += 1

	# ── Cars on city streets ──────────────────────────────────────────────
	var cars := Node3D.new()
	cars.name = "Cars"
	city.add_child(cars)

	var cidx := 0
	for z in STREET_EW_Z:
		for _k in range(10):
			var cx := rng.randf_range(-110, 110)
			var lane := rng.randf_range(-4.0, 4.0)
			var cc: Color = C_CAR[rng.randi() % C_CAR.size()]
			_box(cars, Vector3(cx, 1.05, z + lane), CAR_EW, cc, "C_%d" % cidx, 2)
			cidx += 1

	for x in STREET_NS_X:
		for _k in range(10):
			var cz := rng.randf_range(-110, 110)
			var lane := rng.randf_range(-4.0, 4.0)
			var cc: Color = C_CAR[rng.randi() % C_CAR.size()]
			_box(cars, Vector3(x + lane, 1.05, cz), CAR_NS, cc, "C_%d" % cidx, 2)
			cidx += 1


# ── Compute block edges from street positions ────────────────────────────────
func _block_edges(street_positions: Array, edge: float) -> Array:
	var bounds: Array = [-edge]
	for s in street_positions:
		bounds.append(s - STREET_WIDTH / 2.0 - 1.5)
		bounds.append(s + STREET_WIDTH / 2.0 + 1.5)
	bounds.append(edge)
	return bounds


# ── Random float clamped so min <= max ────────────────────────────────────────
func _rand_clamped(rng: RandomNumberGenerator, lo: float, hi: float) -> float:
	if lo >= hi:
		return (lo + hi) / 2.0
	return rng.randf_range(lo, hi)


# ── HUD ──────────────────────────────────────────────────────────────────────
func _build_hud():
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	canvas.add_child(panel)

	_hud_label = Label.new()
	_hud_label.add_theme_font_size_override("font_size", 14)
	panel.add_child(_hud_label)
