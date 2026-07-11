#include "voxel_camera.h"
#include "utility/utils.h"
#include <godot_cpp/variant/callable_method_pointer.hpp>

void VoxelCamera::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("get_fov"), &VoxelCamera::get_fov);
    ClassDB::bind_method(D_METHOD("set_fov", "value"), &VoxelCamera::set_fov);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "fov"), "set_fov", "get_fov");

    ClassDB::bind_method(D_METHOD("get_voxel_world"), &VoxelCamera::get_voxel_world);
    ClassDB::bind_method(D_METHOD("set_voxel_world", "value"), &VoxelCamera::set_voxel_world);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "voxel_world", PROPERTY_HINT_NODE_TYPE, "VoxelWorld"),
                 "set_voxel_world", "get_voxel_world");

    ClassDB::bind_method(D_METHOD("get_output_texture"), &VoxelCamera::get_output_texture);
    ClassDB::bind_method(D_METHOD("set_output_texture", "value"), &VoxelCamera::set_output_texture);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "output_texture", PROPERTY_HINT_NODE_TYPE, "TextureRect"),
                 "set_output_texture", "get_output_texture");

    ClassDB::bind_method(D_METHOD("get_render_texture"), &VoxelCamera::get_render_texture);
}

void VoxelCamera::_notification(int p_what)
{
    if (godot::Engine::get_singleton()->is_editor_hint())
    {
        return;
    }
    switch (p_what)
    {
    case NOTIFICATION_ENTER_TREE: {
        set_process_internal(true);

        break;
    }
    case NOTIFICATION_EXIT_TREE: {
        set_process_internal(false);

        break;
    }
    case NOTIFICATION_READY: {
        // The camera can be READY before a sibling VoxelWorld (READY fires in
        // tree order), and init() needs the world's GPU buffers to exist.
        if (voxel_world != nullptr && !voxel_world->is_initialized())
            callable_mp(this, &VoxelCamera::init).call_deferred();
        else
            init();
        break;
    }
    case NOTIFICATION_INTERNAL_PROCESS: {
        render();
        break;
    }
    }
}

float VoxelCamera::get_fov() const
{
    return fov;
}

void VoxelCamera::set_fov(float value)
{
    fov = value;
}

// int VoxelCamera::get_num_bounces() const
// {
//     return num_bounces;
// }

// void VoxelCamera::set_num_bounces(int value)
// {
//     num_bounces = value;
// }

TextureRect *VoxelCamera::get_output_texture() const
{
    return output_texture_rect;
}

void VoxelCamera::set_output_texture(TextureRect *value)
{
    output_texture_rect = value;
}

Ref<Texture2DRD> VoxelCamera::get_render_texture() const
{
    return output_texture;
}

VoxelWorld *VoxelCamera::get_voxel_world() const
{
    return voxel_world;
}

void VoxelCamera::set_voxel_world(VoxelWorld *value)
{
    voxel_world = value;
}

void VoxelCamera::init()
{
    if (voxel_world == nullptr)
    {
        UtilityFunctions::printerr("No voxel world set.");
        return;
    }
    if (!voxel_world->is_initialized())
    {
        UtilityFunctions::printerr("VoxelCamera: voxel world failed to initialize, cannot set up renderer.");
        return;
    }

    _rd = RenderingServer::get_singleton()->get_rendering_device();

    //get resolution
    Vector2i resolution = DisplayServer::get_singleton()->window_get_size();
    auto near = 0.01f;
    auto far = 1000.0f;    

    projection_matrix = Projection::create_perspective(fov, static_cast<float>(resolution.width) / resolution.height, near, far, false);

    VoxelWorldProperties world_props = voxel_world->get_voxel_properties();
    UtilityFunctions::print("VoxelCamera: init at ", get_global_transform().get_origin(),
                            " | resolution ", resolution, " fov ", fov);
    UtilityFunctions::print("VoxelCamera: world grid_size ", world_props.grid_size,
                            " brick_grid_size ", world_props.brick_grid_size,
                            " scale ", world_props.scale,
                            " (world AABB max ", Vector3(world_props.grid_size.x, world_props.grid_size.y, world_props.grid_size.z) * world_props.scale, ")");

    // setup compute shader
    cs = new ComputeShader("res://addons/voxel_playground/src/shaders/voxel_renderer_oblique.glsl", _rd, {"#define TESTe"});

    //--------- Voxel BUFFERS ---------    
    voxel_world->get_voxel_world_rids().add_voxel_buffers(cs);    

    //--------- GENERAL BUFFERS ---------
    { // input general buffer
        render_parameters.width = resolution.x;
        render_parameters.height = resolution.y;
        render_parameters.fov = fov;

        render_parameters_rid = cs->create_storage_buffer_uniform(render_parameters.to_packed_byte_array(), 2, 1);
    }

    { //camera buffer        
        Vector3 camera_position = get_global_transform().get_origin();
        Projection VP = projection_matrix * get_global_transform().affine_inverse();
        Projection IVP = VP.inverse();

        Utils::projection_to_float(camera_parameters.vp, VP);
        Utils::projection_to_float(camera_parameters.ivp, IVP);
        camera_parameters.cameraPosition = Vector4(camera_position.x, camera_position.y, camera_position.z, 1.0f);
        camera_parameters.frame_index = 0;
        camera_parameters.nearPlane = near;
        camera_parameters.farPlane = far;

        camera_parameters_rid = cs->create_storage_buffer_uniform(camera_parameters.to_packed_byte_array(), 3, 1);
    }

    Ref<RDTextureView> output_texture_view = memnew(RDTextureView);
    { // output texture
        auto output_format = cs->create_texture_format(render_parameters.width, render_parameters.height, RenderingDevice::DATA_FORMAT_R32G32B32A32_SFLOAT);
        if (output_texture_rect == nullptr)
        {
            UtilityFunctions::printerr("No output texture set.");
            return;
        }
        output_image = Image::create(render_parameters.width, render_parameters.height, false, Image::FORMAT_RGBAF);
        output_texture_rid = cs->create_image_uniform(output_image, output_format, output_texture_view, 0, 1);

        output_texture.instantiate();
        output_texture->set_texture_rd_rid(output_texture_rid);
        output_texture_rect->set_texture(output_texture);
    }

    Ref<RDTextureView> depth_texture_view = memnew(RDTextureView);
    { // depth texture
        auto depth_format = cs->create_texture_format(render_parameters.width, render_parameters.height, RenderingDevice::DATA_FORMAT_R32_SFLOAT);
        depth_image = Image::create(render_parameters.width, render_parameters.height, false, Image::FORMAT_RF);        
        depth_texture_rid = cs->create_image_uniform(depth_image, depth_format, depth_texture_view, 1, 1);
    }

    cs->finish_create_uniforms();
}

void VoxelCamera::clear_compute_shader()
{
}

void VoxelCamera::render()
{
    if (cs == nullptr || !cs->check_ready())
        return;
    // fov acts as the zoom control for the oblique renderer; sync it when changed
    if (render_parameters.fov != fov)
    {
        render_parameters.fov = fov;
        cs->update_storage_buffer_uniform(render_parameters_rid, render_parameters.to_packed_byte_array());
    }

    // update rendering parameters
    Vector3 camera_position = get_global_transform().get_origin();
    if (camera_parameters.frame_index == 0)
        UtilityFunctions::print("VoxelCamera: first render — pos ", camera_position,
                                " forward ", -get_global_transform().get_basis().get_column(2),
                                " dispatching ", render_parameters.width, "x", render_parameters.height);
    Projection VP = projection_matrix * get_global_transform().affine_inverse();
    Projection IVP = VP.inverse();

    Utils::projection_to_float(camera_parameters.vp, VP);
    Utils::projection_to_float(camera_parameters.ivp, IVP);
    camera_parameters.cameraPosition = Vector4(camera_position.x, camera_position.y, camera_position.z, 1.0f);
    camera_parameters.frame_index++;
    cs->update_storage_buffer_uniform(camera_parameters_rid, camera_parameters.to_packed_byte_array());

    // render
    Vector2i Size = {render_parameters.width, render_parameters.height};
    cs->compute({static_cast<int32_t>(std::ceil(Size.x / 16.0f)), static_cast<int32_t>(std::ceil(Size.y / 16.0f)), 1}, false);

    // One-shot readback to verify imageStore writes are landing (debug)
    if (camera_parameters.frame_index == 5)
    {
        PackedByteArray params_data = cs->get_storage_buffer_uniform(render_parameters_rid);
        if (params_data.size() >= 28)
        {
            const int *pi = reinterpret_cast<const int *>(params_data.ptr() + 16);
            const float *pf = reinterpret_cast<const float *>(params_data.ptr() + 24);
            UtilityFunctions::print("VoxelCamera: params buffer on GPU — width ", pi[0], " height ", pi[1], " fov ", pf[0]);
        }
        PackedByteArray tex_data = cs->get_image_uniform_buffer(output_texture_rid, 0);
        int64_t center = (int64_t)(render_parameters.height / 2) * render_parameters.width * 16 + (render_parameters.width / 2) * 16;
        if (tex_data.size() >= center + 16)
        {
            const float *p = reinterpret_cast<const float *>(tex_data.ptr() + center);
            int64_t nonzero = 0;
            const uint8_t *b = tex_data.ptr();
            for (int64_t i = 0; i < tex_data.size(); i++)
                nonzero += (b[i] != 0);
            UtilityFunctions::print("VoxelCamera: readback — bytes ", tex_data.size(), " nonzero ", nonzero,
                                    " center RGBA (", p[0], ", ", p[1], ", ", p[2], ", ", p[3], ")");
        }
        else
            UtilityFunctions::print("VoxelCamera: readback — unexpected size ", tex_data.size());
    }
    
    { // post processing

    }
    
    // output_image->set_data(Size.x, Size.y, false, Image::FORMAT_RGBA8,
    //                        cs->get_image_uniform_buffer(output_texture_rid));
    // output_texture->update(output_image);
}