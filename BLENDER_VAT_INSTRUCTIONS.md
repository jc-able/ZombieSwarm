# Blender VAT Baking Instructions for ZombieSwarm

This guide walks you through baking the zombie FBX animation into Vertex Animation Textures (VAT) for use with the MultiMesh swarm system in Godot.

## What You Need

- **Blender 3.6+** (free at blender.org)
- **A VAT Blender addon** (see options below)
- **ZombieFastRun_FBX.fbx** (already in this project)

## Recommended Blender Addon

Install one of these VAT baking addons:

1. **"Vertex Animation Texture Tools for Blender"** by Matthias Patscheider
   - GitHub: search for `blender-vertex-animation-textures`
   - Specifically designed for game engine VAT workflows

2. **"Mesh to VAT"** or similar community addons
   - Search Blender extensions for "vertex animation texture"

### Installing the Addon
1. Download the addon `.zip` file
2. In Blender: Edit > Preferences > Add-ons > Install
3. Select the `.zip` file
4. Enable the addon (check the checkbox)

## Step-by-Step Baking Process

### 1. Import the FBX
1. Open Blender, start a new General project
2. Delete the default cube
3. File > Import > FBX
4. Navigate to this project folder and select `ZombieFastRun_FBX.fbx`
5. Click "Import FBX"
6. You should see the zombie mesh with an armature (skeleton)

### 2. Verify the Animation
1. Press Space in the viewport to play the animation
2. You should see the zombie running
3. Note the frame range in the timeline (e.g., frames 1-30)
4. Set the correct start/end frames in the timeline

### 3. Bake to VAT
The exact steps depend on which addon you installed, but generally:

1. Select the **mesh object** (not the armature)
2. Open the addon panel (usually in the sidebar: View > Sidebar > VAT tab, or in Object Properties)
3. Set the output directory to this Godot project folder
4. Set the frame range to match your animation
5. Click "Bake" or "Export VAT"

### 4. Expected Output Files
After baking, you should have these files:

| File | Description |
|------|-------------|
| `zombie_static.glb` or `.obj` | The static mesh (no skeleton, rest pose) |
| `vat_position.exr` | Float32 texture with XYZ vertex positions per frame |
| `vat_normal.exr` | Float32 texture with vertex normals per frame |

### 5. Rename and Place Files
Copy/rename the output files to match what the Godot swarm system expects:

```
ZombieSwarm/
  zombie_static.glb       <-- static mesh
  vat_position.exr         <-- position texture
  vat_normal.exr           <-- normal texture (optional but recommended)
```

### 6. Configure Godot Import Settings
After dropping the files into the project:

1. Open the Godot editor
2. Select `vat_position.exr` in the FileSystem dock
3. In the Import tab, set:
   - Compress Mode: **Lossless** (NOT VRAM compressed — we need float precision)
   - Mipmaps: **Off**
4. Click "Reimport"
5. Repeat for `vat_normal.exr`

### 7. Update Shader Parameters
Open `shaders/vat_zombie.gdshader` and verify:
- `num_frames` matches your animation frame count (e.g., 30)
- `fps` matches your desired playback speed (e.g., 30.0)
- `num_vertices` will be auto-detected by the spawner script

## Testing
After placing the files, run the Godot project and press **S** to spawn a swarm. If VAT files are detected, the swarm will use the real zombie mesh with GPU-driven animation instead of placeholder capsules.

## Troubleshooting

- **Mesh appears deformed**: Check that the VAT addon exports absolute positions (not offsets). The shader may need adjustment.
- **Animation doesn't play**: Verify `num_frames` in the shader matches the baked frame count.
- **Lighting looks wrong**: Make sure `vat_normal.exr` is present and imported as Lossless.
- **T-pose instead of animation**: The static mesh should be exported at rest pose. The VAT texture drives all animation.

## Alternative: Manual VAT Baking (No Addon)
If addons don't work, you can bake VAT manually with a Blender Python script:

1. For each animation frame, evaluate the armature
2. For each vertex, record its world-space position after deformation
3. Write all positions into a float32 EXR image
   - Width = number of vertices
   - Height = number of frames
   - RGB channels = XYZ position

This is more involved but gives full control over the output format.
