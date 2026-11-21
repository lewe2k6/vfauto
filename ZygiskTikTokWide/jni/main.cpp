// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/ZygiskTikTokWide/jni/main.cpp
// Context: C++17 Zygisk API v4 Native Module / Inline-hooks libcamera2ndk.so for TikTok Ultra-Wide 0.6x (ID 3)

#include <android/log.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>
#include "zygisk.hpp"
#include "And64InlineHook.hpp"

#define LOG_TAG "TikTokWideNDK"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static const char *kCfgPath = "/data/local/tmp/tiktok_wide_cfg.properties";
static const char *kUltraWideId = "3";

static bool isWideEnabled() {
    FILE *f = fopen(kCfgPath, "r");
    if (!f) return true; // Default ON
    char line[256];
    bool enabled = true;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "wide_enabled=", 13) == 0) {
            if (strncmp(line + 13, "false", 5) == 0 || line[13] == '0') {
                enabled = false;
            } else {
                enabled = true;
            }
            break;
        }
    }
    fclose(f);
    return enabled;
}

using open_cam_fn = int (*)(void *mgr, const char *cameraId, void *callbacks, void **device);
using get_chars_fn = int (*)(void *mgr, const char *cameraId, void **characteristics);

static open_cam_fn orig_openCamera = nullptr;
static get_chars_fn orig_getCameraCharacteristics = nullptr;

static int hooked_openCamera(void *mgr, const char *cameraId, void *callbacks, void **device) {
    if (cameraId && strcmp(cameraId, "0") == 0 && isWideEnabled()) {
        LOGI("ACameraManager_openCamera('0') -> redirected to Ultra-Wide '%s'", kUltraWideId);
        return orig_openCamera(mgr, kUltraWideId, callbacks, device);
    }
    LOGI("ACameraManager_openCamera('%s') passthrough", cameraId ? cameraId : "null");
    return orig_openCamera(mgr, cameraId, callbacks, device);
}

static int hooked_getCameraCharacteristics(void *mgr, const char *cameraId, void **characteristics) {
    if (cameraId && strcmp(cameraId, "0") == 0 && isWideEnabled()) {
        return orig_getCameraCharacteristics(mgr, kUltraWideId, characteristics);
    }
    return orig_getCameraCharacteristics(mgr, cameraId, characteristics);
}

static void installCameraNdkHooks() {
    void *handle = dlopen("/system/lib64/libcamera2ndk.so", RTLD_NOW);
    if (!handle) {
        handle = dlopen("libcamera2ndk.so", RTLD_NOW);
    }
    if (!handle) {
        LOGE("Failed to dlopen libcamera2ndk.so: %s", dlerror());
        return;
    }

    void *symOpen = dlsym(handle, "ACameraManager_openCamera");
    void *symChars = dlsym(handle, "ACameraManager_getCameraCharacteristics");

    if (symOpen) {
        A64HookFunction(symOpen, (void *)hooked_openCamera, (void **)&orig_openCamera);
        LOGI("A64HookFunction ACameraManager_openCamera (%p) -> orig=%p", symOpen, (void *)orig_openCamera);
    } else {
        LOGE("dlsym ACameraManager_openCamera not found");
    }

    if (symChars) {
        A64HookFunction(symChars, (void *)hooked_getCameraCharacteristics, (void **)&orig_getCameraCharacteristics);
        LOGI("A64HookFunction ACameraManager_getCameraCharacteristics (%p) -> orig=%p", symChars, (void *)orig_getCameraCharacteristics);
    } else {
        LOGE("dlsym ACameraManager_getCameraCharacteristics not found");
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
            LOGI("Active in TikTok process (pid=%d) -> hooking libcamera2ndk.so", getpid());
            installCameraNdkHooks();
        }
    }

private:
    zygisk::Api *api = nullptr;
    JNIEnv *env = nullptr;
    bool is_tiktok = false;
};

REGISTER_ZYGISK_MODULE(TikTokWideModule)
