#include "register_types.h"
#include "voxel_rendering/voxel_camera.h"
#include "voxel_world/voxel_world.h"
#include "voxel_world/generator/voxel_world_generator.h"
#include "voxel_world/generator/voxel_world_shader_generator.h"
#include "voxel_world/generator/voxel_world_generator_cpu_pass.h"
#include "voxel_world/generator/voxel_world_cpu_generator.h"
#include "voxel_world/generator/cpu_passes/voxel_world_data_loader.h"
#include "voxel_world/generator/cpu_passes/voxel_world_terrain_generator.h"
#include "voxel_world/generator/cpu_passes/wave_function_collapse/voxel_world_wfc_adjacency_generator.h"
#include "voxel_world/generator/cpu_passes/wave_function_collapse/voxel_world_wfc_pattern_generator.h"
#include "voxel_world/generator/cpu_passes/wave_function_collapse/voxel_world_wfc_tile_generator.h"
#include "voxel_world/data/voxel_data_vox.h"
#include "voxel_world/cellular_automata/cellpond_rule_set.h"

using namespace godot;

void initialize_voxel_playground_module(ModuleInitializationLevel p_level)
{
    if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE)
    {
        GDREGISTER_ABSTRACT_CLASS(VoxelData);
        GDREGISTER_CLASS(VoxelDataVoxFilter);
        GDREGISTER_CLASS(VoxelDataVox);

        GDREGISTER_ABSTRACT_CLASS(VoxelWorldGenerator);        
        GDREGISTER_CLASS(VoxelWorldShaderGenerator);
        GDREGISTER_CLASS(VoxelWorldCPUGenerator);

        GDREGISTER_ABSTRACT_CLASS(VoxelWorldGeneratorCPUPass)
        GDREGISTER_CLASS(VoxelWorldDataLoader);
        GDREGISTER_CLASS(VoxelWorldTerrainGenerator);

        GDREGISTER_ABSTRACT_CLASS(WaveFunctionCollapseGenerator);
        GDREGISTER_CLASS(VoxelWorldWFCAdjacencyGenerator);
        GDREGISTER_CLASS(VoxelWorldWFCPatternGenerator);
        GDREGISTER_CLASS(WaveFunctionCollapseTile);
        GDREGISTER_CLASS(VoxelWorldWFCTileGenerator);
        

        GDREGISTER_CLASS(CellPondRuleSet);

        GDREGISTER_CLASS(VoxelCamera);
        GDREGISTER_CLASS(VoxelWorldCollider);
        GDREGISTER_CLASS(VoxelWorld);
    }
}

void uninitialize_voxel_playground_module(ModuleInitializationLevel p_level)
{
    if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE)
    {
    }
}

extern "C"
{
    // Initialization.
    GDExtensionBool GDE_EXPORT voxel_playground_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                                                              const GDExtensionClassLibraryPtr p_library,
                                                              GDExtensionInitialization *r_initialization)
    {
        godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

        init_obj.register_initializer(initialize_voxel_playground_module);
        init_obj.register_terminator(uninitialize_voxel_playground_module);
        init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

        return init_obj.init();
    }
}