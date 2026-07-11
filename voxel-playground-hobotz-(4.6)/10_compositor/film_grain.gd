@tool
extends CompositorEffect
class_name FilmGrain

# Film grain post-processing effect with beat-sync support.
#
# Applies the effect in 2 stages (same ping-pong pattern as ChromaticAberration):
# 1 - Copies the color buffer to a temporary texture (blit)
# 2 - Reads from the temp texture, applies grain noise, writes back to color
#
# The grain pattern changes at a configurable FPS. When connected to a
# Metronome beat signal the intensity can spike on each beat and decay.
#
# Wiring example (from any node that has access to the Compositor resource):
#
#   var grain_effect: FilmGrain = compositor.compositor_effects[index]
#   metronome.beat.connect(grain_effect.trigger_beat)

@export_group("Film Grain", "grain_")
@export_range(0.0, 1.0) var grain_intensity : float = 0.08
@export_range(1.0, 8.0) var grain_size : float = 1.5
@export_range(1.0, 60.0) var grain_fps : float = 24.0
@export_range(0.0, 1.0) var grain_luminance_response : float = 0.5

@export_group("Beat Sync", "beat_")
@export var beat_intensity_boost : float = 0.25
@export_range(0.1, 20.0) var beat_decay_speed : float = 4.0

func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_compute)

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if grain_shader.is_valid():
			rd.free_rid(grain_shader)
		if blit_shader.is_valid():
			rd.free_rid(blit_shader)

###############################################################################
# Everything after this point is designed to run on our rendering thread

var rd : RenderingDevice

var grain_shader : RID
var grain_pipeline : RID

var blit_shader : RID
var blit_pipeline : RID

var context : StringName = "FilmGrain"
var texture : StringName = "texture"

# Beat-sync state (written from main thread, read from render thread)
var _beat_boost : float = 0.0
var _last_beat_time_ms : float = 0.0

func _initialize_compute():
	rd = RenderingServer.get_rendering_device()
	if !rd:
		return

	var shader_file = load("res://10_compositor/blit_rgba.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	blit_shader = rd.shader_create_from_spirv(shader_spirv)
	blit_pipeline = rd.compute_pipeline_create(blit_shader)

	shader_file = load("res://10_compositor/film_grain.glsl")
	shader_spirv = shader_file.get_spirv()
	grain_shader = rd.shader_create_from_spirv(shader_spirv)
	grain_pipeline = rd.compute_pipeline_create(grain_shader)

func get_image_uniform(image : RID, binding : int = 0) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(image)
	return uniform

## Call this from a Metronome beat signal to spike the grain on each beat.
## Example: metronome.beat.connect(grain_effect.trigger_beat)
func trigger_beat(_beat_number : int = 0) -> void:
	_beat_boost = beat_intensity_boost
	_last_beat_time_ms = Time.get_ticks_msec()

func _render_callback(p_effect_callback_type, p_render_data):
	if rd and p_effect_callback_type == CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT and grain_pipeline.is_valid() and blit_pipeline.is_valid():
		var render_scene_buffers : RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
		if render_scene_buffers:
			var render_size : Vector2 = render_scene_buffers.get_internal_size()
			if render_size.x == 0.0 and render_size.y == 0.0:
				return

			# Recreate texture if size changed
			if render_scene_buffers.has_texture(context, texture):
				var tf : RDTextureFormat = render_scene_buffers.get_texture_format(context, texture)
				if tf.width != render_size.x or tf.height != render_size.y:
					render_scene_buffers.clear_context(context)

			if !render_scene_buffers.has_texture(context, texture):
				var usage_bits : int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
				render_scene_buffers.create_texture(context, texture, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RenderingDevice.TEXTURE_SAMPLES_1, render_size, 1, 1, true, false)

			# Compute the current grain seed from time and FPS setting.
			# floor(time * fps) gives a seed that only changes grain_fps
			# times per second, regardless of actual framerate.
			var current_time_ms : float = Time.get_ticks_msec()
			var frame_duration_ms : float = 1000.0 / max(grain_fps, 1.0)
			var seed_value : float = floor(current_time_ms / frame_duration_ms)

			# Decay the beat intensity boost over time
			var effective_boost : float = 0.0
			if _beat_boost > 0.0:
				var elapsed : float = (current_time_ms - _last_beat_time_ms) / 1000.0
				effective_boost = max(0.0, _beat_boost - elapsed * beat_decay_speed)
				if effective_boost <= 0.0:
					_beat_boost = 0.0

			var final_intensity : float = grain_intensity + effective_boost

			rd.draw_command_begin_label("Film Grain", Color(1.0, 1.0, 1.0, 1.0))

			var view_count = render_scene_buffers.get_view_count()
			for view in range(view_count):
				var color_image = render_scene_buffers.get_color_layer(view)
				var texture_image = render_scene_buffers.get_texture_slice(context, texture, view, 0, 1, 1)

				var x_groups = (render_size.x - 1) / 8 + 1
				var y_groups = (render_size.y - 1) / 8 + 1

				##############################################################
				# Step 1: Copy color buffer to temp texture

				var uniform = get_image_uniform(color_image)
				var input_set = UniformSetCacheRD.get_cache(blit_shader, 0, [ uniform ])

				uniform = get_image_uniform(texture_image)
				var output_set = UniformSetCacheRD.get_cache(blit_shader, 1, [ uniform ])

				var push_constant : PackedFloat32Array = PackedFloat32Array()
				push_constant.push_back(render_size.x)
				push_constant.push_back(render_size.y)
				push_constant.push_back(0.0)
				push_constant.push_back(0.0)

				rd.draw_command_begin_label("Blit color to temp " + str(view), Color(1.0, 1.0, 1.0, 1.0))

				var compute_list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, blit_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, input_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, output_set, 1)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
				rd.compute_list_end()

				rd.draw_command_end_label()

				##############################################################
				# Step 2: Apply film grain
				#
				# Roles swap: temp texture is now input, color buffer is
				# output. The shader generates noise from the seed and
				# blends it with the source image.

				uniform = get_image_uniform(texture_image)
				input_set = UniformSetCacheRD.get_cache(grain_shader, 0, [ uniform ])

				uniform = get_image_uniform(color_image)
				output_set = UniformSetCacheRD.get_cache(grain_shader, 1, [ uniform ])

				push_constant = PackedFloat32Array()
				push_constant.push_back(render_size.x)
				push_constant.push_back(render_size.y)
				push_constant.push_back(seed_value)
				push_constant.push_back(final_intensity)
				push_constant.push_back(grain_luminance_response)
				push_constant.push_back(grain_size)
				push_constant.push_back(0.0)
				push_constant.push_back(0.0)

				rd.draw_command_begin_label("Apply film grain " + str(view), Color(1.0, 1.0, 1.0, 1.0))

				compute_list = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, grain_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, input_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, output_set, 1)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
				rd.compute_list_end()

				rd.draw_command_end_label()

			rd.draw_command_end_label()
