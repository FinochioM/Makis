@echo off
sokol-shdc -i madventures/shader.glsl -o madventures/shader.odin -l hlsl5:wgsl -f sokol_odin

odin build madventures -debug