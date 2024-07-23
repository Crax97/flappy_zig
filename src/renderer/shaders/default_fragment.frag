#version 460

#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 0) uniform sampler2D[] tex2d_samplers;

layout(location = 0) in vec2 uv;

layout(location = 0) out vec4 color;

layout(push_constant) uniform TexDrawInfo { uint tex_id; };

void main() {
  vec4 tex_color = texture(tex2d_samplers[tex_id], uv);
  //   color = vec4(1.0, 0.0, 0.0, 1.0);

  color = tex_color;
}