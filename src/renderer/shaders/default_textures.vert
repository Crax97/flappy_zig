#version 460

#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_shader_explicit_arithmetic_types : require

struct TexData {
  vec4 position_scale;
  vec4 offset_extent_px;
  float rotation;
  uint tex_id;
  uint z_index;
};

layout(set = 0, binding = 0) uniform sampler2D[] tex2d_samplers;

layout(buffer_reference, std430,
       buffer_reference_align = 16) readonly buffer TextureDrawInfoBase {
  TexData data[];
};

layout(push_constant) uniform TexDrawConstants { TextureDrawInfoBase base; };

layout(location = 0) out vec2 uv;
layout(location = 1) out uint inst_index;

void main() {

  vec3 verts[6] =
      vec3[6](vec3(-0.5, -0.5, 0.0), vec3(-0.5, 0.5, 0.0), vec3(0.5, -0.5, 0.0),
              vec3(0.5, -0.5, 0.0), vec3(-0.5, 0.5, 0.0), vec3(0.5, 0.5, 0.0));

  vec4 offset = vec4(base.data[gl_InstanceIndex].position_scale.xy, 0.0, 0.0);

  gl_Position = vec4(verts[gl_VertexIndex], 1.0) + offset;
  uv = (verts[gl_VertexIndex].xy + vec2(0.5));
  inst_index = gl_InstanceIndex;
}