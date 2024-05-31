extends Node3D

@export var cur_zoom: int

@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D
@onready var attack_move_cast: ShapeCast3D = $AttackMoveCast
@export var server_listener: Node

const MoveMarker: PackedScene = preload ("res://effects/move_marker.tscn")

var camera_target_position := Vector3.ZERO
var initial_mouse_position := Vector2.ZERO
var is_middle_mouse_dragging := false
var is_right_mouse_dragging := false
var is_left_mouse_dragging := false

#@export var player := 1:
	#set(id):
		#player = id
		#$MultiplayerSynchronizer.set_multiplayer_authority(id)

func _ready():
	# For now close game when server dies
	multiplayer.server_disconnected.connect(get_tree().quit)
	spring_arm.spring_length = Config.max_zoom
	Config.camera_property_changed.connect(_on_camera_setting_changed)
	
	center_camera.call_deferred(multiplayer.get_unique_id())
	
	if server_listener == null:
		server_listener = get_parent();
		while !server_listener.is_in_group("Map"):
			server_listener = server_listener.get_parent();
		server_listener = server_listener.get_node("ServerListener");


func _input(event):
	if event is InputEventMouseButton:

		if event.button_index == MOUSE_BUTTON_LEFT and not is_right_mouse_dragging:
			player_action(event, not is_left_mouse_dragging, true)
			if event.is_pressed and not is_left_mouse_dragging:
				is_left_mouse_dragging = true
			else:
				is_left_mouse_dragging = false
		# Right click to move
		if event.button_index == MOUSE_BUTTON_RIGHT and not is_left_mouse_dragging:
			# Start dragging
			player_action(event, not is_right_mouse_dragging)  # For single clicks
			if event.is_pressed and not is_right_mouse_dragging:
				is_right_mouse_dragging = true
			else:
				is_right_mouse_dragging = false
			

		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				initial_mouse_position = event.position
				is_middle_mouse_dragging = true
			else:
				is_middle_mouse_dragging = false
		
		# Stop dragging if mouse is released
	
	if event is InputEventMouseMotion:
		if is_left_mouse_dragging:
			player_action(event, false, true)
			return
		if is_right_mouse_dragging:
			player_action(event, false)
			return


func get_target_position(pid: int) -> Vector3:
	var champ = get_champion(pid)
	if champ:
		return champ.position
	return Vector3.ZERO


func player_action(event, play_marker: bool = false, attack_move: bool = false):
	var from = camera.project_ray_origin(event.position)
	var to = from + camera.project_ray_normal(event.position) * 1000
	
	var space = get_world_3d().direct_space_state
	var params = PhysicsRayQueryParameters3D.create(from, to)
	var result = space.intersect_ray(params)
	if !result: return

	# Move
	if result.collider.is_in_group("ground"):
		
		if attack_move:
			if _try_attack_move(result.position, play_marker):
				return
		_player_action_move(result, play_marker, attack_move)
	# Attack
	_player_action_attack(result.collider)


func _player_action_attack(collider):
	var collider_groups = collider.get_groups()
	for group in collider_groups:
		if group not in ["Objective", "Minion", "Champion"]: continue
		server_listener.rpc_id(get_multiplayer_authority(), "target", collider.name)
		break
	# To account for hitting Navmeshes, we check the parent of the target as well
	var parent_collider_groups = collider.get_parent().get_groups()
	for group in parent_collider_groups:
		if group not in ["Objective", "Minion", "Champion"]: continue
		server_listener.rpc_id(get_multiplayer_authority(), "target", collider.get_parent().name)
		break


func _player_action_move(result, play_marker: bool, attack_move: bool):
		result.position.y += 1
		if play_marker:
			_play_move_marker(result.position, attack_move)
		server_listener.rpc_id(get_multiplayer_authority(), "move_to", result.position)


func _try_attack_move(target_position: Vector3, play_marker : bool = false):
	attack_move_cast.global_position = target_position
	attack_move_cast.force_shapecast_update()
	if attack_move_cast.is_colliding():
		var closest_enemy: Unit = null
		for i in attack_move_cast.get_collision_count():
			var collider = attack_move_cast.get_collider(i)
			if collider == null: continue
			if not collider is Unit: continue
			if collider.team == get_champion(multiplayer.get_unique_id()).team: continue
			if closest_enemy == null:
				closest_enemy = collider
				continue
			if target_position.distance_to(collider.position) < target_position.distance_to(closest_enemy.position):
				closest_enemy = collider
		if closest_enemy != null:
			_player_action_attack(closest_enemy)
			print(closest_enemy.name)
			if play_marker:
				_play_move_marker(target_position, true)
			return true
	return false

func _play_move_marker(marker_position : Vector3, attack_move: bool = false):
	var marker = MoveMarker.instantiate()
	marker.position = marker_position
	marker.attack_move = attack_move
	get_node("/root").add_child(marker)


func center_camera(playerid):
	camera_target_position = get_target_position(playerid)

func _process(delta):
	# handle all the camera-related input
	camera_movement_handler()
	
	# check input for ability uses
	detect_ability_use()
	
	# update the camera position using lerp
	position = position.lerp(camera_target_position, delta * Config.cam_speed)


func detect_ability_use() -> void:
	var pid = multiplayer.get_unique_id()
	if Input.is_action_just_pressed("player_ability1"):
		get_champion(pid).trigger_ability(1)
		return
	if Input.is_action_just_pressed("player_ability2"):
		get_champion(pid).trigger_ability(2)
		return
	if Input.is_action_just_pressed("player_ability3"):
		get_champion(pid).trigger_ability(3)
		return
	if Input.is_action_just_pressed("player_ability4"):
		get_champion(pid).trigger_ability(4)
		return


func camera_movement_handler() -> void:
	# don't move the cam while changing the settings since that is annoying af
	if Config.in_config_settings:
		return
	
	# If centered, blindly follow the champion
	if (Config.is_cam_centered):
		camera_target_position = get_target_position(multiplayer.get_unique_id())
	else:
		# Get Mouse Coords on screen
		var current_mouse_position = get_viewport().get_mouse_position()
		var size = get_viewport().get_visible_rect().size
		var cam_delta = Vector3(0, 0, 0)
		var edge_margin = Config.edge_margin
		
		# Edge Panning
		if current_mouse_position.x <= edge_margin:
			cam_delta.x -= 1
		elif current_mouse_position.x >= size.x - edge_margin:
			cam_delta.x += 1

		if current_mouse_position.y <= edge_margin:
			cam_delta.z -= 1
		elif current_mouse_position.y >= size.y - edge_margin:
			cam_delta.z += 1
		
		# Keyboard input
		cam_delta.x += Input.get_action_strength("player_right") - Input.get_action_strength("player_left")
		cam_delta.z += Input.get_action_strength("player_down") - Input.get_action_strength("player_up")
		
		# Middle mouse dragging
		if is_middle_mouse_dragging:
			var mouse_delta = current_mouse_position - initial_mouse_position
			cam_delta += Vector3(mouse_delta.x, 0, mouse_delta.y) * Config.cam_pan_sensitivity
		
		# Apply camera movement
		if cam_delta != Vector3.ZERO:
			camera_target_position += cam_delta
	
	# Zoom
	if Input.is_action_just_pressed("player_zoomin"):
		if spring_arm.spring_length > Config.min_zoom:
			spring_arm.spring_length -= 1
	if Input.is_action_just_pressed("player_zoomout"):
		if spring_arm.spring_length < Config.max_zoom:
			spring_arm.spring_length += 1
	
	# Recenter - Tap
	if Input.is_action_pressed("player_camera_recenter"):
		camera_target_position = get_target_position(multiplayer.get_unique_id())
	# Recenter - Toggle
	if Input.is_action_just_pressed("player_camera_recenter_toggle"):
		Config.set_cam_centered(!Config.is_cam_centered)


func get_champion(pid: int) -> Node:
	var champs = $"../Champions".get_children()
	for child in champs:
		if child.name == str(pid):
			return child
	return null


func _on_camera_setting_changed():
	spring_arm.spring_length = clamp(spring_arm.spring_length, Config.min_zoom, Config.max_zoom)
