//! DMA-BUF texture import pipeline for VR rendering.
//!
//! Imports Wayland surface textures into the OpenXR/OpenGL rendering context.
//! For v0.5.0: allocates GL textures with solid color content.
//! Full zero-copy DMA-BUF import (EGL_EXT_image_dma_buf_import) deferred to v0.6.0.
//!
//! Pipeline: Wayland client -> wl_buffer -> DMA-BUF fd -> GL texture -> OpenXR swapchain

#[cfg(feature = "vr")]
use glow::HasContext;
use tracing::{debug, info, warn};

/// Texture format for VR surface rendering.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VrTextureFormat {
    Rgba8,
    Bgra8,
    Rgba16f,
}

impl VrTextureFormat {
    /// GL internal format constant.
    pub fn gl_internal_format(&self) -> u32 {
        match self {
            Self::Rgba8 => 0x8058,   // GL_RGBA8
            Self::Bgra8 => 0x8058,   // GL_RGBA8 (swizzled)
            Self::Rgba16f => 0x881A,  // GL_RGBA16F
        }
    }

    /// GL format constant.
    pub fn gl_format(&self) -> u32 {
        match self {
            Self::Rgba8 => 0x1908,  // GL_RGBA
            Self::Bgra8 => 0x80E1,  // GL_BGRA
            Self::Rgba16f => 0x1908, // GL_RGBA
        }
    }
}

/// Imported texture handle for a Wayland surface.
#[derive(Debug)]
pub struct VrTexture {
    pub surface_id: u64,
    pub gl_texture: u32,
    pub width: u32,
    pub height: u32,
    pub format: VrTextureFormat,
    pub dirty: bool,
}

impl VrTexture {
    /// Create a placeholder texture (actual import happens in render context).
    pub fn placeholder(surface_id: u64, width: u32, height: u32) -> Self {
        Self {
            surface_id,
            gl_texture: 0,
            width,
            height,
            format: VrTextureFormat::Rgba8,
            dirty: true,
        }
    }

    /// Mark texture as needing re-import (surface content changed).
    pub fn mark_dirty(&mut self) {
        self.dirty = true;
    }
}

/// Manages texture import for all VR surfaces.
pub struct TextureManager {
    textures: std::collections::HashMap<u64, VrTexture>,
}

impl TextureManager {
    pub fn new() -> Self {
        info!("VR texture manager initialized");
        Self {
            textures: std::collections::HashMap::new(),
        }
    }

    /// Register a surface for texture tracking.
    pub fn register_surface(&mut self, surface_id: u64, width: u32, height: u32) {
        let tex = VrTexture::placeholder(surface_id, width, height);
        self.textures.insert(surface_id, tex);
        debug!("VR texture: registered surface {} ({}x{})", surface_id, width, height);
    }

    /// Unregister a surface and clean up its texture (no GL context).
    pub fn unregister_surface(&mut self, surface_id: u64) {
        if let Some(tex) = self.textures.remove(&surface_id) {
            if tex.gl_texture != 0 {
                debug!(
                    "VR texture: removed surface {} (GL texture leaked without context)",
                    surface_id
                );
            }
        }
    }

    /// Unregister a surface and properly delete its GL texture.
    #[cfg(feature = "vr")]
    pub fn unregister_surface_gl(&mut self, surface_id: u64, gl: &glow::Context) {
        if let Some(tex) = self.textures.remove(&surface_id) {
            if tex.gl_texture != 0 {
                unsafe {
                    if let Some(native) = std::num::NonZeroU32::new(tex.gl_texture) {
                        gl.delete_texture(glow::NativeTexture(native));
                    }
                }
                debug!(
                    "VR texture: deleted GL texture {} for surface {}",
                    tex.gl_texture, surface_id
                );
            }
        }
    }

    /// Mark a surface texture as dirty (needs re-import).
    pub fn mark_dirty(&mut self, surface_id: u64) {
        if let Some(tex) = self.textures.get_mut(&surface_id) {
            tex.mark_dirty();
        }
    }

    /// Import pending dirty textures using GL context.
    ///
    /// For v0.5.0: creates GL textures with allocated storage (solid color).
    /// Full DMA-BUF import deferred to v0.6.0.
    #[cfg(feature = "vr")]
    pub fn import_pending_gl(&mut self, gl: &glow::Context) {
        for (id, tex) in &mut self.textures {
            if !tex.dirty {
                continue;
            }

            if tex.gl_texture == 0 {
                // Allocate new GL texture
                unsafe {
                    match gl.create_texture() {
                        Ok(native_tex) => {
                            gl.bind_texture(glow::TEXTURE_2D, Some(native_tex));

                            // Allocate storage (empty — content via DMA-BUF in v0.6.0)
                            gl.tex_image_2d(
                                glow::TEXTURE_2D,
                                0,
                                tex.format.gl_internal_format() as i32,
                                tex.width as i32,
                                tex.height as i32,
                                0,
                                tex.format.gl_format(),
                                glow::UNSIGNED_BYTE,
                                glow::PixelUnpackData::Slice(None),
                            );

                            // Set filtering
                            gl.tex_parameter_i32(
                                glow::TEXTURE_2D,
                                glow::TEXTURE_MIN_FILTER,
                                glow::LINEAR as i32,
                            );
                            gl.tex_parameter_i32(
                                glow::TEXTURE_2D,
                                glow::TEXTURE_MAG_FILTER,
                                glow::LINEAR as i32,
                            );

                            gl.bind_texture(glow::TEXTURE_2D, None);

                            // Store the raw texture ID
                            tex.gl_texture = native_tex.0.get();
                            tex.dirty = false;

                            debug!(
                                "VR texture: created GL texture {} for surface {} ({}x{})",
                                tex.gl_texture, id, tex.width, tex.height
                            );
                        }
                        Err(e) => {
                            warn!(
                                "VR texture: failed to create GL texture for surface {}: {}",
                                id, e
                            );
                        }
                    }
                }
            } else {
                // Existing texture, mark clean (actual content update via DMA-BUF in v0.6.0)
                tex.dirty = false;
            }
        }
    }

    /// Import pending dirty textures (legacy path without GL).
    pub fn import_pending(&mut self) -> Vec<(u64, u32)> {
        let mut imported = Vec::new();

        for (id, tex) in &mut self.textures {
            if tex.dirty && tex.gl_texture == 0 {
                debug!("VR texture: would import DMA-BUF for surface {}", id);
                tex.dirty = false;
                imported.push((*id, tex.gl_texture));
            }
        }

        imported
    }

    /// Get the GL texture ID for a surface.
    pub fn get_texture(&self, surface_id: u64) -> Option<u32> {
        self.textures.get(&surface_id).map(|t| t.gl_texture)
    }

    /// Get number of tracked textures.
    pub fn texture_count(&self) -> usize {
        self.textures.len()
    }
}

impl Default for TextureManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_register_unregister() {
        let mut mgr = TextureManager::new();
        mgr.register_surface(1, 1920, 1080);
        mgr.register_surface(2, 1280, 720);
        assert_eq!(mgr.texture_count(), 2);

        mgr.unregister_surface(1);
        assert_eq!(mgr.texture_count(), 1);
        assert!(mgr.get_texture(2).is_some());
    }

    #[test]
    fn test_mark_dirty() {
        let mut mgr = TextureManager::new();
        mgr.register_surface(1, 1920, 1080);

        // Import clears dirty
        mgr.import_pending();
        let tex = mgr.textures.get(&1).unwrap();
        assert!(!tex.dirty);

        // Re-mark dirty
        mgr.mark_dirty(1);
        let tex = mgr.textures.get(&1).unwrap();
        assert!(tex.dirty);
    }

    #[test]
    fn test_texture_format() {
        assert_eq!(VrTextureFormat::Rgba8.gl_internal_format(), 0x8058);
        assert_eq!(VrTextureFormat::Bgra8.gl_format(), 0x80E1);
    }
}
