//! Build script for `miniaudio_player_rust`.
//! Compiles native C bridge (`miniaudio_device_bridge.c`) and links platform-specific audio libraries.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=c_src/miniaudio_device_bridge.c");
    println!("cargo:rerun-if-changed=c_src/miniaudio_device_bridge.h");
    println!("cargo:rerun-if-changed=c_src/miniaudio.h");

    let target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    if target_arch == "wasm32" {
        return;
    }

    let mut build = cc::Build::new();
    build
        .file("c_src/miniaudio_device_bridge.c")
        .include("c_src")
        .warnings(false)
        .opt_level(3)
        .flag_if_supported("-ffunction-sections")
        .flag_if_supported("-fdata-sections")
        .flag_if_supported("-fvisibility=hidden");

    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "android" {
        println!("cargo:rustc-link-lib=OpenSLES");
        println!("cargo:rustc-link-lib=log");
        println!("cargo:rustc-cdylib-link-arg=-Wl,-z,max-page-size=16384");
        println!("cargo:rustc-cdylib-link-arg=-Wl,-Bsymbolic-functions");
        println!("cargo:rustc-cdylib-link-arg=-Wl,-soname,libminiaudio_player.so");
    } else if target_os == "linux" {
        println!("cargo:rustc-link-lib=pthread");
        println!("cargo:rustc-link-lib=m");
        println!("cargo:rustc-link-lib=dl");
        println!("cargo:rustc-cdylib-link-arg=-Wl,-Bsymbolic-functions");
        println!("cargo:rustc-cdylib-link-arg=-Wl,-soname,libminiaudio_player.so");
    } else if target_os == "windows" {
        println!("cargo:rustc-link-lib=ole32");
        println!("cargo:rustc-link-lib=winmm");
        println!("cargo:rustc-link-lib=advapi32");
    } else if target_os == "macos" || target_os == "ios" {
        println!("cargo:rustc-link-lib=framework=CoreAudio");
        println!("cargo:rustc-link-lib=framework=AudioToolbox");
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libminiaudio_player.dylib");
        println!("cargo:rustc-cdylib-link-arg=-Wl,-headerpad_max_install_names");
        if target_os == "ios" {
            build.flag("-x").flag("objective-c");

            println!("cargo:rustc-link-lib=objc");
            println!("cargo:rustc-link-lib=pthread");
            println!("cargo:rustc-link-lib=m");

            for framework in [
                "Foundation",
                "CoreFoundation",
                "CoreAudio",
                "AudioToolbox",
                "AVFoundation",
                "AVFAudio",
                "UIKit",
            ] {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
        }
    }

    build.compile("miniaudio_bridge");
}
