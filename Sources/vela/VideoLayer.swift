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
        pixelFormat = Self.makePixelFormat()
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

    private static func makePixelFormat() -> CGLPixelFormatObj? {
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
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

        var fbo = mpv_opengl_fbo(fbo: fboID, w: viewport[2], h: viewport[3], internal_format: 0)
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
