#version 460

layout(set = 0, binding = 0) uniform sampler2D[] tex2d_samplers;

layout(location = 0) out vec4 color;

void main() { color = vec4(1.0, 0.0, 0.0, 1.0); }