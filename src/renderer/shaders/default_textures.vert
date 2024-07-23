#version 460

layout(set = 0, binding = 0) uniform sampler2D[] tex2d_samplers;

layout(location = 0) out vec2 uv;

void main() {

  vec3 verts[6] =
      vec3[6](vec3(-0.5, -0.5, 0.0), vec3(-0.5, 0.5, 0.0), vec3(0.5, -0.5, 0.0),
              vec3(0.5, -0.5, 0.0), vec3(-0.5, 0.5, 0.0), vec3(0.5, 0.5, 0.0));

  gl_Position = vec4(verts[gl_VertexIndex], 1.0);
  uv = (verts[gl_VertexIndex].xy + vec2(0.5));
}