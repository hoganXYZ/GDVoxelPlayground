#include "voxel_camera.h"
#include "utility/utils.h"

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

    _rd = RenderingServer::get_singleton()->get_rendering_device();

    //get resolution
    Vector2i resolution = DisplayServer::get_singleton()->window_get_size();
    auto near = 0.01f;
    auto far = 1000.0f;    

    projection_matrix = Projection::create_perspective(fov, static_cast<float>(resolution.width) / resolution.height, near, far, false);

    // setup compute shader
    cs = new ComputeShader("res://addons/voxel_playground/src/shaders/voxel_renderer.glsl", _rd, {"#define TESTe"});

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
    // update rendering parameters
    Vector3 camera_position = get_global_transform().get_origin();
    Projection VP = projection_matrix * get_global_transform().affine_inverse();
    Projection IVP = VP.inverse();

    Utils::projection_to_float(camera_parameters.vp, VP);
    Utils::projection_to_float(camera_parameters.ivp, IVP);
    camera_parameters.cameraPosition = Vector4(camera_position.x, camera_position.y, camera_position.z, 1.0f);
    camera_parameters.frame_index++;
    cs->update_storage_buffer_uniform(camera_parameters_rid, camera_parameters.to_packed_byte_array());

    // render
    Vector2i Size = {render_parameters.width, render_parameters.height};
    cs->compute({static_cast<int32_t>(std::ceil(Size.x / 32.0f)), static_cast<int32_t>(std::ceil(Size.y / 32.0f)), 1}, false);
    
    { // post processing

    }
    
    // output_image->set_data(Size.x, Size.y, false, Image::FORMAT_RGBA8,
    //                        cs->get_image_uniform_buffer(output_texture_rid));
    // output_texture->update(output_image);
}