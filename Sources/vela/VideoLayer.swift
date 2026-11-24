// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CMpv
import OpenGL.GL3

private let glLibrary = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)

/// Core Animation layer that lets libmpv draw straight into its OpenGL framebuffer.
/// VideoToolbox frames reach GL as IOSurfaces, so decoded video is never copied by the CPU.
final class VideoLayer: CAOpenGLLayer {
    private let player: Player
    private var renderContext: OpaquePointer?
    private var glContext: CGLContextObj?
    private var pixelFormat: CGLPixelFormatObj?
    /// GL_RGBA16F when we got a half-float framebuffer, 0 (unknown, mpv assumes 8-bit) otherwise.
    private var framebufferFormat: Int32 = 0
    private var loggedFramebuffer = false

    init(player: Player) {
        self.player = player
        super.init()
        // Core Animation asks canDraw() on every display refresh (vsync); we draw only when
        // mpv has a new frame. This keeps frame timing tied to the screen, not the main thread.
        isAsynchronous = true
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // mpv needs the render context before a file loads, or it disables video.
        // So we own the GL context and create it now instead of on first draw.
        // Prefer a 16-bit float framebuffer so 10-bit video reaches the screen without banding
        // (mpv's own window uses a 10-bit surface for the same reason). Fall back to 8-bit.
        if let pf = Self.makePixelFormat(deep: true) {
            pixelFormat = pf
            framebufferFormat = Int32(GL_RGBA16F)
            // Core Animation treats float surfaces as linear light unless told otherwise, which
            // brightens mpv's gamma-encoded output (washed-out shadows). Declare what mpv writes:
            // BT.709 primaries with a display gamma, i.e. sRGB — same as an 8-bit surface.
            colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        } else {
            pixelFormat = Self.makePixelFormat(deep: false)
        }
        if let pf = pixelFormat {
            CGLCreateContext(pf, nil, &glContext)
            if let gl = glContext {
                CGLSetCurrentContext(gl)
                createRenderContext()
            }
        }
    }

    override init(layer: Any) {
        player = (layer as! VideoLayer).player
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - GL setup

    private static func makePixelFormat(deep: Bool) -> CGLPixelFormatObj? {
        var attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
        ]
        if deep { attrs += [kCGLPFAColorSize, CGLPixelFormatAttribute(64), kCGLPFAColorFloat] }
        attrs.append(CGLPixelFormatAttribute(0))
        var pf: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attrs, &pf, &count)
        return pf
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        pixelFormat ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        glContext ?? super.copyCGLContext(forPixelFormat: pf)
    }

    private func createRenderContext() {
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in dlsym(glLibrary, name) },
            get_proc_address_ctx: nil)
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }

        withUnsafeMutablePointer(to: &initParams) { ip in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: ip),
                mpv_render_param(),
            ]
            if mpv_render_context_create(&renderContext, player.handle, &params) < 0 {
                fputs("vela: could not create render context\n", stderr)
            }
        }

    }

    // MARK: - Drawing

    /// Set when the window resizes so the current frame is redrawn even without a new one.
    private var forceRedraw = true

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        guard let rc = renderContext else { return false }
        let newFrame = mpv_render_context_update(rc) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
        defer { forceRedraw = false }
        return newFrame || forceRedraw
    }

    override var bounds: CGRect {
        didSet { forceRedraw = true }
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        guard let rc = renderContext else { return }
        var fboID: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fboID)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        // Telling mpv the real depth lets it dither for 16-bit output instead of 8-bit.
        var fbo = mpv_opengl_fbo(fbo: fboID, w: viewport[2], h: viewport[3], internal_format: framebufferFormat)
        if !loggedFramebuffer, ProcessInfo.processInfo.environment["VELA_DEBUG"] != nil {
            loggedFramebuffer = true
            var bits: GLint = 0, type: GLint = 0
            let attachment = GLenum(fboID == 0 ? GL_BACK_LEFT : GL_COLOR_ATTACHMENT0)
            glGetFramebufferAttachmentParameteriv(GLenum(GL_DRAW_FRAMEBUFFER), attachment, GLenum(GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE), &bits)
            glGetFramebufferAttachmentParameteriv(GLenum(GL_DRAW_FRAMEBUFFER), attachment, GLenum(GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE), &type)
            fputs("framebuffer: fbo=\(fboID) red_bits=\(bits) float=\(type == GL_FLOAT) told_mpv=\(framebufferFormat == Int32(GL_RGBA16F) ? "RGBA16F" : "unknown")\n", stderr)
        }
        var flipY: Int32 = 1
        withUnsafeMutablePointer(to: &fbo) { fp in
            withUnsafeMutablePointer(to: &flipY) { yp in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fp),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: yp),
                    mpv_render_param(),
                ]
                mpv_render_context_render(rc, &params)
            }
        }
        glFlush()
        mpv_render_context_report_swap(rc)
    }

    /// Must run before the Player is destroyed.
    func shutdown() {
        guard let rc = renderContext else { return }
        if let gl = glContext { CGLSetCurrentContext(gl) }
        mpv_render_context_free(rc)
        renderContext = nil
    }
}
