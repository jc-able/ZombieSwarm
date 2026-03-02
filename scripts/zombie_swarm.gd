extends Node3D

# ══════════════════════════════════════════════════════════════════════════════
# Zombie Swarm — Multi-Layer Map Scan + Flow Field (Zero Raycasts/Frame)
#
# Pre-bakes at game load (one-time cost):
#   1. Cascading terrain scan: finds ground AND upper surfaces (bridges, caves)
#   2. Per-layer obstacle scan: classifies obstacles at each level
#   3. Horizontal wall face scan: detects climbable surfaces at border cells
#   4. BFS flow field: routes around obstacles at ground level
#
# Each cell stores up to 2 layers:
#   Ground layer: _heightmap, _obstacle_type, _obstacle_top
#   Upper layer:  _upper_floor_y, _upper_obs_type, _upper_obs_top
#   Shared:       _ceiling_y (underside of upper floor)
#
# Per-frame simulation uses only O(1) array lookups per zombie.
# Zombie picks its layer based on current Y position.
# ══════════════════════════════════════════════════════════════════════════════

# ── Grid config ─────────────────────────────────────────────────────────────
const GRID_CELL := 2.0
const GRID_MIN := -430.0
const GRID_MAX := 430.0

# ── Obstacle types ──────────────────────────────────────────────────────────
const OBS_OPEN := 0
const OBS_CLIMBABLE := 1
const OBS_WALL := 2
const OBS_BUILDING := 3

# ── Wall face bitmask ──────────────────────────────────────────────────────
const WALL_FACE_EAST  := 1   # +X direction
const WALL_FACE_WEST  := 2   # -X direction
const WALL_FACE_SOUTH := 4   # +Z direction
const WALL_FACE_NORTH := 8   # -Z direction

# ── Thresholds ──────────────────────────────────────────────────────────────
const CLIMBABLE_MAX := 2.5
const BUILDING_MIN := 8.0

# ── Horizontal scan config ─────────────────────────────────────────────────
const SCAN_HEIGHTS: Array[float] = [1.0, 3.0, 6.0, 10.0, 20.0]
const H_RAY_LENGTH := 4.0
const CEILING_MIN_GAP := 3.0
const WALL_MIN_HITS := 2

# ── Zombie states ─────────────────────────────────────────────────────────
const STATE_RUNNING  := 0
const STATE_CLIMBING := 1
const STATE_FALLING  := 2
const STATE_START_CLIMB := 3
const STATE_STANDING_UP := 4
const CLIMB_CHECK_RANGE := 5  # cells to check in each perpendicular direction
const START_CLIMB_DURATION := 0.5  # seconds before climbing begins
const STANDING_UP_DURATION := 0.6  # seconds to recover from fall

# ── Physics ─────────────────────────────────────────────────────────────────
const GRAVITY := 20.0
const CLIMB_SPEED := 6.0

# ── Grid data — ground layer (baked once at load) ─────────────────────────
var _grid_size: int = 0
var _heightmap: PackedFloat32Array      # ground Y per cell (lowest walkable surface)
var _obstacle_top: PackedFloat32Array   # obstacle top Y at ground level (-9999 = none)
var _obstacle_type: PackedInt32Array    # obstacle classification at ground level
var _flow_x: PackedFloat32Array         # flow field X direction (ground level)
var _flow_z: PackedFloat32Array         # flow field Z direction (ground level)

# ── Grid data — upper layer (bridges, cave ceilings) ─────────────────────
var _upper_floor_y: PackedFloat32Array   # upper walkable surface Y (-9999 = single layer)
var _upper_obs_top: PackedFloat32Array   # obstacle top Y on upper level (-9999 = none)
var _upper_obs_type: PackedInt32Array    # obstacle classification on upper level
var _ceiling_y: PackedFloat32Array       # ceiling above ground layer (underside of upper)

# ── Wall face data (baked once at load) ───────────────────────────────────
var _wall_faces: PackedByteArray         # bitmask: which sides have wall surfaces
var _wall_bottom_y: PackedFloat32Array   # Y where climbing starts
var _wall_top_y: PackedFloat32Array      # Y where climbing ends (rooftop)
var _wall_normal_x: PackedFloat32Array   # outward surface normal X
var _wall_normal_z: PackedFloat32Array   # outward surface normal Z

# ── Instance data ───────────────────────────────────────────────────────────
var _multimesh_instance: MultiMeshInstance3D
var _multimesh: MultiMesh
var _running := false
var _speed := 7.0
var _instance_count := 0
var _using_vat := false

var _positions: PackedVector3Array
var _directions: PackedVector3Array     # current movement direction
var _home_directions: PackedVector3Array # per-zombie preferred direction (with jitter)
var _vel_y: PackedFloat32Array
var _steer_bias: PackedFloat32Array     # +1.0 or -1.0 per zombie (random left/right preference)
var _state: PackedInt32Array            # STATE_RUNNING / CLIMBING / FALLING
var _climb_target_y: PackedFloat32Array # wall_top_y to reach while climbing
var _climb_normal_x: PackedFloat32Array # wall normal X (for climbing orientation)
var _climb_normal_z: PackedFloat32Array # wall normal Z
var _time_offset: PackedFloat32Array   # per-instance animation time offset (for shader)
var _state_timer: PackedFloat32Array   # countdown for transition states

var _base_direction: Vector3
var _spawn_origin: Vector3


# ── Grid helpers ────────────────────────────────────────────────────────────

func _world_to_grid(wx: float, wz: float) -> Vector2i:
	var gx := int(floor((wx - GRID_MIN) / GRID_CELL))
	var gz := int(floor((wz - GRID_MIN) / GRID_CELL))
	return Vector2i(clampi(gx, 0, _grid_size - 1), clampi(gz, 0, _grid_size - 1))


func _grid_idx(gx: int, gz: int) -> int:
	return gz * _grid_size + gx


# ── Bake heightmap + obstacle map (cascading multi-layer scan) ────────────

func _bake_maps():
	_grid_size = int(ceil((GRID_MAX - GRID_MIN) / GRID_CELL))
	var total := _grid_size * _grid_size

	# Ground layer
	_heightmap = PackedFloat32Array()
	_obstacle_top = PackedFloat32Array()
	_obstacle_type = PackedInt32Array()
	_heightmap.resize(total)
	_obstacle_top.resize(total)
	_obstacle_type.resize(total)

	# Upper layer
	_upper_floor_y = PackedFloat32Array()
	_upper_obs_top = PackedFloat32Array()
	_upper_obs_type = PackedInt32Array()
	_ceiling_y = PackedFloat32Array()
	_upper_floor_y.resize(total)
	_upper_obs_top.resize(total)
	_upper_obs_type.resize(total)
	_ceiling_y.resize(total)

	_upper_floor_y.fill(-9999.0)
	_upper_obs_top.fill(-9999.0)
	_upper_obs_type.fill(OBS_OPEN)
	_ceiling_y.fill(-9999.0)

	var space := get_world_3d().direct_space_state
	if not space:
		push_warning("ZombieSwarm: No physics space for baking")
		_heightmap.fill(0.0)
		_obstacle_top.fill(-9999.0)
		_obstacle_type.fill(OBS_OPEN)
		return

	var t0 := Time.get_ticks_msec()
	var two_layer_count := 0

	for gz in range(_grid_size):
		for gx in range(_grid_size):
			var wx := GRID_MIN + (float(gx) + 0.5) * GRID_CELL
			var wz := GRID_MIN + (float(gz) + 0.5) * GRID_CELL
			var idx := _grid_idx(gx, gz)

			# ── Cascading terrain scan (layer 1) ─────────────────────
			# First hit from top — may be bridge deck, mountain, or ground
			var gq := PhysicsRayQueryParameters3D.create(
				Vector3(wx, 300.0, wz), Vector3(wx, -50.0, wz))
			gq.collision_mask = 1
			var gh := space.intersect_ray(gq)
			var top_y: float = gh["position"].y if gh else 0.0

			# Try to find a LOWER surface (ground under bridge/cave)
			var ground_y := top_y
			var has_upper := false
			if gh:
				var gq2 := PhysicsRayQueryParameters3D.create(
					Vector3(wx, top_y - 1.0, wz), Vector3(wx, -50.0, wz))
				gq2.collision_mask = 1
				var gh2 := space.intersect_ray(gq2)
				if gh2:
					var lower_y: float = gh2["position"].y
					if (top_y - lower_y) > CEILING_MIN_GAP:
						# Two layers: upper = bridge/cave ceiling, lower = ground
						ground_y = lower_y
						_upper_floor_y[idx] = top_y
						_ceiling_y[idx] = top_y
						has_upper = true
						two_layer_count += 1

			_heightmap[idx] = ground_y

			# ── Ground-level obstacle scan ────────────────────────────
			# Cast from just below ceiling (or from 300 if single layer)
			var obs_from_y := (_ceiling_y[idx] - 0.5) if has_upper else 300.0
			var oq := PhysicsRayQueryParameters3D.create(
				Vector3(wx, obs_from_y, wz), Vector3(wx, ground_y - 1.0, wz))
			oq.collision_mask = 2
			var oh := space.intersect_ray(oq)

			if oh:
				var otop: float = oh["position"].y
				var oheight := otop - ground_y
				_obstacle_top[idx] = otop
				if oheight > BUILDING_MIN:
					_obstacle_type[idx] = OBS_BUILDING
				elif oheight > CLIMBABLE_MAX:
					_obstacle_type[idx] = OBS_WALL
				else:
					_obstacle_type[idx] = OBS_CLIMBABLE
			else:
				_obstacle_top[idx] = -9999.0
				_obstacle_type[idx] = OBS_OPEN

			# ── Upper-level obstacle scan (if 2 layers) ──────────────
			if has_upper:
				var uoq := PhysicsRayQueryParameters3D.create(
					Vector3(wx, 300.0, wz), Vector3(wx, top_y + 0.5, wz))
				uoq.collision_mask = 2
				var uoh := space.intersect_ray(uoq)
				if uoh:
					var utop: float = uoh["position"].y
					var uheight := utop - top_y
					_upper_obs_top[idx] = utop
					if uheight > BUILDING_MIN:
						_upper_obs_type[idx] = OBS_BUILDING
					elif uheight > CLIMBABLE_MAX:
						_upper_obs_type[idx] = OBS_WALL
					else:
						_upper_obs_type[idx] = OBS_CLIMBABLE

	print("Bake maps: ", Time.get_ticks_msec() - t0, "ms (", total,
		" cells, ", two_layer_count, " two-layer cells)")

	# ── Post-process: classify steep terrain as walls ────────────────────
	# If a cell's highest surface is much higher than a neighbor's highest
	# surface, the cliff edge is impassable from below — treat it like a
	# building/wall. Uses max(heightmap, upper_floor_y) so stacked mountain
	# layers (where cascading scan creates 2-layer cells) are handled.
	var t1 := Time.get_ticks_msec()
	var terrain_wall_count := 0
	var c_nbrs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	]

	for gz in range(_grid_size):
		for gx in range(_grid_size):
			var idx := _grid_idx(gx, gz)
			# Skip cells already classified as obstacles
			if _obstacle_type[idx] >= OBS_WALL:
				continue

			# Use highest surface at this cell (upper layer if it exists)
			var height: float = _heightmap[idx]
			if _upper_floor_y[idx] > -9000.0:
				height = maxf(height, _upper_floor_y[idx])
			var max_drop := 0.0

			for nb in c_nbrs:
				var ngx := gx + nb.x
				var ngz := gz + nb.y
				if ngx < 0 or ngx >= _grid_size or ngz < 0 or ngz >= _grid_size:
					continue
				var nidx := _grid_idx(ngx, ngz)
				# Use highest surface at the neighbor too
				var n_height: float = _heightmap[nidx]
				if _upper_floor_y[nidx] > -9000.0:
					n_height = maxf(n_height, _upper_floor_y[nidx])
				var drop := height - n_height
				if drop > max_drop:
					max_drop = drop

			if max_drop > BUILDING_MIN:
				_obstacle_type[idx] = OBS_BUILDING
				_obstacle_top[idx] = height
				terrain_wall_count += 1
			elif max_drop > CLIMBABLE_MAX:
				_obstacle_type[idx] = OBS_WALL
				_obstacle_top[idx] = height
				terrain_wall_count += 1

	print("Terrain wall classification: ", Time.get_ticks_msec() - t1, "ms, ",
		terrain_wall_count, " cliff cells marked")

	# Horizontal wall face scan
	_bake_wall_faces(space)


# ── Bake wall faces (horizontal raycasts at border cells) ─────────────────

func _bake_wall_faces(space: PhysicsDirectSpaceState3D):
	var total := _grid_size * _grid_size
	var t0 := Time.get_ticks_msec()

	# Allocate arrays with sentinel values
	_wall_faces = PackedByteArray()
	_wall_bottom_y = PackedFloat32Array()
	_wall_top_y = PackedFloat32Array()
	_wall_normal_x = PackedFloat32Array()
	_wall_normal_z = PackedFloat32Array()

	_wall_faces.resize(total)
	_wall_bottom_y.resize(total)
	_wall_top_y.resize(total)
	_wall_normal_x.resize(total)
	_wall_normal_z.resize(total)

	_wall_faces.fill(0)
	_wall_bottom_y.fill(-9999.0)
	_wall_top_y.fill(-9999.0)
	_wall_normal_x.fill(0.0)
	_wall_normal_z.fill(0.0)

	# Cardinal direction vectors and their corresponding bitmask bits
	# [dir_x, dir_z, face_bit]
	var dirs: Array[Vector3i] = [
		Vector3i(1, 0, WALL_FACE_EAST),
		Vector3i(-1, 0, WALL_FACE_WEST),
		Vector3i(0, 1, WALL_FACE_SOUTH),
		Vector3i(0, -1, WALL_FACE_NORTH),
	]

	var border_count := 0
	var face_count := 0

	for gz in range(_grid_size):
		for gx in range(_grid_size):
			var idx := _grid_idx(gx, gz)

			# Use effective walking surface height (highest layer) so mountain
			# shelf cells scan from the correct elevation and detect the NEXT
			# step's wall rather than re-detecting the step they already climbed.
			var ground_y: float = _heightmap[idx]
			if _upper_floor_y[idx] > -9000.0:
				ground_y = maxf(ground_y, _upper_floor_y[idx])
			var wx := GRID_MIN + (float(gx) + 0.5) * GRID_CELL
			var wz := GRID_MIN + (float(gz) + 0.5) * GRID_CELL

			var face_mask := 0
			var best_wall_top := -9999.0
			var best_normal_x := 0.0
			var best_normal_z := 0.0
			var is_border := false

			for d in dirs:
				var nx := gx + d.x
				var nz := gz + d.y
				# Bounds check
				if nx < 0 or nx >= _grid_size or nz < 0 or nz >= _grid_size:
					continue
				var nidx := _grid_idx(nx, nz)

				# Check if neighbor is an obstacle (WALL/BUILDING) or a terrain cliff
				var is_obstacle_wall := _obstacle_type[nidx] >= OBS_WALL
				# Use highest surface at neighbor (upper layer for stacked mountain)
				var neighbor_top: float = _heightmap[nidx]
				if _upper_floor_y[nidx] > -9000.0:
					neighbor_top = maxf(neighbor_top, _upper_floor_y[nidx])
				var height_diff := neighbor_top - ground_y
				var is_terrain_cliff := height_diff > CLIMBABLE_MAX

				if not is_obstacle_wall and not is_terrain_cliff:
					continue

				is_border = true

				# Cast horizontal rays at multiple heights
				# Use mask 3 (terrain + obstacles) to detect both mountain walls and buildings
				var hit_count := 0
				var ray_dir := Vector3(float(d.x), 0.0, float(d.y))

				for h in SCAN_HEIGHTS:
					var scan_y := ground_y + h
					var origin := Vector3(wx, scan_y, wz)
					var target := origin + ray_dir * H_RAY_LENGTH
					var rq := PhysicsRayQueryParameters3D.create(origin, target)
					rq.collision_mask = 3
					var rh := space.intersect_ray(rq)
					if rh:
						hit_count += 1

				if hit_count >= WALL_MIN_HITS:
					face_mask |= d.z  # d.z holds the face bit
					face_count += 1

					# Wall top: use obstacle_top for buildings, highest surface for terrain
					var n_top: float
					if is_obstacle_wall:
						n_top = _obstacle_top[nidx]
					else:
						n_top = neighbor_top
					if n_top > best_wall_top:
						best_wall_top = n_top
						# Normal points AWAY from wall (toward this open cell)
						best_normal_x = -float(d.x)
						best_normal_z = -float(d.y)

			if is_border:
				border_count += 1

			if face_mask > 0:
				_wall_faces[idx] = face_mask
				_wall_bottom_y[idx] = ground_y
				_wall_top_y[idx] = best_wall_top
				_wall_normal_x[idx] = best_normal_x
				_wall_normal_z[idx] = best_normal_z

	print("Wall face bake: ", Time.get_ticks_msec() - t0, "ms, ",
		border_count, " border cells, ", face_count, " faces detected")



# ── Bake flow field via BFS ─────────────────────────────────────────────────

func _bake_flow_field():
	var total := _grid_size * _grid_size

	_flow_x = PackedFloat32Array()
	_flow_z = PackedFloat32Array()
	_flow_x.resize(total)
	_flow_z.resize(total)

	# Default: base direction everywhere
	for i in range(total):
		_flow_x[i] = _base_direction.x
		_flow_z[i] = _base_direction.z

	var visited := PackedInt32Array()
	visited.resize(total)
	visited.fill(0)

	var queue: Array[Vector2i] = []

	# Seed the goal edge(s) — the edge zombies are heading toward
	if absf(_base_direction.x) >= absf(_base_direction.z):
		var goal_gx := _grid_size - 1 if _base_direction.x > 0 else 0
		for gz in range(_grid_size):
			var idx := _grid_idx(goal_gx, gz)
			if _obstacle_type[idx] == OBS_OPEN or _obstacle_type[idx] == OBS_CLIMBABLE:
				queue.append(Vector2i(goal_gx, gz))
				visited[idx] = 1
	else:
		var goal_gz := _grid_size - 1 if _base_direction.z > 0 else 0
		for gx in range(_grid_size):
			var idx := _grid_idx(gx, goal_gz)
			if _obstacle_type[idx] == OBS_OPEN or _obstacle_type[idx] == OBS_CLIMBABLE:
				queue.append(Vector2i(gx, goal_gz))
				visited[idx] = 1

	# For diagonal movement, also seed the secondary edge
	if absf(_base_direction.x) > 0.3 and absf(_base_direction.z) > 0.3:
		if absf(_base_direction.x) < absf(_base_direction.z):
			var goal_gx := _grid_size - 1 if _base_direction.x > 0 else 0
			for gz in range(_grid_size):
				var idx := _grid_idx(goal_gx, gz)
				if visited[idx] == 0 and (_obstacle_type[idx] == OBS_OPEN or _obstacle_type[idx] == OBS_CLIMBABLE):
					queue.append(Vector2i(goal_gx, gz))
					visited[idx] = 1
		else:
			var goal_gz := _grid_size - 1 if _base_direction.z > 0 else 0
			for gx in range(_grid_size):
				var idx := _grid_idx(gx, goal_gz)
				if visited[idx] == 0 and (_obstacle_type[idx] == OBS_OPEN or _obstacle_type[idx] == OBS_CLIMBABLE):
					queue.append(Vector2i(gx, goal_gz))
					visited[idx] = 1

	# BFS expansion
	var t0 := Time.get_ticks_msec()
	var head := 0
	var nbrs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
	]

	while head < queue.size():
		var cell := queue[head]
		head += 1

		for n in nbrs:
			var nx := cell.x + n.x
			var nz := cell.y + n.y
			if nx < 0 or nx >= _grid_size or nz < 0 or nz >= _grid_size:
				continue
			var nidx := _grid_idx(nx, nz)
			if visited[nidx] == 1:
				continue
			# Block BFS through buildings AND walls (both impassable)
			if _obstacle_type[nidx] == OBS_BUILDING or _obstacle_type[nidx] == OBS_WALL:
				continue

			visited[nidx] = 1
			queue.append(Vector2i(nx, nz))

			# Direction: from this cell toward its parent (toward goal)
			var dx := float(cell.x - nx)
			var dz := float(cell.y - nz)
			var dlen := sqrt(dx * dx + dz * dz)
			if dlen > 0.001:
				_flow_x[nidx] = dx / dlen
				_flow_z[nidx] = dz / dlen

	print("Flow field BFS: ", Time.get_ticks_msec() - t0, "ms, ", queue.size(), " cells reached")


# ── Public: Bake map data (call once at world load, before any spawns) ────

var _maps_baked := false

func bake_map_data():
	_bake_maps()
	_maps_baked = true
	print("Map data baked and ready for swarm spawns")


# ── Spawn ────────────────────────────────────────────────────────────────────

func spawn_swarm(center: Vector3, direction: Vector3, count: int, spread: float = 1.5):
	clear_swarm()

	_base_direction = Vector3(direction.x, 0, direction.z).normalized()
	_spawn_origin = center
	_instance_count = count
	_running = true

	# Bake maps if not already done (fallback safety)
	if not _maps_baked:
		_bake_maps()
		_maps_baked = true

	# Flow field depends on direction — must be baked per spawn
	_bake_flow_field()

	_using_vat = (
		ResourceLoader.exists("res://zombie_static.glb") and
		ResourceLoader.exists("res://vat_position.exr")
	)

	# ── MultiMesh ────────────────────────────────────────────────────────
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_custom_data = true

	var material: ShaderMaterial
	if _using_vat:
		material = _setup_vat_mesh()
	else:
		material = _setup_placeholder_mesh()

	_multimesh.instance_count = count

	# ── Per-instance arrays ──────────────────────────────────────────────
	_positions = PackedVector3Array()
	_directions = PackedVector3Array()
	_home_directions = PackedVector3Array()
	_vel_y = PackedFloat32Array()
	_steer_bias = PackedFloat32Array()
	_positions.resize(count)
	_directions.resize(count)
	_home_directions.resize(count)
	_vel_y.resize(count)
	_steer_bias.resize(count)
	_state = PackedInt32Array()
	_climb_target_y = PackedFloat32Array()
	_climb_normal_x = PackedFloat32Array()
	_climb_normal_z = PackedFloat32Array()
	_state.resize(count)
	_climb_target_y.resize(count)
	_climb_normal_x.resize(count)
	_climb_normal_z.resize(count)
	_time_offset = PackedFloat32Array()
	_time_offset.resize(count)
	_state_timer = PackedFloat32Array()
	_state_timer.resize(count)

	# ── Grid placement ───────────────────────────────────────────────────
	var cols := ceili(sqrt(float(count)))
	var facing := atan2(_base_direction.x, _base_direction.z)

	for i in range(count):
		@warning_ignore("integer_division")
		var row := i / cols
		var col := i % cols

		var off_r := (col - cols / 2.0) * spread
		var off_b := (row - cols / 2.0) * spread

		var right := Vector3(_base_direction.z, 0, -_base_direction.x)
		var pos := center + right * off_r - _base_direction * off_b
		pos.x += randf_range(-0.3, 0.3)
		pos.z += randf_range(-0.3, 0.3)

		# Snap to baked ground height
		var gcell := _world_to_grid(pos.x, pos.z)
		var gidx := _grid_idx(gcell.x, gcell.y)
		pos.y = _heightmap[gidx]

		_positions[i] = pos
		var jitter := randf_range(-0.12, 0.12)
		var home_dir := _base_direction.rotated(Vector3.UP, jitter)
		_directions[i] = home_dir
		_home_directions[i] = home_dir
		_vel_y[i] = 0.0
		_steer_bias[i] = 1.0 if randf() > 0.5 else -1.0

		var t_off := randf_range(0.0, 2.0)
		_time_offset[i] = t_off

		var xform := Transform3D().rotated(Vector3.UP, facing + jitter)
		xform.origin = pos
		_multimesh.set_instance_transform(i, xform)
		_multimesh.set_instance_custom_data(i, Color(t_off, 0, 0, 0))

	# ── Node ─────────────────────────────────────────────────────────────
	_multimesh_instance = MultiMeshInstance3D.new()
	_multimesh_instance.multimesh = _multimesh
	_multimesh_instance.name = "ZombieSwarmMesh"
	if material:
		_multimesh_instance.material_override = material
	add_child(_multimesh_instance)

	print("Swarm spawned: ", count, " zombies (VAT: ", _using_vat, ")")


func clear_swarm():
	_running = false
	_instance_count = 0
	_positions = PackedVector3Array()
	_directions = PackedVector3Array()
	_home_directions = PackedVector3Array()
	_vel_y = PackedFloat32Array()
	_steer_bias = PackedFloat32Array()
	_state = PackedInt32Array()
	_climb_target_y = PackedFloat32Array()
	_climb_normal_x = PackedFloat32Array()
	_climb_normal_z = PackedFloat32Array()
	_time_offset = PackedFloat32Array()
	_state_timer = PackedFloat32Array()
	# NOTE: Map data (_heightmap, _obstacle_*, _upper_*, _wall_*, _ceiling_y)
	# is NOT cleared — baked once at load and reused across spawns.
	if _multimesh_instance and is_instance_valid(_multimesh_instance):
		_multimesh_instance.queue_free()
		_multimesh_instance = null
	_multimesh = null


# ── Main simulation loop (zero raycasts) ────────────────────────────────────

func _process(delta: float):
	if not _running or not _multimesh or _instance_count == 0:
		return

	for i in range(_instance_count):
		_simulate(i, delta)

	# Write transforms + state to INSTANCE_CUSTOM
	for i in range(_instance_count):
		var xform: Transform3D
		if _state[i] == STATE_CLIMBING or _state[i] == STATE_START_CLIMB:
			# Face the wall and tilt 90° to lie flat against it
			var wall_facing := atan2(-_climb_normal_x[i], -_climb_normal_z[i])
			xform = Transform3D()
			xform = xform.rotated(Vector3.UP, wall_facing)
			xform = xform.rotated(Vector3(1, 0, 0), -PI / 2.0)
		else:
			# Running or falling: face movement direction
			var dir := _directions[i]
			var f := atan2(dir.x, dir.z)
			xform = Transform3D().rotated(Vector3.UP, f)
		xform.origin = _positions[i]
		_multimesh.set_instance_transform(i, xform)
		_multimesh.set_instance_custom_data(i, Color(_time_offset[i], float(_state[i]), 0, 0))


# ── Climb heuristic: is the wall too wide to run around? ─────────────────

func _should_climb(gx: int, gz: int) -> bool:
	var idx := _grid_idx(gx, gz)
	var nx := _wall_normal_x[idx]
	var nz := _wall_normal_z[idx]

	# Along-wall direction (perpendicular to outward normal, rotated 90° CW)
	var along_x := int(round(nz))
	var along_z := int(round(-nx))
	if along_x == 0 and along_z == 0:
		return false

	# Direction toward the wall (opposite of outward normal)
	var tw_x := int(round(-nx))
	var tw_z := int(round(-nz))

	# Check both directions along the wall face
	var right_has_wall := false
	var left_has_wall := false

	for step in range(1, CLIMB_CHECK_RANGE + 1):
		# Right along wall: is there still a wall in that direction?
		var rx := gx + along_x * step
		var rz := gz + along_z * step
		if rx >= 0 and rx < _grid_size and rz >= 0 and rz < _grid_size:
			var wgx := rx + tw_x
			var wgz := rz + tw_z
			if wgx >= 0 and wgx < _grid_size and wgz >= 0 and wgz < _grid_size:
				if _obstacle_type[_grid_idx(wgx, wgz)] >= OBS_WALL:
					right_has_wall = true

		# Left along wall
		var lx := gx - along_x * step
		var lz := gz - along_z * step
		if lx >= 0 and lx < _grid_size and lz >= 0 and lz < _grid_size:
			var wgx := lx + tw_x
			var wgz := lz + tw_z
			if wgx >= 0 and wgx < _grid_size and wgz >= 0 and wgz < _grid_size:
				if _obstacle_type[_grid_idx(wgx, wgz)] >= OBS_WALL:
					left_has_wall = true

	return right_has_wall and left_has_wall


# ── Per-instance simulation (all grid lookups, no raycasts) ─────────────────

func _simulate(idx: int, delta: float):
	var pos := _positions[idx]
	var dir := _directions[idx]
	var state := _state[idx]

	# Current cell
	var gcell := _world_to_grid(pos.x, pos.z)
	var gidx := _grid_idx(gcell.x, gcell.y)

	# ── Determine which layer this zombie is on ──────────────────────────
	var on_upper := false
	var upper_y: float = _upper_floor_y[gidx]
	if upper_y > -9000.0:
		var mid_y := (_heightmap[gidx] + upper_y) * 0.5
		on_upper = pos.y > mid_y

	# ══════════════════════════════════════════════════════════════════════
	# STATE: START_CLIMB (brief pause at wall base before climbing)
	# ══════════════════════════════════════════════════════════════════════
	if state == STATE_START_CLIMB:
		_state_timer[idx] -= delta
		if _state_timer[idx] <= 0.0:
			_state[idx] = STATE_CLIMBING
		_positions[idx] = pos
		return

	# ══════════════════════════════════════════════════════════════════════
	# STATE: STANDING_UP (recovery after landing from fall)
	# ══════════════════════════════════════════════════════════════════════
	if state == STATE_STANDING_UP:
		_state_timer[idx] -= delta
		if _state_timer[idx] <= 0.0:
			_state[idx] = STATE_RUNNING
		_positions[idx] = pos
		return

	# ══════════════════════════════════════════════════════════════════════
	# STATE: CLIMBING
	# ══════════════════════════════════════════════════════════════════════
	if state == STATE_CLIMBING:
		var target_y := _climb_target_y[idx]

		# Move upward only — no horizontal drift
		pos.y += CLIMB_SPEED * delta

		# Reached the top → step onto rooftop
		if pos.y >= target_y - 0.3:
			pos.y = target_y + 0.1
			# Push past wall edge onto the rooftop (opposite of normal = into wall)
			var nx := _climb_normal_x[idx]
			var nz := _climb_normal_z[idx]
			pos.x -= nx * 3.0
			pos.z -= nz * 3.0
			_state[idx] = STATE_RUNNING
			_vel_y[idx] = 0.0

		_positions[idx] = pos
		return

	# ══════════════════════════════════════════════════════════════════════
	# STATE: FALLING
	# ══════════════════════════════════════════════════════════════════════
	if state == STATE_FALLING:
		# Horizontal drift at half speed (no steering)
		pos.x += dir.x * _speed * 0.5 * delta
		pos.z += dir.z * _speed * 0.5 * delta

		# Gravity
		_vel_y[idx] -= GRAVITY * delta
		pos.y += _vel_y[idx] * delta

		# Re-lookup grid after movement
		gcell = _world_to_grid(pos.x, pos.z)
		gidx = _grid_idx(gcell.x, gcell.y)

		# Determine floor at new position
		upper_y = _upper_floor_y[gidx]
		if upper_y > -9000.0:
			var mid_y := (_heightmap[gidx] + upper_y) * 0.5
			on_upper = pos.y > mid_y
		else:
			on_upper = false

		var f_layer_floor: float = upper_y if on_upper else _heightmap[gidx]
		var f_obs_top_y: float = (_upper_obs_top[gidx] if on_upper else _obstacle_top[gidx])
		var f_obs_type: int = (_upper_obs_type[gidx] if on_upper else _obstacle_type[gidx])

		var f_floor_y := f_layer_floor
		if f_obs_type == OBS_CLIMBABLE and f_obs_top_y > f_layer_floor:
			f_floor_y = f_obs_top_y
		elif f_obs_top_y > f_layer_floor and pos.y >= f_obs_top_y - 0.5:
			f_floor_y = f_obs_top_y

		# Landed → standing up recovery
		if pos.y <= f_floor_y + 0.2:
			pos.y = f_floor_y
			_vel_y[idx] = 0.0
			_state[idx] = STATE_STANDING_UP
			_state_timer[idx] = STANDING_UP_DURATION

		_positions[idx] = pos
		return

	# ══════════════════════════════════════════════════════════════════════
	# STATE: RUNNING (default — existing logic + climb/fall transitions)
	# ══════════════════════════════════════════════════════════════════════

	# Check 4m ahead in current direction using the correct layer
	var ax := pos.x + dir.x * 4.0
	var az := pos.z + dir.z * 4.0
	var ac := _world_to_grid(ax, az)
	var ai := _grid_idx(ac.x, ac.y)

	var ahead_upper_y: float = _upper_floor_y[ai]
	var ahead_on_upper := false
	if ahead_upper_y > -9000.0:
		var ahead_mid := (_heightmap[ai] + ahead_upper_y) * 0.5
		ahead_on_upper = pos.y > ahead_mid

	var ahead_obs: int = _upper_obs_type[ai] if ahead_on_upper else _obstacle_type[ai]
	var cur_blocked := ahead_obs == OBS_BUILDING or ahead_obs == OBS_WALL

	# ── Direction logic ──────────────────────────────────────────────────
	if cur_blocked:
		# Check if we should climb instead of steering around
		var wall_f := int(_wall_faces[gidx]) if gidx < _wall_faces.size() else 0
		if wall_f > 0 and _wall_top_y[gidx] > pos.y + 1.0 and _should_climb(gcell.x, gcell.y):
			# Transition to START_CLIMB (brief pause before climbing)
			_state[idx] = STATE_START_CLIMB
			_state_timer[idx] = START_CLIMB_DURATION
			_climb_target_y[idx] = _wall_top_y[gidx]
			_climb_normal_x[idx] = _wall_normal_x[gidx]
			_climb_normal_z[idx] = _wall_normal_z[gidx]
			_vel_y[idx] = 0.0
			# Snap to wall surface (one cell toward wall)
			pos.x -= _wall_normal_x[gidx] * GRID_CELL * 0.5
			pos.z -= _wall_normal_z[gidx] * GRID_CELL * 0.5
			_positions[idx] = pos
			return

		# Wall sliding / steering (existing logic)
		if wall_f > 0:
			var wall_n := Vector3(_wall_normal_x[gidx], 0, _wall_normal_z[gidx])
			if wall_n.length() > 0.01:
				var slide_dir := (dir - wall_n * dir.dot(wall_n)).normalized()
				var flow_dir := Vector3(_flow_x[gidx], 0, _flow_z[gidx])
				dir = (slide_dir * 0.5 + flow_dir * 0.5).normalized()
				_directions[idx] = dir
			else:
				wall_f = 0

		if wall_f == 0:
			# Standard steering: flow field + perpendicular checks
			var flow_dir := Vector3(_flow_x[gidx], 0, _flow_z[gidx])
			if on_upper:
				flow_dir = _base_direction
			var perp := Vector3(flow_dir.z, 0, -flow_dir.x)

			var rc := _world_to_grid(pos.x + perp.x * 6.0, pos.z + perp.z * 6.0)
			var ri := _grid_idx(rc.x, rc.y)
			var r_obs: int = _upper_obs_type[ri] if on_upper else _obstacle_type[ri]
			var r_blocked := r_obs >= OBS_WALL

			var lc := _world_to_grid(pos.x - perp.x * 6.0, pos.z - perp.z * 6.0)
			var li := _grid_idx(lc.x, lc.y)
			var l_obs: int = _upper_obs_type[li] if on_upper else _obstacle_type[li]
			var l_blocked := l_obs >= OBS_WALL

			var steer: Vector3
			if r_blocked and l_blocked:
				steer = flow_dir
			elif r_blocked:
				steer = (flow_dir - perp * 0.5).normalized()
			elif l_blocked:
				steer = (flow_dir + perp * 0.5).normalized()
			else:
				steer = (flow_dir + perp * _steer_bias[idx] * 0.4).normalized()

			dir = (dir * 0.3 + steer * 0.7).normalized()
			_directions[idx] = dir
	else:
		# Path clear — gently return to home direction if safe
		var home := _home_directions[idx]
		var hc := _world_to_grid(pos.x + home.x * 5.0, pos.z + home.z * 5.0)
		var hi := _grid_idx(hc.x, hc.y)
		var h_obs: int = _upper_obs_type[hi] if on_upper else _obstacle_type[hi]
		var home_blocked := h_obs >= OBS_WALL

		if not home_blocked:
			dir = (dir * 0.97 + home * 0.03).normalized()
			_directions[idx] = dir

	# ── Horizontal movement ──────────────────────────────────────────────
	pos.x += dir.x * _speed * delta
	pos.z += dir.z * _speed * delta

	# ── Vertical ─────────────────────────────────────────────────────────
	gcell = _world_to_grid(pos.x, pos.z)
	gidx = _grid_idx(gcell.x, gcell.y)

	upper_y = _upper_floor_y[gidx]
	if upper_y > -9000.0:
		var mid_y := (_heightmap[gidx] + upper_y) * 0.5
		on_upper = pos.y > mid_y
	else:
		on_upper = false

	var layer_floor: float = upper_y if on_upper else _heightmap[gidx]
	var obs_top_y: float = (_upper_obs_top[gidx] if on_upper else _obstacle_top[gidx])
	var obs_type: int = (_upper_obs_type[gidx] if on_upper else _obstacle_type[gidx])

	var floor_y := layer_floor
	if obs_type == OBS_CLIMBABLE and obs_top_y > layer_floor:
		floor_y = obs_top_y
	elif obs_top_y > layer_floor and pos.y >= obs_top_y - 0.5:
		floor_y = obs_top_y

	# Check for falling off a rooftop edge
	if pos.y > floor_y + 3.0:
		_state[idx] = STATE_FALLING
		_positions[idx] = pos
		return

	# Apply gravity or step up
	if pos.y < floor_y - 0.1:
		pos.y = move_toward(pos.y, floor_y, CLIMB_SPEED * delta)
		_vel_y[idx] = 0.0
	elif pos.y > floor_y + 0.1:
		_vel_y[idx] -= GRAVITY * delta
		pos.y += _vel_y[idx] * delta
	else:
		_vel_y[idx] = 0.0
		pos.y = floor_y

	if pos.y < floor_y:
		pos.y = floor_y
		_vel_y[idx] = 0.0

	# ── Ceiling clamp ────────────────────────────────────────────────────
	if not on_upper:
		var ceiling: float = _ceiling_y[gidx]
		if ceiling > -9000.0 and pos.y > ceiling - 1.8:
			pos.y = ceiling - 1.8
			_vel_y[idx] = 0.0

	_positions[idx] = pos


# ── Mesh setup ──────────────────────────────────────────────────────────────

func _setup_vat_mesh() -> ShaderMaterial:
	var zombie_scene := load("res://zombie_static.glb") as PackedScene
	if not zombie_scene:
		_using_vat = false
		return _setup_placeholder_mesh()

	var instance := zombie_scene.instantiate()
	var mesh: Mesh = _find_mesh(instance)
	instance.free()

	if not mesh:
		_using_vat = false
		return _setup_placeholder_mesh()

	_multimesh.mesh = mesh

	var shader := load("res://shaders/vat_zombie.gdshader") as Shader
	var mat := ShaderMaterial.new()
	mat.shader = shader

	var pos_tex := load("res://vat_position.exr") as Texture2D
	mat.set_shader_parameter("vat_position", pos_tex)

	if ResourceLoader.exists("res://vat_normal.exr"):
		var norm_tex := load("res://vat_normal.exr") as Texture2D
		mat.set_shader_parameter("vat_normal", norm_tex)

	if ResourceLoader.exists("res://ZombieFastRun_FBX_0.png"):
		var albedo := load("res://ZombieFastRun_FBX_0.png") as Texture2D
		mat.set_shader_parameter("albedo_tex", albedo)

	var vertex_count := _count_vertices(mesh)
	mat.set_shader_parameter("num_vertices", vertex_count)
	return mat


func _setup_placeholder_mesh() -> ShaderMaterial:
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	_multimesh.mesh = capsule

	var shader := load("res://shaders/vat_zombie_placeholder.gdshader") as Shader
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("color_running", Color(1.0, 0.1, 0.1, 1.0))
	mat.set_shader_parameter("color_climbing", Color(1.0, 0.9, 0.1, 1.0))
	mat.set_shader_parameter("color_falling", Color(0.2, 0.4, 1.0, 1.0))
	mat.set_shader_parameter("color_start_climb", Color(1.0, 0.5, 0.0, 1.0))
	mat.set_shader_parameter("color_standing_up", Color(1.0, 0.2, 0.6, 1.0))
	return mat


func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and node.mesh:
		return node.mesh
	for child in node.get_children():
		var result := _find_mesh(child)
		if result:
			return result
	return null


func _count_vertices(mesh: Mesh) -> int:
	var count := 0
	for surf_idx in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surf_idx)
		if arrays and arrays[Mesh.ARRAY_VERTEX]:
			count += arrays[Mesh.ARRAY_VERTEX].size()
	return count
