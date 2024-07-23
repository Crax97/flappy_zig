#version 460

#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types : require

struct TexData {
  vec4 position_scale;
  vec4 offset_extent_px;
  float rotation;
  uint tex_id;
  uint z_index;
};

struct SceneData {
    mat4 projection;
    mat4 view;
};

layout(set = 0, binding = 0) uniform sampler2D[] tex2d_samplers;

layout(buffer_reference, std430,
       buffer_reference_align = 16) readonly buffer TextureDrawInfoBase {
  TexData data[];
};

layout(buffer_reference, std430,
       buffer_reference_align = 16) readonly buffer SceneDataBase {
  SceneData scene_data[];
};

layout(push_constant) uniform TexDrawConstants {
    TextureDrawInfoBase base;
    SceneDataBase scene_base;
};

layout(location = 0) in vec2 uv;
layout(location = 1) flat in uint inst_index;
layout(location = 0) out vec4 color;

void main() {
  TexData instance = base.data[inst_index];
  vec4 tex_color = texture(tex2d_samplers[instance.tex_id], uv);
  //   color = vec4(1.0, 0.0, 0.0, 1.0);

  color = tex_color;
}
