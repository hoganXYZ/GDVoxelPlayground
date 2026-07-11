@tool
extends MeshInstance3D


func _ready() -> void:
	var mat: StandardMaterial3D = get_surface_override_material(0)
	var tex: Texture2DRD = %VoxelCamera.get_render_texture()
	mat.albedo_texture = tex
