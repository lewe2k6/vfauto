// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/ZygiskTikTokWide/jni/main.cpp
// Context: C++17 Zygisk API v4 Native Module (static libstdc++, zero external deps)
// Hooks:
//   1. libcamera2ndk.so: ACameraManager_openCamera + ACameraManager_getCameraCharacteristics ("0" -> "3" Ultra-Wide 0.6x)
//   2. libEGL.so: eglSwapBuffers + eglSwapBuffersWithDamageKHR -> GLES2/3 HUD overlay from /data/local/tmp/tiktok_hud/hud.rgba

#include <android/log.h>
#include <dlfcn.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <sys/prctl.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <unistd.h>
#include "zygisk.hpp"
#include "And64InlineHook.hpp"

#define LOG_TAG "TikTokWideNDK"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static const char *kCfgPath = "/data/local/tmp/tiktok_wide_cfg.properties";
static const char *kHudPath = "/data/local/tmp/tiktok_hud/hud.rgba";
static const char *kUltraWideId = "3";
static constexpr uint32_t kHudMagic = 0x48554431u; // 'HUD1'

// ---------------- Config Helper ----------------

static bool readCfgBool(const char *key, bool defVal) {
    FILE *f = fopen(kCfgPath, "r");
    if (!f) return defVal;
    char line[256];
    size_t klen = strlen(key);
    bool val = defVal;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
            const char *v = line + klen + 1;
            if (strncmp(v, "false", 5) == 0 || v[0] == '0') val = false;
            else if (strncmp(v, "true", 4) == 0 || v[0] == '1') val = true;
            break;
        }
    }
    fclose(f);
    return val;
}

static uint64_t nowMs() {
    struct timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)(ts.tv_nsec / 1000000ull);
}

// ---------------- 1. Camera2 NDK Hooks (0 -> 3 Ultra-Wide) ----------------

using open_cam_fn = int (*)(void *mgr, const char *cameraId, void *callbacks, void **device);
using get_chars_fn = int (*)(void *mgr, const char *cameraId, void **characteristics);

static open_cam_fn orig_openCamera = nullptr;
static get_chars_fn orig_getCameraCharacteristics = nullptr;

static int hooked_openCamera(void *mgr, const char *cameraId, void *callbacks, void **device) {
    if (cameraId && strcmp(cameraId, "0") == 0 && readCfgBool("wide_enabled", true)) {
        LOGI("ACameraManager_openCamera('0') -> Ultra-Wide '%s'", kUltraWideId);
        return orig_openCamera(mgr, kUltraWideId, callbacks, device);
    }
    return orig_openCamera(mgr, cameraId, callbacks, device);
}

static int hooked_getCameraCharacteristics(void *mgr, const char *cameraId, void **characteristics) {
    if (cameraId && strcmp(cameraId, "0") == 0 && readCfgBool("wide_enabled", true)) {
        return orig_getCameraCharacteristics(mgr, kUltraWideId, characteristics);
    }
    return orig_getCameraCharacteristics(mgr, cameraId, characteristics);
}

// ---------------- 2. Dynamic EGL + GLES2/3 Function Pointers ----------------

struct GlApi {
    bool loaded = false;
    EGLContext (*eglGetCurrentContext)() = nullptr;
    EGLBoolean (*eglQuerySurface)(EGLDisplay, EGLSurface, EGLint, EGLint *) = nullptr;
    void *(*eglGetProcAddress)(const char *) = nullptr;

    GLuint (*glCreateShader)(GLenum) = nullptr;
    void (*glShaderSource)(GLuint, GLsizei, const GLchar *const *, const GLint *) = nullptr;
    void (*glCompileShader)(GLuint) = nullptr;
    void (*glGetShaderiv)(GLuint, GLenum, GLint *) = nullptr;
    void (*glDeleteShader)(GLuint) = nullptr;
    GLuint (*glCreateProgram)() = nullptr;
    void (*glAttachShader)(GLuint, GLuint) = nullptr;
    void (*glLinkProgram)(GLuint) = nullptr;
    void (*glGetProgramiv)(GLuint, GLenum, GLint *) = nullptr;
    GLboolean (*glIsProgram)(GLuint) = nullptr;
    void (*glUseProgram)(GLuint) = nullptr;
    GLint (*glGetAttribLocation)(GLuint, const GLchar *) = nullptr;
    GLint (*glGetUniformLocation)(GLuint, const GLchar *) = nullptr;
    void (*glUniform1i)(GLint, GLint) = nullptr;

    void (*glGenTextures)(GLsizei, GLuint *) = nullptr;
    void (*glBindTexture)(GLenum, GLuint) = nullptr;
    void (*glTexParameteri)(GLenum, GLenum, GLint) = nullptr;
    void (*glTexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *) = nullptr;
    void (*glTexSubImage2D)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *) = nullptr;
    void (*glActiveTexture)(GLenum) = nullptr;
    void (*glPixelStorei)(GLenum, GLint) = nullptr;

    void (*glGenBuffers)(GLsizei, GLuint *) = nullptr;
    void (*glBindBuffer)(GLenum, GLuint) = nullptr;
    void (*glBufferData)(GLenum, GLsizeiptr, const void *, GLenum) = nullptr;
    void (*glEnableVertexAttribArray)(GLuint) = nullptr;
    void (*glDisableVertexAttribArray)(GLuint) = nullptr;
    void (*glVertexAttribPointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void *) = nullptr;
    void (*glDrawArrays)(GLenum, GLint, GLsizei) = nullptr;

    void (*glBindFramebuffer)(GLenum, GLuint) = nullptr;
    void (*glViewport)(GLint, GLint, GLsizei, GLsizei) = nullptr;
    void (*glEnable)(GLenum) = nullptr;
    void (*glDisable)(GLenum) = nullptr;
    GLboolean (*glIsEnabled)(GLenum) = nullptr;
    void (*glBlendFuncSeparate)(GLenum, GLenum, GLenum, GLenum) = nullptr;
    void (*glColorMask)(GLboolean, GLboolean, GLboolean, GLboolean) = nullptr;
    void (*glGetIntegerv)(GLenum, GLint *) = nullptr;
    void (*glGetBooleanv)(GLenum, GLboolean *) = nullptr;
    void (*glGetVertexAttribiv)(GLuint, GLenum, GLint *) = nullptr;

    // Optional GLES3 VAO support
    void (*glGenVertexArrays)(GLsizei, GLuint *) = nullptr;
    void (*glBindVertexArray)(GLuint) = nullptr;
};

static GlApi g_gl;

static bool loadGlApi(void *eglHandle) {
    void *gles = dlopen("/system/lib64/libGLESv2.so", RTLD_NOW);
    if (!gles) gles = dlopen("libGLESv2.so", RTLD_NOW);
    if (!eglHandle || !gles) {
        LOGE("Failed to open libEGL/libGLESv2");
        return false;
    }
    auto eSym = [&](auto &fn, const char *name) {
        fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(dlsym(eglHandle, name));
        return fn != nullptr;
    };
    auto gSym = [&](auto &fn, const char *name) {
        fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(dlsym(gles, name));
        return fn != nullptr;
    };

    bool ok = true;
    ok &= eSym(g_gl.eglGetCurrentContext, "eglGetCurrentContext");
    ok &= eSym(g_gl.eglQuerySurface, "eglQuerySurface");
    ok &= eSym(g_gl.eglGetProcAddress, "eglGetProcAddress");

    ok &= gSym(g_gl.glCreateShader, "glCreateShader");
    ok &= gSym(g_gl.glShaderSource, "glShaderSource");
    ok &= gSym(g_gl.glCompileShader, "glCompileShader");
    ok &= gSym(g_gl.glGetShaderiv, "glGetShaderiv");
    ok &= gSym(g_gl.glDeleteShader, "glDeleteShader");
    ok &= gSym(g_gl.glCreateProgram, "glCreateProgram");
    ok &= gSym(g_gl.glAttachShader, "glAttachShader");
    ok &= gSym(g_gl.glLinkProgram, "glLinkProgram");
    ok &= gSym(g_gl.glGetProgramiv, "glGetProgramiv");
    ok &= gSym(g_gl.glIsProgram, "glIsProgram");
    ok &= gSym(g_gl.glUseProgram, "glUseProgram");
    ok &= gSym(g_gl.glGetAttribLocation, "glGetAttribLocation");
    ok &= gSym(g_gl.glGetUniformLocation, "glGetUniformLocation");
    ok &= gSym(g_gl.glUniform1i, "glUniform1i");

    ok &= gSym(g_gl.glGenTextures, "glGenTextures");
    ok &= gSym(g_gl.glBindTexture, "glBindTexture");
    ok &= gSym(g_gl.glTexParameteri, "glTexParameteri");
    ok &= gSym(g_gl.glTexImage2D, "glTexImage2D");
    ok &= gSym(g_gl.glTexSubImage2D, "glTexSubImage2D");
    ok &= gSym(g_gl.glActiveTexture, "glActiveTexture");
    ok &= gSym(g_gl.glPixelStorei, "glPixelStorei");

    ok &= gSym(g_gl.glGenBuffers, "glGenBuffers");
    ok &= gSym(g_gl.glBindBuffer, "glBindBuffer");
    ok &= gSym(g_gl.glBufferData, "glBufferData");
    ok &= gSym(g_gl.glEnableVertexAttribArray, "glEnableVertexAttribArray");
    ok &= gSym(g_gl.glDisableVertexAttribArray, "glDisableVertexAttribArray");
    ok &= gSym(g_gl.glVertexAttribPointer, "glVertexAttribPointer");
    ok &= gSym(g_gl.glDrawArrays, "glDrawArrays");

    ok &= gSym(g_gl.glBindFramebuffer, "glBindFramebuffer");
    ok &= gSym(g_gl.glViewport, "glViewport");
    ok &= gSym(g_gl.glEnable, "glEnable");
    ok &= gSym(g_gl.glDisable, "glDisable");
    ok &= gSym(g_gl.glIsEnabled, "glIsEnabled");
    ok &= gSym(g_gl.glBlendFuncSeparate, "glBlendFuncSeparate");
    ok &= gSym(g_gl.glColorMask, "glColorMask");
    ok &= gSym(g_gl.glGetIntegerv, "glGetIntegerv");
    ok &= gSym(g_gl.glGetBooleanv, "glGetBooleanv");
    ok &= gSym(g_gl.glGetVertexAttribiv, "glGetVertexAttribiv");

    if (g_gl.eglGetProcAddress) {
        g_gl.glGenVertexArrays = reinterpret_cast<void (*)(GLsizei, GLuint *)>(g_gl.eglGetProcAddress("glGenVertexArrays"));
        g_gl.glBindVertexArray = reinterpret_cast<void (*)(GLuint)>(g_gl.eglGetProcAddress("glBindVertexArray"));
    }

    g_gl.loaded = ok;
    LOGI("loadGlApi ok=%d vao=%d", ok ? 1 : 0, g_gl.glBindVertexArray ? 1 : 0);
    return ok;
}

// ---------------- 3. Shared HUD Binary Buffer ----------------

#pragma pack(push, 1)
struct HudFileHeader {
    uint32_t magic;    // 0x48554431 ('HUD1')
    uint32_t version;  // 1
    uint32_t width;
    uint32_t height;
    uint32_t seq;      // monotonic version
    uint32_t visible;  // 1 = draw, 0 = hide
    uint32_t flipY;    // 0 = normal top-to-bottom, 1 = flip Y
    float    normX;    // [0..1] left
    float    normY;    // [0..1] top from top edge
    float    normW;    // [0..1] width
    float    normH;    // [0..1] height
};
#pragma pack(pop)

struct HudSnapshot {
    bool valid = false;
    HudFileHeader hdr{};
    std::vector<uint8_t> pixels;
};

static std::mutex g_hudMtx;
static HudSnapshot g_hud;
static uint64_t g_lastPollMs = 0;

static void pollHudFileIfNeeded() {
    uint64_t now = nowMs();
    std::lock_guard<std::mutex> lk(g_hudMtx);
    if (now - g_lastPollMs < 180) return;
    g_lastPollMs = now;

    FILE *f = fopen(kHudPath, "rb");
    if (!f) {
        g_hud.valid = false;
        return;
    }
    HudFileHeader hdr{};
    if (fread(&hdr, 1, sizeof(hdr), f) != sizeof(hdr)) {
        fclose(f);
        return;
    }
    if (hdr.magic != kHudMagic || hdr.visible == 0 || hdr.seq == 0 ||
        hdr.width == 0 || hdr.height == 0 || hdr.width > 1080 || hdr.height > 600) {
        g_hud.valid = false;
        fclose(f);
        return;
    }
    if (g_hud.valid && g_hud.hdr.seq == hdr.seq &&
        g_hud.hdr.width == hdr.width && g_hud.hdr.height == hdr.height) {
        g_hud.hdr = hdr;
        fclose(f);
        return;
    }
    size_t byteCount = (size_t)hdr.width * (size_t)hdr.height * 4u;
    std::vector<uint8_t> buf(byteCount);
    if (fread(buf.data(), 1, byteCount, f) == byteCount) {
        g_hud.hdr = hdr;
        g_hud.pixels.swap(buf);
        g_hud.valid = true;
    }
    fclose(f);
}

// ---------------- 4. Per-EGLContext GLES2/3 Overlay Renderer ----------------

static const char *kVertSrc =
    "attribute vec2 aPos;\n"
    "attribute vec2 aTex;\n"
    "varying vec2 vTex;\n"
    "void main() {\n"
    "  gl_Position = vec4(aPos, 0.0, 1.0);\n"
    "  vTex = aTex;\n"
    "}\n";

static const char *kFragSrc =
    "precision mediump float;\n"
    "varying vec2 vTex;\n"
    "uniform sampler2D uTex;\n"
    "void main() {\n"
    "  gl_FragColor = texture2D(uTex, vTex);\n"
    "}\n";

struct GlCtxState {
    GLuint prog = 0;
    GLuint tex = 0;
    GLuint vbo = 0;
    GLuint vao = 0;
    GLint aPos = -1;
    GLint aTex = -1;
    GLint uTex = -1;
    uint32_t texW = 0;
    uint32_t texH = 0;
    uint32_t uploadedSeq = 0;
};

static std::mutex g_glMtx;
static std::unordered_map<EGLContext, GlCtxState> g_ctxMap;
static std::unordered_set<std::string> g_loggedSurfaces;

static GLuint compileShader(GLenum type, const char *src) {
    GLuint s = g_gl.glCreateShader(type);
    if (!s) return 0;
    g_gl.glShaderSource(s, 1, &src, nullptr);
    g_gl.glCompileShader(s);
    GLint ok = 0;
    g_gl.glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        g_gl.glDeleteShader(s);
        return 0;
    }
    return s;
}

static bool ensureCtxResources(GlCtxState &st) {
    if (st.prog && g_gl.glIsProgram(st.prog)) return true;
    st = GlCtxState{};

    GLuint vs = compileShader(GL_VERTEX_SHADER, kVertSrc);
    GLuint fs = compileShader(GL_FRAGMENT_SHADER, kFragSrc);
    if (!vs || !fs) {
        if (vs) g_gl.glDeleteShader(vs);
        if (fs) g_gl.glDeleteShader(fs);
        return false;
    }
    GLuint prog = g_gl.glCreateProgram();
    g_gl.glAttachShader(prog, vs);
    g_gl.glAttachShader(prog, fs);
    g_gl.glLinkProgram(prog);
    g_gl.glDeleteShader(vs);
    g_gl.glDeleteShader(fs);

    GLint linked = 0;
    g_gl.glGetProgramiv(prog, GL_LINK_STATUS, &linked);
    if (!linked) return false;

    st.prog = prog;
    st.aPos = g_gl.glGetAttribLocation(prog, "aPos");
    st.aTex = g_gl.glGetAttribLocation(prog, "aTex");
    st.uTex = g_gl.glGetUniformLocation(prog, "uTex");
    if (st.aPos < 0 || st.aTex < 0 || st.uTex < 0) return false;

    g_gl.glGenTextures(1, &st.tex);
    g_gl.glBindTexture(GL_TEXTURE_2D, st.tex);
    g_gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    g_gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    g_gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    g_gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    g_gl.glGenBuffers(1, &st.vbo);
    if (g_gl.glGenVertexArrays && g_gl.glBindVertexArray) {
        g_gl.glGenVertexArrays(1, &st.vao);
        g_gl.glBindVertexArray(st.vao);
        g_gl.glBindBuffer(GL_ARRAY_BUFFER, st.vbo);
        g_gl.glEnableVertexAttribArray((GLuint)st.aPos);
        g_gl.glVertexAttribPointer((GLuint)st.aPos, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void *)0);
        g_gl.glEnableVertexAttribArray((GLuint)st.aTex);
        g_gl.glVertexAttribPointer((GLuint)st.aTex, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void *)(2 * sizeof(float)));
        g_gl.glBindVertexArray(0);
    }
    return true;
}

static void drawHudOnCurrentSurface(EGLDisplay dpy, EGLSurface surface) {
    if (!g_gl.loaded || dpy == EGL_NO_DISPLAY || surface == EGL_NO_SURFACE) return;

    char tname[32] = {0};
    prctl(PR_GET_NAME, tname, 0, 0, 0);
    if (strcmp(tname, "RenderThread") == 0) return;

    EGLint surfW = 0, surfH = 0;
    g_gl.eglQuerySurface(dpy, surface, EGL_WIDTH, &surfW);
    g_gl.eglQuerySurface(dpy, surface, EGL_HEIGHT, &surfH);

    // Log each unique non-RenderThread EGL surface once for diagnostics
    {
        char key[80];
        snprintf(key, sizeof(key), "%s:%dx%d", tname, surfW, surfH);
        std::lock_guard<std::mutex> lk(g_glMtx);
        if (g_loggedSurfaces.insert(key).second) {
            LOGI("EGL surface seen: thread='%s' %dx%d", tname, surfW, surfH);
        }
    }

    // Only overlay onto portrait Live preview & RTMP encoder surfaces (>= 360x480)
    if (surfW < 360 || surfH < 480 || surfW >= surfH) return;

    pollHudFileIfNeeded();

    HudFileHeader hdr{};
    std::vector<uint8_t> uploadBuf;
    bool needUpload = false;

    {
        std::lock_guard<std::mutex> lk(g_hudMtx);
        if (!g_hud.valid) return;
        hdr = g_hud.hdr;
    }

    EGLContext ctx = g_gl.eglGetCurrentContext();
    if (ctx == EGL_NO_CONTEXT) return;

    // Save current GL state before modifying anything
    GLint oldFbo = 0, oldProg = 0, oldActiveTex = 0, oldTex2D = 0;
    GLint oldArrayBuf = 0, oldElemBuf = 0, oldVao = 0, oldUnpack = 4;
    GLint oldViewport[4] = {0, 0, 0, 0};
    GLint oldBlendSrcRgb = 0, oldBlendDstRgb = 0, oldBlendSrcA = 0, oldBlendDstA = 0;
    GLboolean oldColorMask[4] = {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE};

    g_gl.glGetIntegerv(GL_FRAMEBUFFER_BINDING, &oldFbo);
    g_gl.glGetIntegerv(GL_CURRENT_PROGRAM, &oldProg);
    g_gl.glGetIntegerv(GL_ACTIVE_TEXTURE, &oldActiveTex);
    g_gl.glGetIntegerv(GL_VIEWPORT, oldViewport);
    g_gl.glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &oldArrayBuf);
    g_gl.glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &oldElemBuf);
    g_gl.glGetIntegerv(GL_UNPACK_ALIGNMENT, &oldUnpack);
    g_gl.glGetIntegerv(GL_BLEND_SRC_RGB, &oldBlendSrcRgb);
    g_gl.glGetIntegerv(GL_BLEND_DST_RGB, &oldBlendDstRgb);
    g_gl.glGetIntegerv(GL_BLEND_SRC_ALPHA, &oldBlendSrcA);
    g_gl.glGetIntegerv(GL_BLEND_DST_ALPHA, &oldBlendDstA);
    g_gl.glGetBooleanv(GL_COLOR_WRITEMASK, oldColorMask);
    if (g_gl.glBindVertexArray) {
        g_gl.glGetIntegerv(0x85B5 /* GL_VERTEX_ARRAY_BINDING */, &oldVao);
    }

    GLboolean oldBlend = g_gl.glIsEnabled(GL_BLEND);
    GLboolean oldDepth = g_gl.glIsEnabled(GL_DEPTH_TEST);
    GLboolean oldScissor = g_gl.glIsEnabled(GL_SCISSOR_TEST);
    GLboolean oldCull = g_gl.glIsEnabled(GL_CULL_FACE);
    GLboolean oldStencil = g_gl.glIsEnabled(GL_STENCIL_TEST);

    g_gl.glActiveTexture(GL_TEXTURE0);
    g_gl.glGetIntegerv(GL_TEXTURE_BINDING_2D, &oldTex2D);

    GlCtxState stCopy{};
    {
        std::lock_guard<std::mutex> lk(g_glMtx);
        GlCtxState &st = g_ctxMap[ctx];
        if (!ensureCtxResources(st)) {
            goto restore_state;
        }
        if (st.uploadedSeq != hdr.seq || st.texW != hdr.width || st.texH != hdr.height) {
            needUpload = true;
            std::lock_guard<std::mutex> hlk(g_hudMtx);
            if (!g_hud.valid || g_hud.pixels.size() != (size_t)hdr.width * hdr.height * 4u) {
                goto restore_state;
            }
            uploadBuf = g_hud.pixels;
            st.uploadedSeq = hdr.seq;
            st.texW = hdr.width;
            st.texH = hdr.height;
        }
        stCopy = st;
    }

    g_gl.glBindTexture(GL_TEXTURE_2D, stCopy.tex);
    if (needUpload) {
        g_gl.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        g_gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)hdr.width, (GLsizei)hdr.height,
                          0, GL_RGBA, GL_UNSIGNED_BYTE, uploadBuf.data());
        g_gl.glPixelStorei(GL_UNPACK_ALIGNMENT, oldUnpack);
    }

    // Compute quad NDC vertices from normalized HUD rectangle
    {
        float x0 = -1.0f + 2.0f * hdr.normX;
        float x1 = -1.0f + 2.0f * (hdr.normX + hdr.normW);
        float yTop = 1.0f - 2.0f * hdr.normY;
        float yBot = 1.0f - 2.0f * (hdr.normY + hdr.normH);
        float vTop = hdr.flipY ? 1.0f : 0.0f;
        float vBot = hdr.flipY ? 0.0f : 1.0f;

        const float verts[16] = {
            x0, yTop, 0.0f, vTop,
            x0, yBot, 0.0f, vBot,
            x1, yTop, 1.0f, vTop,
            x1, yBot, 1.0f, vBot
        };

        g_gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        g_gl.glViewport(0, 0, surfW, surfH);
        g_gl.glDisable(GL_DEPTH_TEST);
        g_gl.glDisable(GL_SCISSOR_TEST);
        g_gl.glDisable(GL_CULL_FACE);
        g_gl.glDisable(GL_STENCIL_TEST);
        g_gl.glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        g_gl.glEnable(GL_BLEND);
        // Android Bitmap Canvas produces premultiplied alpha -> GL_ONE, GL_ONE_MINUS_SRC_ALPHA
        g_gl.glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        g_gl.glUseProgram(stCopy.prog);
        g_gl.glUniform1i(stCopy.uTex, 0);

        if (stCopy.vao && g_gl.glBindVertexArray) {
            g_gl.glBindVertexArray(stCopy.vao);
            g_gl.glBindBuffer(GL_ARRAY_BUFFER, stCopy.vbo);
            g_gl.glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);
            g_gl.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        } else {
            GLint oldPosEn = 0, oldTexEn = 0;
            g_gl.glGetVertexAttribiv((GLuint)stCopy.aPos, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &oldPosEn);
            g_gl.glGetVertexAttribiv((GLuint)stCopy.aTex, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &oldTexEn);

            g_gl.glBindBuffer(GL_ARRAY_BUFFER, stCopy.vbo);
            g_gl.glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);
            g_gl.glEnableVertexAttribArray((GLuint)stCopy.aPos);
            g_gl.glVertexAttribPointer((GLuint)stCopy.aPos, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void *)0);
            g_gl.glEnableVertexAttribArray((GLuint)stCopy.aTex);
            g_gl.glVertexAttribPointer((GLuint)stCopy.aTex, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void *)(2 * sizeof(float)));
            g_gl.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

            if (!oldPosEn) g_gl.glDisableVertexAttribArray((GLuint)stCopy.aPos);
            if (!oldTexEn) g_gl.glDisableVertexAttribArray((GLuint)stCopy.aTex);
        }
    }

restore_state:
    if (g_gl.glBindVertexArray) g_gl.glBindVertexArray((GLuint)oldVao);
    g_gl.glBindBuffer(GL_ARRAY_BUFFER, (GLuint)oldArrayBuf);
    g_gl.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, (GLuint)oldElemBuf);
    g_gl.glBindTexture(GL_TEXTURE_2D, (GLuint)oldTex2D);
    g_gl.glActiveTexture((GLenum)oldActiveTex);
    g_gl.glUseProgram((GLuint)oldProg);
    g_gl.glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)oldFbo);
    g_gl.glViewport(oldViewport[0], oldViewport[1], oldViewport[2], oldViewport[3]);
    g_gl.glBlendFuncSeparate((GLenum)oldBlendSrcRgb, (GLenum)oldBlendDstRgb,
                             (GLenum)oldBlendSrcA, (GLenum)oldBlendDstA);
    g_gl.glColorMask(oldColorMask[0], oldColorMask[1], oldColorMask[2], oldColorMask[3]);
    if (oldBlend) g_gl.glEnable(GL_BLEND); else g_gl.glDisable(GL_BLEND);
    if (oldDepth) g_gl.glEnable(GL_DEPTH_TEST); else g_gl.glDisable(GL_DEPTH_TEST);
    if (oldScissor) g_gl.glEnable(GL_SCISSOR_TEST); else g_gl.glDisable(GL_SCISSOR_TEST);
    if (oldCull) g_gl.glEnable(GL_CULL_FACE); else g_gl.glDisable(GL_CULL_FACE);
    if (oldStencil) g_gl.glEnable(GL_STENCIL_TEST); else g_gl.glDisable(GL_STENCIL_TEST);
}

using egl_swap_fn = EGLBoolean (*)(EGLDisplay, EGLSurface);
using egl_swap_dmg_fn = EGLBoolean (*)(EGLDisplay, EGLSurface, const EGLint *, EGLint);

static egl_swap_fn orig_eglSwapBuffers = nullptr;
static egl_swap_dmg_fn orig_eglSwapBuffersWithDamageKHR = nullptr;
static thread_local bool g_inSwap = false;

static EGLBoolean hooked_eglSwapBuffers(EGLDisplay dpy, EGLSurface surface) {
    if (!g_inSwap) {
        g_inSwap = true;
        drawHudOnCurrentSurface(dpy, surface);
        EGLBoolean ret = orig_eglSwapBuffers(dpy, surface);
        g_inSwap = false;
        return ret;
    }
    return orig_eglSwapBuffers(dpy, surface);
}

static EGLBoolean hooked_eglSwapBuffersWithDamageKHR(EGLDisplay dpy, EGLSurface surface,
                                                     const EGLint *rects, EGLint n_rects) {
    if (!g_inSwap) {
        g_inSwap = true;
        drawHudOnCurrentSurface(dpy, surface);
        EGLBoolean ret = orig_eglSwapBuffersWithDamageKHR(dpy, surface, rects, n_rects);
        g_inSwap = false;
        return ret;
    }
    return orig_eglSwapBuffersWithDamageKHR(dpy, surface, rects, n_rects);
}

// ---------------- 5. Hook Installation ----------------

static void installHooks() {
    // 1) Camera2 NDK
    void *camHandle = dlopen("/system/lib64/libcamera2ndk.so", RTLD_NOW);
    if (!camHandle) camHandle = dlopen("libcamera2ndk.so", RTLD_NOW);
    if (camHandle) {
        void *symOpen = dlsym(camHandle, "ACameraManager_openCamera");
        void *symChars = dlsym(camHandle, "ACameraManager_getCameraCharacteristics");
        if (symOpen) {
            A64HookFunction(symOpen, (void *)hooked_openCamera, (void **)&orig_openCamera);
            LOGI("Hooked ACameraManager_openCamera (%p)", symOpen);
        }
        if (symChars) {
            A64HookFunction(symChars, (void *)hooked_getCameraCharacteristics, (void **)&orig_getCameraCharacteristics);
            LOGI("Hooked ACameraManager_getCameraCharacteristics (%p)", symChars);
        }
    } else {
        LOGE("dlopen libcamera2ndk.so failed: %s", dlerror());
    }

    // 2) EGL HUD overlay
    void *eglHandle = dlopen("/system/lib64/libEGL.so", RTLD_NOW);
    if (!eglHandle) eglHandle = dlopen("libEGL.so", RTLD_NOW);
    if (eglHandle && loadGlApi(eglHandle)) {
        void *symSwap = dlsym(eglHandle, "eglSwapBuffers");
        if (symSwap) {
            A64HookFunction(symSwap, (void *)hooked_eglSwapBuffers, (void **)&orig_eglSwapBuffers);
            LOGI("Hooked eglSwapBuffers (%p)", symSwap);
        }
        void *symSwapDmg = dlsym(eglHandle, "eglSwapBuffersWithDamageKHR");
        if (symSwapDmg) {
            A64HookFunction(symSwapDmg, (void *)hooked_eglSwapBuffersWithDamageKHR,
                            (void **)&orig_eglSwapBuffersWithDamageKHR);
            LOGI("Hooked eglSwapBuffersWithDamageKHR (%p)", symSwapDmg);
        }
    } else {
        LOGE("EGL HUD hook skipped (libEGL/libGLESv2 init failed)");
    }
}

class TikTokWideModule : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        this->api = api;
        this->env = env;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        const char *proc = env->GetStringUTFChars(args->nice_name, nullptr);
        if (proc) {
            if (strcmp(proc, "com.ss.android.ugc.trill") == 0 ||
                strcmp(proc, "com.zhiliaoapp.musically") == 0) {
                is_tiktok = true;
            }
            env->ReleaseStringUTFChars(args->nice_name, proc);
        }
        if (!is_tiktok) {
            api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
        }
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *args) override {
        if (is_tiktok) {
            LOGI("Active in TikTok (pid=%d) -> installing Camera2 + EGL HUD hooks", getpid());
            installHooks();
        }
    }

private:
    zygisk::Api *api = nullptr;
    JNIEnv *env = nullptr;
    bool is_tiktok = false;
};

REGISTER_ZYGISK_MODULE(TikTokWideModule)
