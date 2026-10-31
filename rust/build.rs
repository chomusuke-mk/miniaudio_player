fn main() {
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
    } else if target_os == "linux" {
        println!("cargo:rustc-link-lib=pthread");
        println!("cargo:rustc-link-lib=m");
        println!("cargo:rustc-link-lib=dl");
    } else if target_os == "windows" {
        println!("cargo:rustc-link-lib=ole32");
        println!("cargo:rustc-link-lib=winmm");
        println!("cargo:rustc-link-lib=advapi32");
    } else if target_os == "macos" || target_os == "ios" {
        println!("cargo:rustc-link-lib=framework=CoreAudio");
        println!("cargo:rustc-link-lib=framework=AudioToolbox");
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
    }

    build.compile("miniaudio_bridge");
    println!("cargo:rerun-if-changed=c_src/miniaudio_device_bridge.c");
    println!("cargo:rerun-if-changed=c_src/miniaudio_device_bridge.h");
    println!("cargo:rerun-if-changed=c_src/miniaudio.h");
}
