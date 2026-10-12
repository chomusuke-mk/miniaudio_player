/**
 * @file map_device.c
 * @brief Audio hardware device enumeration, string serialization, and platform routing implementation.
 */

#include "map_device.h"

/* Helper to check if a device ID string represents the automatic/default output */
ma_bool32 map_is_device_id_default(const char *str)
{
    size_t i, len;
    if (str == NULL || str[0] == '\0')
        return MA_TRUE;
    if (strcmp(str, "auto") == 0 || strcmp(str, "default") == 0 || strcmp(str, "0") == 0)
        return MA_TRUE;
    len = strlen(str);
    if (len == sizeof(ma_device_id) * 2)
    {
        for (i = 0; i < len; i++)
        {
            if (str[i] != '0')
                return MA_FALSE;
        }
        return MA_TRUE;
    }
    return MA_FALSE;
}

/* Device ID serialization: converts ma_device_id to/from 512-character hex string, or integer on Android */
void map_device_id_to_string(const ma_device_id *pID, char *out_str, size_t max_len)
{
    const unsigned char *bytes = (const unsigned char *)pID;
    size_t i;
    if (out_str == NULL || max_len == 0)
        return;
    if (pID == NULL || max_len < (sizeof(ma_device_id) * 2 + 1))
    {
        out_str[0] = '\0';
        return;
    }
#if defined(__ANDROID__)
    if (pID->aaudio > 0)
    {
        snprintf(out_str, max_len, "%d", (int)pID->aaudio);
        return;
    }
    else
    {
        out_str[0] = '\0';
        return;
    }
#endif
    for (i = 0; i < sizeof(ma_device_id); i++)
    {
        sprintf(out_str + (i * 2), "%02x", bytes[i]);
    }
    out_str[sizeof(ma_device_id) * 2] = '\0';
}

ma_bool32 map_string_to_device_id(const char *str, ma_device_id *out_id)
{
    size_t i;
    if (str == NULL || out_id == NULL)
        return MA_FALSE;

    memset(out_id, 0, sizeof(ma_device_id));

    if (strlen(str) == sizeof(ma_device_id) * 2)
    {
        unsigned char *bytes = (unsigned char *)out_id;
        for (i = 0; i < sizeof(ma_device_id); i++)
        {
            unsigned int val;
            if (sscanf(str + (i * 2), "%02x", &val) != 1)
            {
                return MA_FALSE;
            }
            bytes[i] = (unsigned char)val;
        }
        return MA_TRUE;
    }

    const char *num_str = str;
    if (strncmp(str, "android:", 8) == 0)
    {
        num_str = str + 8;
    }

    char *endptr = NULL;
    long int_val = strtol(num_str, &endptr, 10);
    if (endptr != num_str && *endptr == '\0')
    {
        out_id->aaudio = (ma_int32)int_val;
        out_id->opensl = (ma_uint32)int_val;
        return MA_TRUE;
    }

    return MA_FALSE;
}

ma_bool32 map_is_device_connected(ma_context *pContext, const ma_device_id *pTargetID)
{
    ma_device_info *pPlaybackInfos;
    ma_uint32 playbackCount = 0;
    ma_uint32 i;
    ma_result res;

    if (pContext == NULL || pTargetID == NULL)
        return MA_FALSE;

    if (pContext->backend == ma_backend_aaudio)
    {
        return (pTargetID->aaudio > 0) ? MA_TRUE : MA_FALSE;
    }

#if defined(__ANDROID__)
    if (pContext->backend == ma_backend_opensl)
    {
        return (pTargetID->opensl > 0 || pTargetID->aaudio > 0) ? MA_TRUE : MA_FALSE;
    }
#endif

    res = ma_context_get_devices(pContext, &pPlaybackInfos, &playbackCount, NULL, NULL);
    if (res != MA_SUCCESS || playbackCount == 0)
        return MA_FALSE;

    for (i = 0; i < playbackCount; i++)
    {
        if (memcmp(&pPlaybackInfos[i].id, pTargetID, sizeof(ma_device_id)) == 0)
        {
            return MA_TRUE;
        }
    }
    return MA_FALSE;
}

/* ========================================================================= */
/* Android JNI Hardware Device Query & Reflection                            */
/* ========================================================================= */

#if defined(__ANDROID__)

static JavaVM *g_map_jvm = NULL;

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved)
{
    (void)reserved;
    g_map_jvm = vm;
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] JNI_OnLoad called, captured JavaVM: %p", vm);
    return JNI_VERSION_1_6;
}

MAP_API void miniaudio_player_set_jvm(void *jvm)
{
    if (jvm != NULL)
    {
        g_map_jvm = (JavaVM *)jvm;
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] miniaudio_player_set_jvm called: %p", jvm);
    }
}

typedef struct {
    const char *target_symbol;
    int match_specific_libs;
    void *found_addr;
} map_symbol_search_t;

static int map_android_phdr_callback(struct dl_phdr_info *info, size_t size, void *data)
{
    (void)size;
    map_symbol_search_t *search = (map_symbol_search_t *)data;
    if (search == NULL || search->found_addr != NULL || info->dlpi_name == NULL)
    {
        return 0;
    }

    if (search->match_specific_libs)
    {
        if (strstr(info->dlpi_name, "libart.so") == NULL &&
            strstr(info->dlpi_name, "libnativehelper.so") == NULL &&
            strstr(info->dlpi_name, "libdvm.so") == NULL &&
            strstr(info->dlpi_name, "libandroid_runtime.so") == NULL)
        {
            return 0;
        }
    }

    ElfW(Addr) base = info->dlpi_addr;
    const ElfW(Phdr) *dynamic_phdr = NULL;
    for (int i = 0; i < info->dlpi_phnum; i++)
    {
        if (info->dlpi_phdr[i].p_type == PT_DYNAMIC)
        {
            dynamic_phdr = &info->dlpi_phdr[i];
            break;
        }
    }
    if (dynamic_phdr == NULL)
    {
        return 0;
    }

    const ElfW(Dyn) *dyn = (const ElfW(Dyn) *)(base + dynamic_phdr->p_vaddr);
    const ElfW(Sym) *symtab = NULL;
    const char *strtab = NULL;
    const uint32_t *hash = NULL;
    const uint32_t *gnu_hash = NULL;

    for (const ElfW(Dyn) *d = dyn; d->d_tag != DT_NULL; d++)
    {
        ElfW(Addr) ptr = d->d_un.d_ptr;
        if (ptr < base)
        {
            ptr += base;
        }
        if (d->d_tag == DT_SYMTAB)
        {
            symtab = (const ElfW(Sym) *)ptr;
        }
        else if (d->d_tag == DT_STRTAB)
        {
            strtab = (const char *)ptr;
        }
        else if (d->d_tag == DT_HASH)
        {
            hash = (const uint32_t *)ptr;
        }
        else if (d->d_tag == DT_GNU_HASH)
        {
            gnu_hash = (const uint32_t *)ptr;
        }
    }

    if (symtab == NULL || strtab == NULL)
    {
        return 0;
    }

    size_t sym_count = 0;
    if (hash != NULL)
    {
        sym_count = hash[1];
    }
    else if (gnu_hash != NULL)
    {
        uint32_t nbuckets = gnu_hash[0];
        uint32_t symoffset = gnu_hash[1];
        uint32_t bloom_size = gnu_hash[2];
        const uint32_t *buckets = (const uint32_t *)((const char *)&gnu_hash[4] + bloom_size * sizeof(ElfW(Addr)));
        const uint32_t *chains = &buckets[nbuckets];
        uint32_t max_chain = 0;
        for (uint32_t b = 0; b < nbuckets; b++)
        {
            if (buckets[b] > max_chain)
            {
                max_chain = buckets[b];
            }
        }
        if (max_chain >= symoffset)
        {
            while (!(chains[max_chain - symoffset] & 1))
            {
                max_chain++;
            }
            sym_count = max_chain + 1;
        }
    }

    for (size_t i = 0; i < sym_count; i++)
    {
        const char *name = strtab + symtab[i].st_name;
        if (strcmp(name, search->target_symbol) == 0)
        {
            search->found_addr = (void *)(base + symtab[i].st_value);
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player",
                "[JNI] Symbol %s found in %s at %p (base=%p)", search->target_symbol, info->dlpi_name, search->found_addr, (void *)base);
            return 1;
        }
    }

    return 0;
}

static JavaVM *map_android_get_jvm(void)
{
    if (g_map_jvm != NULL)
    {
        return g_map_jvm;
    }

    typedef jint (*GetCreatedJavaVMsFn)(JavaVM **, jsize, jsize *);
    GetCreatedJavaVMsFn pfn = NULL;

    /* 1. Try RTLD_DEFAULT */
    pfn = (GetCreatedJavaVMsFn)dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
    if (pfn != NULL)
    {
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via RTLD_DEFAULT");
    }

    /* 2. Try libnativehelper.so (public NDK library on Android 12+ / API 31+) */
    if (pfn == NULL)
    {
        void *nh_handle = dlopen("libnativehelper.so", RTLD_NOW);
        if (nh_handle != NULL)
        {
            pfn = (GetCreatedJavaVMsFn)dlsym(nh_handle, "JNI_GetCreatedJavaVMs");
            if (pfn != NULL)
            {
                __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via libnativehelper.so");
            }
        }
        else
        {
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] dlopen(libnativehelper.so) failed: %s", dlerror());
        }
    }

    /* 3. Try dlopen on libart.so */
    if (pfn == NULL)
    {
        void *art_handle = dlopen("libart.so", RTLD_NOW);
        if (art_handle != NULL)
        {
            pfn = (GetCreatedJavaVMsFn)dlsym(art_handle, "JNI_GetCreatedJavaVMs");
            if (pfn != NULL)
            {
                __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via libart.so");
            }
        }
        else
        {
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] dlopen(libart.so) failed: %s", dlerror());
        }
    }

    /* 4. Try dlopen on libdvm.so (older Android Dalvik) */
    if (pfn == NULL)
    {
        void *dvm_handle = dlopen("libdvm.so", RTLD_NOW);
        if (dvm_handle != NULL)
        {
            pfn = (GetCreatedJavaVMsFn)dlsym(dvm_handle, "JNI_GetCreatedJavaVMs");
            if (pfn != NULL)
            {
                __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via libdvm.so");
            }
        }
    }

    /* 5. Try dl_iterate_phdr memory scanning on runtime libraries */
    if (pfn == NULL)
    {
        map_symbol_search_t search;
        search.target_symbol = "JNI_GetCreatedJavaVMs";
        search.match_specific_libs = 1;
        search.found_addr = NULL;
        dl_iterate_phdr(map_android_phdr_callback, &search);
        if (search.found_addr != NULL)
        {
            pfn = (GetCreatedJavaVMsFn)search.found_addr;
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via dl_iterate_phdr (targeted)");
        }
    }

    /* 6. Try dl_iterate_phdr memory scanning on ALL loaded libraries */
    if (pfn == NULL)
    {
        map_symbol_search_t search;
        search.target_symbol = "JNI_GetCreatedJavaVMs";
        search.match_specific_libs = 0;
        search.found_addr = NULL;
        dl_iterate_phdr(map_android_phdr_callback, &search);
        if (search.found_addr != NULL)
        {
            pfn = (GetCreatedJavaVMsFn)search.found_addr;
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via dl_iterate_phdr (global)");
        }
    }

    if (pfn != NULL)
    {
        JavaVM *vm = NULL;
        jsize count = 0;
        jint res = pfn(&vm, 1, &count);
        if (res == JNI_OK && count > 0 && vm != NULL)
        {
            g_map_jvm = vm;
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Successfully obtained JavaVM: %p (count: %d)", vm, (int)count);
            return g_map_jvm;
        }
        else
        {
            __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] JNI_GetCreatedJavaVMs invocation failed: res=%d, count=%d, vm=%p", (int)res, (int)count, vm);
        }
    }
    else
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not locate JNI_GetCreatedJavaVMs through any resolution strategy");
    }

    return NULL;
}

static const char *map_android_device_type_name(int type)
{
    switch (type)
    {
    case 1:  return "Earpiece";                  /* TYPE_BUILTIN_EARPIECE */
    case 2:  return "Speaker";                   /* TYPE_BUILTIN_SPEAKER */
    case 3:  return "Wired Headset";             /* TYPE_WIRED_HEADSET */
    case 4:  return "Wired Headphones";          /* TYPE_WIRED_HEADPHONES */
    case 5:  return "Line Analog";               /* TYPE_LINE_ANALOG */
    case 6:  return "Line Digital";              /* TYPE_LINE_DIGITAL */
    case 7:  return "Bluetooth Headset";         /* TYPE_BLUETOOTH_SCO */
    case 8:  return "Bluetooth Audio";           /* TYPE_BLUETOOTH_A2DP */
    case 9:  return "HDMI";                      /* TYPE_HDMI */
    case 10: return "HDMI ARC";                  /* TYPE_HDMI_ARC */
    case 11: return "USB Audio Device";          /* TYPE_USB_DEVICE */
    case 12: return "USB Audio Accessory";       /* TYPE_USB_ACCESSORY */
    case 13: return "Dock Audio";                /* TYPE_DOCK */
    case 14: return "FM Radio";                  /* TYPE_FM */
    case 15: return "Built-in Microphone";       /* TYPE_BUILTIN_MIC */
    case 16: return "FM Tuner";                  /* TYPE_FM_TUNER */
    case 17: return "TV Tuner";                  /* TYPE_TV_TUNER */
    case 18: return "Telephony";                 /* TYPE_TELEPHONY */
    case 19: return "AUX Line";                  /* TYPE_AUX_LINE */
    case 20: return "IP Audio";                  /* TYPE_IP */
    case 21: return "Bus Audio";                 /* TYPE_BUS */
    case 22: return "USB Headset";               /* TYPE_USB_HEADSET */
    case 23: return "Hearing Aid";               /* TYPE_HEARING_AID */
    case 24: return "Speaker (Safe)";            /* TYPE_BUILTIN_SPEAKER_SAFE */
    case 25: return "Remote Submix";             /* TYPE_REMOTE_SUBMIX */
    case 26: return "BLE Headset";               /* TYPE_BLE_HEADSET */
    case 27: return "BLE Speaker";               /* TYPE_BLE_SPEAKER */
    case 28: return "Echo Reference";            /* TYPE_ECHO_REFERENCE */
    case 29: return "HDMI eARC";                 /* TYPE_HDMI_EARC */
    case 30: return "BLE Broadcast";             /* TYPE_BLE_BROADCAST */
    case 31: return "Dock Analog";               /* TYPE_DOCK_ANALOG */
    case 32: return "Multichannel Group";        /* TYPE_MULTICHANNEL_GROUP */
    case 33: return "BLE Hearing Aid";           /* TYPE_BLE_HEARING_AID */
    case 34: return "BLE Central";               /* TYPE_BLE_CENTRAL */
    case 35: return "BLE Central Broadcast";     /* TYPE_BLE_CENTRAL_BROADCAST */
    default: return "Audio Output";
    }
}

static int32_t map_android_get_devices(
    miniaudio_device_info_t **out_devices,
    uint32_t *out_count)
{
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] map_android_get_devices: Starting Android audio device query...");

    JavaVM *jvm = map_android_get_jvm();
    if (jvm == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] map_android_get_devices: FAILED: Unable to obtain JavaVM instance");
        return MAP_ERROR_GENERIC;
    }

    JNIEnv *env = NULL;
    jint get_env_res = (*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6);
    ma_bool32 need_detach = MA_FALSE;

    if (get_env_res == JNI_EDETACHED)
    {
        JavaVMAttachArgs attach_args;
        attach_args.version = JNI_VERSION_1_6;
        attach_args.name = "miniaudio_get_devices";
        attach_args.group = NULL;
        if ((*jvm)->AttachCurrentThread(jvm, &env, &attach_args) != JNI_OK || env == NULL)
        {
            __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] map_android_get_devices: FAILED to attach thread to JavaVM");
            return MAP_ERROR_GENERIC;
        }
        need_detach = MA_TRUE;
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Successfully attached current thread as daemon (env=%p)", env);
    }
    else if (get_env_res != JNI_OK || env == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] GetEnv returned error code %d", get_env_res);
        return MAP_ERROR_GENERIC;
    }
    else
    {
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Current thread already attached to JVM (env=%p)", env);
    }

    int32_t status = MAP_ERROR_GENERIC;
    jclass actThreadCls = NULL;
    jobject context = NULL;
    jclass contextCls = NULL;
    jstring audioServiceStr = NULL;
    jobject audioManager = NULL;
    jclass audioManagerCls = NULL;
    jclass devInfoCls = NULL;
    jclass charSequenceCls = NULL;
    jobjectArray deviceArray = NULL;
    miniaudio_device_info_t *devices = NULL;

    actThreadCls = (*env)->FindClass(env, "android/app/ActivityThread");
    if ((*env)->ExceptionCheck(env) || actThreadCls == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not find class android.app.ActivityThread");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    jmethodID curAppMethod = (*env)->GetStaticMethodID(env, actThreadCls, "currentApplication", "()Landroid/app/Application;");
    if (!(*env)->ExceptionCheck(env) && curAppMethod != NULL)
    {
        context = (*env)->CallStaticObjectMethod(env, actThreadCls, curAppMethod);
    }
    if ((*env)->ExceptionCheck(env))
    {
        (*env)->ExceptionClear(env);
    }

    /* Fallback: currentActivityThread().getApplication() */
    if (context == NULL)
    {
        __android_log_print(ANDROID_LOG_WARN, "miniaudio_player", "[JNI] ActivityThread.currentApplication() returned null, trying currentActivityThread().getApplication()...");
        jmethodID curActThreadMethod = (*env)->GetStaticMethodID(env, actThreadCls, "currentActivityThread", "()Landroid/app/ActivityThread;");
        if (!(*env)->ExceptionCheck(env) && curActThreadMethod != NULL)
        {
            jobject actThreadObj = (*env)->CallStaticObjectMethod(env, actThreadCls, curActThreadMethod);
            if (!(*env)->ExceptionCheck(env) && actThreadObj != NULL)
            {
                jmethodID getAppMethod = (*env)->GetMethodID(env, actThreadCls, "getApplication", "()Landroid/app/Application;");
                if (!(*env)->ExceptionCheck(env) && getAppMethod != NULL)
                {
                    context = (*env)->CallObjectMethod(env, actThreadObj, getAppMethod);
                }
                (*env)->DeleteLocalRef(env, actThreadObj);
            }
        }
        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
        }
    }

    if (context == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Failed to obtain Application context from ActivityThread");
        goto cleanup;
    }
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Successfully obtained Application context: %p", context);

    contextCls = (*env)->FindClass(env, "android/content/Context");
    if ((*env)->ExceptionCheck(env) || contextCls == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not find class android.content.Context");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    jmethodID getSysServiceMethod = (*env)->GetMethodID(env, contextCls, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
    if ((*env)->ExceptionCheck(env) || getSysServiceMethod == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not find getSystemService method");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    audioServiceStr = (*env)->NewStringUTF(env, "audio");
    if ((*env)->ExceptionCheck(env) || audioServiceStr == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] NewStringUTF('audio') failed");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    audioManager = (*env)->CallObjectMethod(env, context, getSysServiceMethod, audioServiceStr);
    if ((*env)->ExceptionCheck(env) || audioManager == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] getSystemService('audio') returned null");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Successfully obtained AudioManager: %p", audioManager);

    audioManagerCls = (*env)->FindClass(env, "android/media/AudioManager");
    if ((*env)->ExceptionCheck(env) || audioManagerCls == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not find class android.media.AudioManager");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    jmethodID getDevicesMethod = (*env)->GetMethodID(env, audioManagerCls, "getDevices", "(I)[Landroid/media/AudioDeviceInfo;");
    if ((*env)->ExceptionCheck(env) || getDevicesMethod == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] AudioManager.getDevices(int) method not found (requires API 23+)");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    /* 2 = AudioManager.GET_DEVICES_OUTPUTS */
    deviceArray = (jobjectArray)(*env)->CallObjectMethod(env, audioManager, getDevicesMethod, (jint)2);
    if ((*env)->ExceptionCheck(env) || deviceArray == NULL)
    {
        __android_log_print(ANDROID_LOG_WARN, "miniaudio_player", "[JNI] AudioManager.getDevices returned null");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    devInfoCls = (*env)->FindClass(env, "android/media/AudioDeviceInfo");
    if ((*env)->ExceptionCheck(env) || devInfoCls == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not find class android.media.AudioDeviceInfo");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    jmethodID getIdMethod = (*env)->GetMethodID(env, devInfoCls, "getId", "()I");
    jmethodID getTypeMethod = (*env)->GetMethodID(env, devInfoCls, "getType", "()I");
    jmethodID getProductNameMethod = (*env)->GetMethodID(env, devInfoCls, "getProductName", "()Ljava/lang/CharSequence;");

    if ((*env)->ExceptionCheck(env) || getIdMethod == NULL || getTypeMethod == NULL || getProductNameMethod == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] AudioDeviceInfo methods not found");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    charSequenceCls = (*env)->FindClass(env, "java/lang/CharSequence");
    jmethodID toStrMethod = NULL;
    if (charSequenceCls != NULL)
    {
        toStrMethod = (*env)->GetMethodID(env, charSequenceCls, "toString", "()Ljava/lang/String;");
    }
    if ((*env)->ExceptionCheck(env))
    {
        (*env)->ExceptionClear(env);
    }

    int sdk_version = ma_android_sdk_version();
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Detected Android SDK version: %d", sdk_version);

    /* Query communication device on Android 12+ (API 31+) */
    jint comm_device_id = -1;
    if (sdk_version >= 31)
    {
        jmethodID getCommDevMethod = (*env)->GetMethodID(env, audioManagerCls, "getCommunicationDevice", "()Landroid/media/AudioDeviceInfo;");
        if (!(*env)->ExceptionCheck(env) && getCommDevMethod != NULL)
        {
            jobject commDev = (*env)->CallObjectMethod(env, audioManager, getCommDevMethod);
            if (!(*env)->ExceptionCheck(env) && commDev != NULL)
            {
                comm_device_id = (*env)->CallIntMethod(env, commDev, getIdMethod);
                if ((*env)->ExceptionCheck(env))
                {
                    (*env)->ExceptionClear(env);
                    comm_device_id = -1;
                }
                (*env)->DeleteLocalRef(env, commDev);
            }
        }
        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
        }
    }
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Active communication device ID: %d", (int)comm_device_id);

    /* Query wired headset and bluetooth states */
    jboolean is_wired_headset_on = JNI_FALSE;
    jboolean is_bt_a2dp_on = JNI_FALSE;

    jmethodID isWiredHeadsetOnMethod = (*env)->GetMethodID(env, audioManagerCls, "isWiredHeadsetOn", "()Z");
    if (!(*env)->ExceptionCheck(env) && isWiredHeadsetOnMethod != NULL)
    {
        is_wired_headset_on = (*env)->CallBooleanMethod(env, audioManager, isWiredHeadsetOnMethod);
        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
            is_wired_headset_on = JNI_FALSE;
        }
    }
    else if ((*env)->ExceptionCheck(env))
    {
        (*env)->ExceptionClear(env);
    }

    jmethodID isBtA2dpOnMethod = (*env)->GetMethodID(env, audioManagerCls, "isBluetoothA2dpOn", "()Z");
    if (!(*env)->ExceptionCheck(env) && isBtA2dpOnMethod != NULL)
    {
        is_bt_a2dp_on = (*env)->CallBooleanMethod(env, audioManager, isBtA2dpOnMethod);
        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
            is_bt_a2dp_on = JNI_FALSE;
        }
    }
    else if ((*env)->ExceptionCheck(env))
    {
        (*env)->ExceptionClear(env);
    }

    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player",
        "[JNI] Audio states: wiredHeadsetOn=%d, btA2dpOn=%d",
        (int)is_wired_headset_on, (int)is_bt_a2dp_on);

    jsize raw_count = (*env)->GetArrayLength(env, deviceArray);
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Raw output devices reported by AudioManager: %d", (int)raw_count);

    if (raw_count <= 0)
    {
        *out_devices = NULL;
        *out_count = 0;
        status = MAP_SUCCESS;
        goto cleanup;
    }

    devices = (miniaudio_device_info_t *)calloc((size_t)raw_count, sizeof(miniaudio_device_info_t));
    if (devices == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] calloc failed for %d devices", (int)raw_count);
        status = MAP_ERROR_OUT_OF_MEMORY;
        goto cleanup;
    }

    uint32_t valid_count = 0;
    int has_found_default = 0;

    for (jsize i = 0; i < raw_count; ++i)
    {
        jobject devObj = (*env)->GetObjectArrayElement(env, deviceArray, i);
        if (devObj == NULL)
        {
            continue;
        }

        jint dev_id = (*env)->CallIntMethod(env, devObj, getIdMethod);
        jint dev_type = (*env)->CallIntMethod(env, devObj, getTypeMethod);

        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
            (*env)->DeleteLocalRef(env, devObj);
            continue;
        }

        const char *typeFallback = map_android_device_type_name((int)dev_type);

        /* Extract product name */
        char prodNameBuf[256] = {0};
        jobject prodNameObj = (*env)->CallObjectMethod(env, devObj, getProductNameMethod);
        if (!(*env)->ExceptionCheck(env) && prodNameObj != NULL && toStrMethod != NULL)
        {
            jstring nameStr = (jstring)(*env)->CallObjectMethod(env, prodNameObj, toStrMethod);
            if (!(*env)->ExceptionCheck(env) && nameStr != NULL)
            {
                const char *utf = (*env)->GetStringUTFChars(env, nameStr, NULL);
                if (utf != NULL)
                {
                    const char *start = utf;
                    while (*start == ' ' || *start == '\t' || *start == '\r' || *start == '\n')
                    {
                        start++;
                    }
                    size_t len = strlen(start);
                    while (len > 0 && (start[len - 1] == ' ' || start[len - 1] == '\t' ||
                                       start[len - 1] == '\r' || start[len - 1] == '\n'))
                    {
                        len--;
                    }
                    if (len > 0 && len < sizeof(prodNameBuf))
                    {
                        memcpy(prodNameBuf, start, len);
                        prodNameBuf[len] = '\0';
                    }
                    (*env)->ReleaseStringUTFChars(env, nameStr, utf);
                }
                (*env)->DeleteLocalRef(env, nameStr);
            }
        }
        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
        }
        if (prodNameObj != NULL)
        {
            (*env)->DeleteLocalRef(env, prodNameObj);
        }

        /* Format display name */
        if (prodNameBuf[0] != '\0' && strcasecmp(prodNameBuf, "default") != 0)
        {
            snprintf(devices[valid_count].name, sizeof(devices[valid_count].name), "%s (%s)", prodNameBuf, typeFallback);
        }
        else
        {
            snprintf(devices[valid_count].name, sizeof(devices[valid_count].name), "%s", typeFallback);
        }

        /* Device ID formatted as decimal integer string */
        snprintf(devices[valid_count].id, sizeof(devices[valid_count].id), "%d", (int)dev_id);

        /* Default output detection */
        int is_default = 0;
        if (!has_found_default)
        {
            if (comm_device_id >= 0 && dev_id == comm_device_id)
            {
                is_default = 1;
            }
            else
            {
                switch (dev_type)
                {
                case 3:  /* TYPE_WIRED_HEADSET */
                case 4:  /* TYPE_WIRED_HEADPHONES */
                case 22: /* TYPE_USB_HEADSET */
                    is_default = (is_wired_headset_on == JNI_TRUE) ? 1 : 0;
                    break;
                case 8:  /* TYPE_BLUETOOTH_A2DP */
                    is_default = (is_bt_a2dp_on == JNI_TRUE) ? 1 : 0;
                    break;
                case 2:  /* TYPE_BUILTIN_SPEAKER */
                    is_default = (!is_wired_headset_on && !is_bt_a2dp_on) ? 1 : 0;
                    break;
                default:
                    is_default = 0;
                    break;
                }
            }
            if (is_default)
            {
                has_found_default = 1;
            }
        }

        devices[valid_count].is_default = is_default;
        devices[valid_count].is_auto = 0;

        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player",
            "[JNI] Discovered Audio Output [%u]: id='%s', name='%s', is_default=%d, type=%d (%s)",
            valid_count, devices[valid_count].id, devices[valid_count].name,
            devices[valid_count].is_default, (int)dev_type, typeFallback);

        valid_count++;
        (*env)->DeleteLocalRef(env, devObj);
    }

    if (!has_found_default && valid_count > 0)
    {
        devices[0].is_default = 1;
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player",
            "[JNI] Default device heuristic did not match; defaulting first device: '%s'", devices[0].name);
    }

    *out_devices = devices;
    *out_count = valid_count;
    status = MAP_SUCCESS;
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player",
        "[JNI] map_android_get_devices: Completed successfully, returning %u devices", valid_count);

cleanup:
    if (status != MAP_SUCCESS && devices != NULL)
    {
        free(devices);
        devices = NULL;
    }
    if (deviceArray != NULL)
    {
        (*env)->DeleteLocalRef(env, deviceArray);
    }
    if (charSequenceCls != NULL)
    {
        (*env)->DeleteLocalRef(env, charSequenceCls);
    }
    if (devInfoCls != NULL)
    {
        (*env)->DeleteLocalRef(env, devInfoCls);
    }
    if (audioManagerCls != NULL)
    {
        (*env)->DeleteLocalRef(env, audioManagerCls);
    }
    if (audioManager != NULL)
    {
        (*env)->DeleteLocalRef(env, audioManager);
    }
    if (audioServiceStr != NULL)
    {
        (*env)->DeleteLocalRef(env, audioServiceStr);
    }
    if (contextCls != NULL)
    {
        (*env)->DeleteLocalRef(env, contextCls);
    }
    if (context != NULL)
    {
        (*env)->DeleteLocalRef(env, context);
    }
    if (actThreadCls != NULL)
    {
        (*env)->DeleteLocalRef(env, actThreadCls);
    }

    if (need_detach)
    {
        (*jvm)->DetachCurrentThread(jvm);
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Detached current thread from JVM");
    }

    return status;
}

#else

MAP_API void miniaudio_player_set_jvm(void *jvm)
{
    (void)jvm;
}

#endif /* __ANDROID__ */

MAP_API int32_t miniaudio_player_get_devices(
    miniaudio_device_info_t **out_devices,
    uint32_t *out_count)
{
    if (out_devices == NULL || out_count == NULL)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    *out_devices = NULL;
    *out_count = 0;

#if defined(__ANDROID__)
    int32_t android_res = map_android_get_devices(out_devices, out_count);
    if (android_res == MAP_SUCCESS)
    {
        return MAP_SUCCESS;
    }
    map_log_print(MAP_LOG_LEVEL_WARNING, "android", "JNI device enumeration returned %d, falling back to miniaudio context", android_res);
#endif

    ma_context context;
    ma_result result;
    ma_device_info *pPlaybackInfos;
    ma_uint32 playbackCount = 0;
    miniaudio_device_info_t *devices = NULL;

    result = ma_context_init(NULL, 0, NULL, &context);
    if (result != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_context_init failed: %d", result);
        return MAP_ERROR_GENERIC;
    }

    result = ma_context_get_devices(&context, &pPlaybackInfos, &playbackCount, NULL, NULL);
    if (result != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_context_get_devices failed: %d", result);
        ma_context_uninit(&context);
        return MAP_ERROR_GENERIC;
    }

    if (playbackCount > 0)
    {
        devices = (miniaudio_device_info_t *)calloc(playbackCount, sizeof(miniaudio_device_info_t));
        if (devices == NULL)
        {
            ma_context_uninit(&context);
            return MAP_ERROR_OUT_OF_MEMORY;
        }

        for (ma_uint32 i = 0; i < playbackCount; ++i)
        {
            strncpy(devices[i].name, pPlaybackInfos[i].name, sizeof(devices[i].name) - 1);
            devices[i].name[sizeof(devices[i].name) - 1] = '\0';
            map_device_id_to_string(&pPlaybackInfos[i].id, devices[i].id, sizeof(devices[i].id));
            devices[i].is_default = pPlaybackInfos[i].isDefault;
            devices[i].is_auto = 0;
        }
    }

    ma_context_uninit(&context);

    *out_devices = devices;
    *out_count = playbackCount;
    return MAP_SUCCESS;
}

MAP_API void miniaudio_player_free_devices(
    miniaudio_device_info_t *devices,
    uint32_t count)
{
    (void)count;
    if (devices != NULL)
    {
        free(devices);
    }
}
