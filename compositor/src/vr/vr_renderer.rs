//! Stereo VR renderer — renders the 3D scene to OpenXR swapchains.
//!
//! Renders each eye's view by:
//! 1. Getting eye poses from OpenXR
//! 2. Computing per-eye view/projection matrices
//! 3. Rendering scene nodes (surface quads) with their textures
//! 4. Submitting frames to OpenXR
//!
//! Uses glow for GL calls and the scene graph from `super::scene` for layout.

use glow::HasContext;
use openxrs as xr;
use tracing::{debug, error, info, warn};

use super::scene::{Mat4, Quat, Transform3D, Vec3, VrScene};
use super::texture::TextureManager;

/// Vertex shader source for textured quads with MVP transform.
const VERTEX_SHADER: &str = r#"#version 320 es
precision highp float;
uniform mat4 u_mvp;
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec2 a_uv;
out vec2 v_uv;
void main() {
    v_uv = a_uv;
    gl_Position = u_mvp * vec4(a_pos, 1.0);
}
"#;

/// Fragment shader source with alpha blending.
const FRAGMENT_SHADER: &str = r#"#version 320 es
precision highp float;
uniform float u_alpha;
uniform sampler2D u_tex;
in vec2 v_uv;
out vec4 frag_color;
void main() {
    vec4 tex_color = texture(u_tex, v_uv);
    frag_color = vec4(tex_color.rgb, tex_color.a * u_alpha);
}
"#;

/// Unit quad geometry: position (xyz) + texcoord (uv).
const QUAD_VERTICES: [f32; 20] = [
    // pos           // uv
    -0.5, -0.5, 0.0,  0.0, 0.0,
     0.5, -0.5, 0.0,  1.0, 0.0,
     0.5,  0.5, 0.0,  1.0, 1.0,
    -0.5,  0.5, 0.0,  0.0, 1.0,
];

/// Quad indices for two triangles.
const QUAD_INDICES: [u16; 6] = [0, 1, 2, 0, 2, 3];

/// Per-eye view configuration.
#[derive(Debug, Clone)]
pub struct EyeView {
    pub pose: Transform3D,
    pub projection: Mat4,
    pub viewport_x: u32,
    pub viewport_y: u32,
    pub viewport_w: u32,
    pub viewport_h: u32,
}

impl Default for EyeView {
    fn default() -> Self {
        Self {
            pose: Transform3D::default(),
            projection: Mat4::IDENTITY,
            viewport_x: 0,
            viewport_y: 0,
            viewport_w: 1920,
            viewport_h: 1080,
        }
    }
}

/// Stereo render target configuration.
#[derive(Debug, Clone)]
pub struct StereoConfig {
    pub left_eye: EyeView,
    pub right_eye: EyeView,
    pub ipd: f32,
}

impl Default for StereoConfig {
    fn default() -> Self {
        let ipd = 0.063; // 63mm average IPD
        Self {
            left_eye: EyeView {
                pose: Transform3D {
                    position: Vec3::new(-ipd / 2.0, 0.0, 0.0),
                    rotation: Quat::IDENTITY,
                    scale: Vec3::ONE,
                },
                ..Default::default()
            },
            right_eye: EyeView {
                pose: Transform3D {
                    position: Vec3::new(ipd / 2.0, 0.0, 0.0),
                    rotation: Quat::IDENTITY,
                    scale: Vec3::ONE,
                },
                ..Default::default()
            },
            ipd,
        }
    }
}

/// VR renderer state with GL resources.
pub struct VrRenderer {
    pub stereo: StereoConfig,
    pub texture_manager: TextureManager,
    pub frame_count: u64,
    pub clear_color: [f32; 4],

    // GL resources (initialized via init_gl)
    gl: Option<glow::Context>,
    program: Option<glow::Program>,
    quad_vao: Option<glow::VertexArray>,
    quad_vbo: Option<glow::Buffer>,
    quad_ebo: Option<glow::Buffer>,
    fbo: Option<glow::Framebuffer>,

    // Uniform locations
    u_mvp: Option<glow::UniformLocation>,
    u_alpha: Option<glow::UniformLocation>,
    u_tex: Option<glow::UniformLocation>,
}

impl VrRenderer {
    pub fn new() -> Self {
        info!("VR renderer initialized");
        Self {
            stereo: StereoConfig::default(),
            texture_manager: TextureManager::new(),
            frame_count: 0,
            clear_color: [0.102, 0.102, 0.180, 1.0],
            gl: None,
            program: None,
            quad_vao: None,
            quad_vbo: None,
            quad_ebo: None,
            fbo: None,
            u_mvp: None,
            u_alpha: None,
            u_tex: None,
        }
    }

    /// Initialize GL resources using the given glow context.
    ///
    /// Must be called from the GL thread after EGL context is current.
    pub fn init_gl(&mut self, gl: glow::Context) -> Result<(), String> {
        unsafe {
            // Compile shaders
            let vert = gl.create_shader(glow::VERTEX_SHADER)
                .map_err(|e| format!("create vertex shader: {}", e))?;
            gl.shader_source(vert, VERTEX_SHADER);
            gl.compile_shader(vert);
            if !gl.get_shader_compile_status(vert) {
                let log = gl.get_shader_info_log(vert);
                gl.delete_shader(vert);
                return Err(format!("vertex shader compile: {}", log));
            }

            let frag = gl.create_shader(glow::FRAGMENT_SHADER)
                .map_err(|e| format!("create fragment shader: {}", e))?;
            gl.shader_source(frag, FRAGMENT_SHADER);
            gl.compile_shader(frag);
            if !gl.get_shader_compile_status(frag) {
                let log = gl.get_shader_info_log(frag);
                gl.delete_shader(vert);
                gl.delete_shader(frag);
                return Err(format!("fragment shader compile: {}", log));
            }

            // Link program
            let program = gl.create_program()
                .map_err(|e| format!("create program: {}", e))?;
            gl.attach_shader(program, vert);
            gl.attach_shader(program, frag);
            gl.link_program(program);
            if !gl.get_program_link_status(program) {
                let log = gl.get_program_info_log(program);
                gl.delete_program(program);
                gl.delete_shader(vert);
                gl.delete_shader(frag);
                return Err(format!("program link: {}", log));
            }
            gl.delete_shader(vert);
            gl.delete_shader(frag);

            // Get uniform locations
            let u_mvp = gl.get_uniform_location(program, "u_mvp");
            let u_alpha = gl.get_uniform_location(program, "u_alpha");
            let u_tex = gl.get_uniform_location(program, "u_tex");

            // Create VAO + VBO + EBO for unit quad
            let vao = gl.create_vertex_array()
                .map_err(|e| format!("create VAO: {}", e))?;
            gl.bind_vertex_array(Some(vao));

            let vbo = gl.create_buffer()
                .map_err(|e| format!("create VBO: {}", e))?;
            gl.bind_buffer(glow::ARRAY_BUFFER, Some(vbo));
            let vert_bytes: &[u8] = std::slice::from_raw_parts(
                QUAD_VERTICES.as_ptr() as *const u8,
                QUAD_VERTICES.len() * std::mem::size_of::<f32>(),
            );
            gl.buffer_data_u8_slice(glow::ARRAY_BUFFER, vert_bytes, glow::STATIC_DRAW);

            let ebo = gl.create_buffer()
                .map_err(|e| format!("create EBO: {}", e))?;
            gl.bind_buffer(glow::ELEMENT_ARRAY_BUFFER, Some(ebo));
            let idx_bytes: &[u8] = std::slice::from_raw_parts(
                QUAD_INDICES.as_ptr() as *const u8,
                QUAD_INDICES.len() * std::mem::size_of::<u16>(),
            );
            gl.buffer_data_u8_slice(glow::ELEMENT_ARRAY_BUFFER, idx_bytes, glow::STATIC_DRAW);

            // Position attribute (location 0): 3 floats, stride 5*4, offset 0
            gl.enable_vertex_attrib_array(0);
            gl.vertex_attrib_pointer_f32(0, 3, glow::FLOAT, false, 20, 0);

            // UV attribute (location 1): 2 floats, stride 5*4, offset 3*4
            gl.enable_vertex_attrib_array(1);
            gl.vertex_attrib_pointer_f32(1, 2, glow::FLOAT, false, 20, 12);

            gl.bind_vertex_array(None);

            // Create FBO for swapchain rendering
            let fbo = gl.create_framebuffer()
                .map_err(|e| format!("create FBO: {}", e))?;

            info!("VR renderer: GL resources initialized");

            self.program = Some(program);
            self.quad_vao = Some(vao);
            self.quad_vbo = Some(vbo);
            self.quad_ebo = Some(ebo);
            self.fbo = Some(fbo);
            self.u_mvp = u_mvp;
            self.u_alpha = u_alpha;
            self.u_tex = u_tex;
            self.gl = Some(gl);
        }

        Ok(())
    }

    /// Update eye poses from OpenXR view state.
    pub fn update_eye_poses(&mut self, left_pose: Transform3D, right_pose: Transform3D) {
        self.stereo.left_eye.pose = left_pose;
        self.stereo.right_eye.pose = right_pose;
    }

    /// Update projection matrices from OpenXR FOV.
    pub fn update_projections(&mut self, left_proj: Mat4, right_proj: Mat4) {
        self.stereo.left_eye.projection = left_proj;
        self.stereo.right_eye.projection = right_proj;
    }

    /// Render one stereo frame to OpenXR swapchains.
    ///
    /// Returns composition layer projection views for frame submission.
    pub fn render_frame_to_swapchains(
        &mut self,
        scene: &VrScene,
        swapchains: &mut [xr::Swapchain<xr::OpenGL>],
        swapchain_images: &[Vec<u32>],
        views: &[xr::View],
        view_configs: &[xr::ViewConfigurationView],
    ) -> Vec<SwapchainRenderResult> {
        let gl = match &self.gl {
            Some(gl) => gl,
            None => {
                warn!("VR renderer: GL not initialized, skipping frame");
                return Vec::new();
            }
        };

        // Import any pending textures
        self.texture_manager.import_pending_gl(gl);

        let render_order = scene.render_order();
        let mut results = Vec::new();

        for (eye_idx, swapchain) in swapchains.iter_mut().enumerate() {
            let images = match swapchain_images.get(eye_idx) {
                Some(imgs) => imgs,
                None => continue,
            };
            let view = match views.get(eye_idx) {
                Some(v) => v,
                None => continue,
            };
            let view_config = match view_configs.get(eye_idx) {
                Some(vc) => vc,
                None => continue,
            };

            // Acquire swapchain image
            let image_idx = match swapchain.acquire_image() {
                Ok(idx) => idx,
                Err(e) => {
                    error!("VR: acquire_image failed for eye {}: {}", eye_idx, e);
                    continue;
                }
            };

            // Wait for image to be available
            if let Err(e) = swapchain.wait_image(xr::Duration::INFINITE) {
                error!("VR: wait_image failed for eye {}: {}", eye_idx, e);
                continue;
            }

            let gl_texture = images[image_idx as usize];
            let width = view_config.recommended_image_rect_width;
            let height = view_config.recommended_image_rect_height;

            // Build view and projection matrices from OpenXR view data
            let view_matrix = view_matrix_from_xr_pose(&view.pose);
            let proj_matrix = projection_from_xr_fov(&view.fov, 0.01, 100.0);

            // Render to swapchain texture
            self.render_eye_to_texture(
                gl,
                gl_texture,
                width,
                height,
                &view_matrix,
                &proj_matrix,
                scene,
                &render_order,
            );

            // Release swapchain image
            if let Err(e) = swapchain.release_image() {
                error!("VR: release_image failed for eye {}: {}", eye_idx, e);
            }

            results.push(SwapchainRenderResult {
                eye_idx,
                image_idx,
                width,
                height,
            });
        }

        self.frame_count += 1;
        results
    }

    /// Render one eye's scene to an FBO-attached texture.
    fn render_eye_to_texture(
        &self,
        gl: &glow::Context,
        texture: u32,
        width: u32,
        height: u32,
        view: &Mat4,
        projection: &Mat4,
        scene: &VrScene,
        render_order: &[u64],
    ) {
        unsafe {
            let fbo = match self.fbo {
                Some(fbo) => fbo,
                None => return,
            };
            let program = match self.program {
                Some(prog) => prog,
                None => return,
            };
            let vao = match self.quad_vao {
                Some(vao) => vao,
                None => return,
            };

            // Bind FBO and attach swapchain texture
            gl.bind_framebuffer(glow::FRAMEBUFFER, Some(fbo));
            gl.framebuffer_texture_2d(
                glow::FRAMEBUFFER,
                glow::COLOR_ATTACHMENT0,
                glow::TEXTURE_2D,
                Some(glow::NativeTexture(std::num::NonZeroU32::new(texture).unwrap())),
                0,
            );

            // Set viewport and clear
            gl.viewport(0, 0, width as i32, height as i32);
            gl.clear_color(
                self.clear_color[0],
                self.clear_color[1],
                self.clear_color[2],
                self.clear_color[3],
            );
            gl.clear(glow::COLOR_BUFFER_BIT | glow::DEPTH_BUFFER_BIT);

            // Enable depth test and blending
            gl.enable(glow::DEPTH_TEST);
            gl.enable(glow::BLEND);
            gl.blend_func(glow::SRC_ALPHA, glow::ONE_MINUS_SRC_ALPHA);

            // Use our shader program
            gl.use_program(Some(program));

            // Set texture sampler uniform
            if let Some(ref loc) = self.u_tex {
                gl.uniform_1_i32(Some(loc), 0);
            }

            // Bind quad VAO
            gl.bind_vertex_array(Some(vao));

            // Render each surface
            for surface_id in render_order {
                if let Some(node) = scene.nodes.get(surface_id) {
                    if !node.visible {
                        continue;
                    }

                    let model = Mat4::from_transform(&node.transform);
                    let mvp = projection.mul(view).mul(&model);

                    // Upload MVP matrix
                    if let Some(ref loc) = self.u_mvp {
                        gl.uniform_matrix_4_f32_slice(Some(loc), false, &mvp.data);
                    }

                    // Upload alpha
                    if let Some(ref loc) = self.u_alpha {
                        gl.uniform_1_f32(Some(loc), node.alpha);
                    }

                    // Bind surface texture (or fallback to 0)
                    let tex_id = self.texture_manager
                        .get_texture(*surface_id)
                        .unwrap_or(0);
                    gl.active_texture(glow::TEXTURE0);
                    if tex_id != 0 {
                        gl.bind_texture(
                            glow::TEXTURE_2D,
                            Some(glow::NativeTexture(std::num::NonZeroU32::new(tex_id).unwrap())),
                        );
                    }

                    // Draw quad
                    gl.draw_elements(glow::TRIANGLES, 6, glow::UNSIGNED_SHORT, 0);

                    debug!(
                        "VR render: eye draw surface {} at ({:.2}, {:.2}, {:.2})",
                        surface_id,
                        node.transform.position.x,
                        node.transform.position.y,
                        node.transform.position.z,
                    );
                }
            }

            // Unbind
            gl.bind_vertex_array(None);
            gl.use_program(None);
            gl.bind_framebuffer(glow::FRAMEBUFFER, None);
        }
    }

    /// Legacy render_frame for backward compatibility (no swapchains).
    pub fn render_frame(&mut self, scene: &VrScene) {
        let imported = self.texture_manager.import_pending();
        for (surface_id, _tex_id) in &imported {
            debug!("VR render: imported texture for surface {}", surface_id);
        }

        let render_order = scene.render_order();

        // Left eye
        self.render_eye(scene, &self.stereo.left_eye.clone(), &render_order);

        // Right eye
        self.render_eye(scene, &self.stereo.right_eye.clone(), &render_order);

        self.frame_count += 1;
    }

    /// Render one eye's view (legacy path without GL).
    fn render_eye(&self, scene: &VrScene, eye: &EyeView, render_order: &[u64]) {
        let model = Mat4::from_transform(&eye.pose);
        let _view = model.inverse().unwrap_or(Mat4::IDENTITY);

        for surface_id in render_order {
            if let Some(node) = scene.nodes.get(surface_id) {
                if !node.visible {
                    continue;
                }

                let _model_matrix = Mat4::from_transform(&node.transform);

                debug!(
                    "VR render: eye draw surface {} at ({:.2}, {:.2}, {:.2}) alpha={:.1}",
                    surface_id,
                    node.transform.position.x,
                    node.transform.position.y,
                    node.transform.position.z,
                    node.alpha,
                );
            }
        }
    }

    /// Register a new surface with the texture manager.
    pub fn register_surface(&mut self, surface_id: u64, width: u32, height: u32) {
        self.texture_manager.register_surface(surface_id, width, height);
    }

    /// Unregister a surface from the texture manager.
    pub fn unregister_surface(&mut self, surface_id: u64) {
        if let Some(gl) = &self.gl {
            self.texture_manager.unregister_surface_gl(surface_id, gl);
        } else {
            self.texture_manager.unregister_surface(surface_id);
        }
    }

    /// Mark a surface's texture as dirty (content changed).
    pub fn mark_surface_dirty(&mut self, surface_id: u64) {
        self.texture_manager.mark_dirty(surface_id);
    }

    /// Clean up GL resources.
    pub fn destroy_gl(&mut self) {
        if let Some(gl) = &self.gl {
            unsafe {
                if let Some(fbo) = self.fbo {
                    gl.delete_framebuffer(fbo);
                }
                if let Some(vao) = self.quad_vao {
                    gl.delete_vertex_array(vao);
                }
                if let Some(vbo) = self.quad_vbo {
                    gl.delete_buffer(vbo);
                }
                if let Some(ebo) = self.quad_ebo {
                    gl.delete_buffer(ebo);
                }
                if let Some(prog) = self.program {
                    gl.delete_program(prog);
                }
            }
        }
        self.fbo = None;
        self.quad_vao = None;
        self.quad_vbo = None;
        self.quad_ebo = None;
        self.program = None;
        self.gl = None;
        info!("VR renderer: GL resources destroyed");
    }
}

impl Default for VrRenderer {
    fn default() -> Self {
        Self::new()
    }
}

/// Result of rendering to a swapchain eye.
pub struct SwapchainRenderResult {
    pub eye_idx: usize,
    pub image_idx: u32,
    pub width: u32,
    pub height: u32,
}

/// Build a view matrix from an OpenXR pose.
fn view_matrix_from_xr_pose(pose: &xr::Posef) -> Mat4 {
    let q = &pose.orientation;
    let p = &pose.position;

    let transform = Transform3D {
        position: Vec3::new(p.x, p.y, p.z),
        rotation: Quat { x: q.x, y: q.y, z: q.z, w: q.w },
        scale: Vec3::ONE,
    };

    // View matrix is the inverse of the camera transform
    Mat4::from_transform(&transform)
        .inverse()
        .unwrap_or(Mat4::IDENTITY)
}

/// Build an asymmetric projection matrix from OpenXR FOV tangent angles.
fn projection_from_xr_fov(fov: &xr::Fovf, near: f32, far: f32) -> Mat4 {
    Mat4::perspective_fov(
        fov.angle_left.tan(),
        fov.angle_right.tan(),
        fov.angle_up.tan(),
        fov.angle_down.tan(),
        near,
        far,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_stereo_config_default_ipd() {
        let config = StereoConfig::default();
        assert!((config.ipd - 0.063).abs() < 0.001);
        assert!(config.left_eye.pose.position.x < 0.0);
        assert!(config.right_eye.pose.position.x > 0.0);
    }

    #[test]
    fn test_renderer_frame_count() {
        let mut renderer = VrRenderer::new();
        let scene = VrScene::new();
        assert_eq!(renderer.frame_count, 0);
        renderer.render_frame(&scene);
        assert_eq!(renderer.frame_count, 1);
        renderer.render_frame(&scene);
        assert_eq!(renderer.frame_count, 2);
    }

    #[test]
    fn test_renderer_surface_lifecycle() {
        let mut renderer = VrRenderer::new();
        renderer.register_surface(1, 1920, 1080);
        renderer.register_surface(2, 1280, 720);
        assert_eq!(renderer.texture_manager.texture_count(), 2);

        renderer.unregister_surface(1);
        assert_eq!(renderer.texture_manager.texture_count(), 1);
    }

    #[test]
    fn test_eye_view_default() {
        let eye = EyeView::default();
        assert_eq!(eye.viewport_w, 1920);
        assert_eq!(eye.viewport_h, 1080);
    }

    #[test]
    fn test_shader_sources_not_empty() {
        assert!(!VERTEX_SHADER.is_empty());
        assert!(!FRAGMENT_SHADER.is_empty());
        assert!(VERTEX_SHADER.contains("u_mvp"));
        assert!(FRAGMENT_SHADER.contains("u_alpha"));
        assert!(FRAGMENT_SHADER.contains("u_tex"));
    }

    #[test]
    fn test_quad_geometry() {
        assert_eq!(QUAD_VERTICES.len(), 20); // 4 vertices * 5 floats
        assert_eq!(QUAD_INDICES.len(), 6);   // 2 triangles * 3 indices
    }
}
