# VoxelCamera: How the GPU Renders to Screen

This guide explains how `voxel_camera.cpp` works, with a focus on how the rendered image gets from the GPU compute shader onto a `TextureRect` in your Godot scene.

## The Big Picture

`VoxelCamera` is a Node3D that:
1. Sets up a GPU compute shader (the voxel raymarcher)
2. Gives that shader a texture to write into
3. Every frame, runs the shader and the result automatically appears on a `TextureRect` in your UI

The key trick: Godot's `Texture2DRD` lets you create a texture that *directly wraps* a GPU-side resource. The compute shader writes pixels into that GPU resource, and because the `TextureRect` is displaying that same resource, the image updates on screen with **no CPU-side copying**.

---

## Lifecycle: When Things Happen

VoxelCamera responds to Godot "notifications" (engine events) in `_notification()`:

| Notification | When | What happens |
|---|---|---|
| `NOTIFICATION_READY` | Node enters the scene for the first time | Calls `init()` -- all the setup |
| `NOTIFICATION_INTERNAL_PROCESS` | Every frame | Calls `render()` -- runs the shader |
| `NOTIFICATION_ENTER_TREE` | Added to scene tree | Enables per-frame processing |
| `NOTIFICATION_EXIT_TREE` | Removed from scene tree | Disables per-frame processing |

If you're in the editor (`is_editor_hint()`), it bails out immediately and does nothing.

---

## The Texture Pipeline (the interesting part)

Here's the chain of objects involved in getting pixels on screen, traced from the GPU all the way to your eyeballs:

```
GPU compute shader
    writes pixels into -->
        output_texture_rid (a RID -- a raw GPU resource handle)
            which is wrapped by -->
                output_texture (a Texture2DRD -- a Godot texture backed by a GPU resource)
                    which is assigned to -->
                        output_texture_rect (a TextureRect -- a UI node that displays a texture)
```

### Step-by-step through `init()`

**1. Create the GPU texture resource**

```cpp
output_image = Image::create(width, height, false, Image::FORMAT_RGBAF);
output_texture_rid = cs->create_image_uniform(output_image, output_format, output_texture_view, 0, 1);
```

- An `Image` is created at the window's resolution in RGBAF format (32-bit float per channel -- R, G, B, A).
- `create_image_uniform()` uploads this image to the GPU and gives back an **RID** (Resource ID). An RID is just an opaque handle -- think of it as a pointer to something on the GPU. You can't look at the data through an RID; you can only pass it to other GPU functions.
- The `0, 1` at the end are the **binding** and **set** numbers. These tell the compute shader *where* to find this texture. In the GLSL shader, there will be a matching `layout(set = 1, binding = 0)` declaration.

**2. Wrap it in a Texture2DRD**

```cpp
output_texture.instantiate();
output_texture->set_texture_rd_rid(output_texture_rid);
```

- `Texture2DRD` is a special Godot class that says "I am a regular Godot texture, but my pixel data lives on the GPU at this RID."
- `instantiate()` creates the object (it's a `Ref<>`, Godot's reference-counted smart pointer, so it manages its own memory).
- `set_texture_rd_rid()` points it at the GPU resource.

**3. Assign it to the TextureRect**

```cpp
output_texture_rect->set_texture(output_texture);
```

- `output_texture_rect` is a `TextureRect` node that you've set up in your scene and assigned to VoxelCamera via the inspector (or code).
- Now the TextureRect is displaying the Texture2DRD, which is backed by the GPU resource. Done.

### Why there's no CPU readback

You might notice commented-out code at the bottom of `render()`:

```cpp
// output_image->set_data(Size.x, Size.y, false, Image::FORMAT_RGBA8,
//                        cs->get_image_uniform_buffer(output_texture_rid));
// output_texture->update(output_image);
```

This *was* the old approach: read pixels back from the GPU into a CPU-side Image, then re-upload them. That's slow because it forces the GPU and CPU to sync up and copies all the pixel data over the bus twice. The current approach (Texture2DRD) avoids this entirely -- the data never leaves the GPU.

---

## The Render Loop

Every frame, `render()` runs:

1. **Update camera data**: Gets the camera's current position and orientation, computes the view-projection matrix and its inverse, packs them into a byte buffer, and uploads to the GPU.

2. **Dispatch the compute shader**: `cs->compute({ceil(width/32), ceil(height/32), 1})` -- this launches one GPU thread per pixel (in groups of 32x32). Each thread raymarches through the voxel world and writes a color to the output texture.

3. **That's it.** Because the TextureRect is already pointing at the GPU texture, the new pixels show up automatically.

---

## How Properties Are Exposed to Godot

`_bind_methods()` registers three properties so they show up in the Godot inspector:

- **`fov`** (float) -- Field of view in degrees
- **`voxel_world`** (VoxelWorld node) -- The voxel data source
- **`output_texture`** (TextureRect node) -- Where to display the result

Each property has a getter, a setter, and a `ClassDB::bind_method` + `ADD_PROPERTY` call. This is boilerplate that GDExtension requires to make C++ properties visible to GDScript and the inspector. You set `voxel_world` and `output_texture` by dragging nodes in the inspector.

---

## The Data Sent to the GPU

Two structs are packed into byte arrays and uploaded as storage buffers:

**RenderParameters** (set 1, binding 2):
- `backgroundColor` -- a Vector4 (RGBA)
- `width`, `height` -- resolution in pixels
- `fov` -- field of view

**CameraParameters** (set 1, binding 3):
- `vp[16]` -- 4x4 view-projection matrix (flattened)
- `ivp[16]` -- inverse view-projection matrix (for ray reconstruction)
- `cameraPosition` -- where the camera is in world space
- `frame_index` -- increments each frame (useful for temporal effects/noise)
- `nearPlane`, `farPlane` -- clipping distances

These structs have `to_packed_byte_array()` methods that do a raw memory copy (`memcpy`) of the struct into a Godot `PackedByteArray`. The GPU shader has matching struct definitions so the bytes line up.

---

## Tracing the Full Path: Scene Setup to Pixels

1. In your Godot scene, you have a **TextureRect** (UI element) and a **VoxelCamera** (3D node).
2. In the inspector, you point VoxelCamera's `output_texture` property at the TextureRect, and its `voxel_world` property at your VoxelWorld node.
3. When the scene loads, `init()` creates a GPU texture, wraps it in Texture2DRD, and hands it to the TextureRect.
4. Every frame, `render()` updates the camera matrices on the GPU and dispatches the compute shader.
5. The compute shader (in `voxel_renderer.glsl`) runs on the GPU, raymarches the voxel world, and writes pixel colors directly into the texture.
6. Godot's renderer draws the TextureRect with that texture, and you see the voxels.

No CPU image copying. No downloading pixels from the GPU. The shader writes directly to what's on screen.
