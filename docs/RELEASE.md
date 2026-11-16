# Plan de Corrección de Empaquetado, Compilación y Distribución (`docs/RELEASE.md`)

Este documento recopila el análisis técnico completo de los problemas detectados en el sistema de build (`hook/build.dart`), empaquetado Web/Native (`pubspec.yaml`, `.pubignore`, `lib/src/loader/*`) y publicación de binarios (`.github/workflows/release-binaries.yml`), junto con un plan paso a paso con checklists para ejecutar y verificar cada solución.

> **Estado inicial del diagnóstico (2026-11-15):** Auditoría verificada sobre Flutter `3.47.6` (`Dart 3.13.5`), `flutter_rust_bridge` `2.13.0`, `hooks` `2.2.0`, `code_assets` `2.2.0`, `native_toolchain_rust` `1.1.1` y `flutter_rust_bridge_hooks` `2.13.0`.

---

## 1. Resumen Ejecutivo de Hallazgos

| # | Problema detectado | Severidad | Impacto principal |
|---|---|---|---|
| **P1** | `web/pkg/.gitignore` (`*`) excluye el WASM del tarball de `pub.dev` | 🔴 **Muy grave** | `flutter pub publish --dry-run` omite `web/pkg/miniaudio_player.{js,wasm}`; cualquier usuario Web vía `pub.dev` falla. |
| **P2** | `flutter: assets:` copia `3.8 MB` de WASM/JS a builds no-Web | 🔴 **Muy grave** | Verificado en `example/build/linux/.../flutter_assets/` y `example/build/flutter_assets/`; infla APKs, EXEs, bundles Linux/macOS/iOS innecesariamente. |
| **P3** | Job `build-web` en CI usa `stable` + `wasm-bindgen-cli 0.2.100` vs `Cargo.lock` `0.2.130` | 🔴 **Muy grave** | Falla por mismatch de versión y carece de `nightly` + `+atomics` + `-Z build-std=std,panic_abort` requeridos para `SharedArrayBuffer`. |
| **P4** | Pipeline de Releases incompleto y versiones desalineadas (`3.0.2` / `3.1.0` / `^4.0.0`) | 🔴 **Muy grave** | `_embeddedReleaseHashes` vacío en `hook/build.dart`, sin tags publicados, y `BuildError` en descarga aborta sin fallback local. |
| **P5** | `_provisionWebAssetsIfNeeded` contamina `<app>/web/pkg/` + `example/web/pkg/` duplicado | 🟠 **Grave** | Escribe archivos fuera de `build/` en el árbol fuente del consumidor; `example/web/pkg/` está versionado y aporta ~3 MB extra al tarball de `pub.dev`. |
| **P6** | Falta `windows-arm64` nativo/`msvc-dev-cmd` correcto y falta soporte `x86` (`ia32`) en Android, Windows y Linux | 🟠 **Grave** | `aarch64-pc-windows-msvc` corre en `windows-latest` sin inicializar `amd64_arm64` ni `windows-11-arm`; faltan `i686-linux-android`, `i686-pc-windows-msvc` y `i686-unknown-linux-gnu`. |
| **P7** | Problemas en compilación Apple (macOS/iOS): filtro `Developer` en `PATH`, env heredado de Xcode, API deprecada y `@rpath` local | 🟠 **Grave** | `PATH` puede perder toolchains o heredar `SDKROOT` de iOS en builds host de `build.rs`; `platform_loader_io.dart` puede cargar `rust/target/release` antes que el `.framework`. |
| **P8** | Fallos en compilación fuente y empaquetado de releases (espacios en rutas, `cCompiler` ignorado, `.tar.gz` dependiente de `tar`, binario no stripped del todo) | 🟠 **Grave** | `CFLAGS_*` / `RUSTFLAGS` sin escape fallan con espacios; Linux/Windows ignoran `codeConfig.cCompiler`; `.tar.gz` es innecesario para 1 archivo y depende de `tar` en Windows; `strip = "debuginfo"` deja el `.so` en `12.2 MB` (`8.7 MB` con `strip = "symbols"`). |
| **P9** | Detección/validación de arquitectura bajo emulación (`Abi.current()`) o cross-compile | 🟠 **Grave** | Un SDK Flutter/Dart x64 corriendo bajo emulación en Windows ARM64 o Linux ARM64 solicita binarios `x64`; falta validación ELF/PE/Mach-O antes de emitir `CodeAsset` y en CI. |
| **P10** | Desincronización silenciosa de WASM local y colisión potencial de `wasmBindgenName` | 🟡 **Moderado** | Editar `rust/` no invalida ni avisa respecto al WASM empaquetado; `wasm_bindgen` genérico en `frb_generated.dart` colisiona con otros plugins FRB. |
| **P11** | Acumulación de `cargo_target/` (`~1 GB`) en `.dart_tool/` y `%TEMP%` | 🟡 **Moderado** | Cada app que cae a compilación local duplica ~994 MB en disco sin limpieza. |

---

## 2. Análisis Detallado por Área

### 2.1 WebAssembly, `.gitignore` de `wasm-pack` y Filtrado de Assets por Plataforma

1. **Por qué `web/pkg/` no debe usarse como directorio fuente directo:**
   * `flutter_rust_bridge_codegen build-web --release` invoca internamente `wasm-pack build -t no-modules -d <output>/pkg ...` (`flutter_rust_bridge/lib/src/cli/build_web/executor.dart`).
   * `wasm-pack` genera siempre dentro del directorio destino un archivo `.gitignore` con `*`, además de `package.json`, `miniaudio_player.d.ts` y `miniaudio_player_bg.wasm.d.ts` que Dart/Flutter no necesitan en runtime.
   * Aunque se haga `git add -f`, **Dart `pub` respeta el `.gitignore` anidado en `web/pkg/.gitignore`**. Al ejecutar `flutter pub publish --dry-run` se verificó que:
     * Emite la advertencia `Files that are checked in while gitignored: web/pkg/miniaudio_player.js, web/pkg/miniaudio_player_bg.wasm`.
     * **Omite completamente `web/pkg/` del archivo `.tar.gz` publicado** (mientras sí incluye `example/web/pkg/`, inflando el paquete en ~3 MB sin arreglar la librería).

2. **Validación empírica: los archivos WASM/JS SÍ se estaban copiando en Android, Linux y Windows:**
   * En este workspace, `pubspec.yaml` (líneas 41-44) declara:
     ```yaml
     flutter:
       assets:
         - web/pkg/miniaudio_player.js
         - web/pkg/miniaudio_player_bg.wasm
     ```
   * Al inspeccionar `example/build/` se verificó la presencia de copias duplicadas en plataformas nativas:
     * `example/build/linux/x64/debug/bundle/data/flutter_assets/packages/miniaudio_player/web/pkg/miniaudio_player_bg.wasm`
     * `example/build/flutter_assets/packages/miniaudio_player/web/pkg/miniaudio_player_bg.wasm` (compartido por el bundle Android/genérico)
     * `example/build/unit_test_assets/packages/miniaudio_player/web/pkg/miniaudio_player_bg.wasm`
   * Esto agrega ~`3.8 MB` muertos en cada APK, AAB, EXE o bundle de escritorio.

3. **Solución nativa de Flutter para restringir assets únicamente a Web:**
   * Inspeccionando el SDK local (`flutter_tools/lib/src/flutter_manifest.dart` líneas 843-937, `flutter_tools/lib/src/asset.dart` líneas 1128-1136 y 1544-1550, `build_info.dart` línea 709), Flutter soporta desde la versión **3.41.0** el filtro `platforms:` por entrada de asset, y sí aplica a assets declarados en `pubspec.yaml` de paquetes/plugins (`_parseAssets`):
     ```yaml
     environment:
       sdk: ">=3.6.0 <4.0.0"
       flutter: ">=3.41.0"

     flutter:
       assets:
         - path: assets/web/miniaudio_player.js
           platforms:
             - web
         - path: assets/web/miniaudio_player_bg.wasm
           platforms:
             - web
     ```
   * **Notas de validación:**
     * Con `platforms: [web]`, en `flutter build apk/appbundle/linux/windows/macos/ios`, `asset.matchesPlatform(targetPlatform)` devuelve `false` y el log muestra `Skipping assets entry ...` sin copiar los `3.8 MB` a los artefactos nativos.
     * Única excepción conocida en `asset.dart:1545`: `if (platforms.isEmpty || targetPlatform == TargetPlatform.tester) return true;`, por lo que `flutter test` (`tester`) los incluye en `build/unit_test_assets/` durante tests locales, pero **nunca** en builds de dispositivo/escritorio.
     * Se evaluó también usar `DataAsset` mediante `hook/build.dart`, pero en `flutter_tools/lib/src/features.dart` (líneas 214-220) la bandera `dartDataAssets` sigue disponible solo en canal `master` y desactivada por defecto (`enabledByDefault: false`), por lo que **no es viable en Flutter `stable` (`3.47.6`)**.
   * **Directorio limpio (`assets/web/`) vs `web/pkg/`:**
     * Mover la salida final limpia (solo `miniaudio_player.js` y `miniaudio_player_bg.wasm`, sin `.gitignore`, `.d.ts` ni `package.json`) a `assets/web/`, generándola desde un directorio staging ignorado (`build/web_wasm/pkg/` o `web/pkg/` en `.gitignore` y `.pubignore`) mediante un script `tool/build_web_wasm.dart`.
     * Actualizar `lib/src/loader/platform_loader_web.dart` (`_candidateWebPrefixes`):
       1. `'assets/packages/miniaudio_player/assets/web/'`
       2. `'packages/miniaudio_player/assets/web/'`
       3. `'pkg/'` (opcional por compatibilidad si una app aloja WASM custom manualmente)
     * Eliminar `_provisionWebAssetsIfNeeded(input)` de `hook/build.dart` y eliminar `example/web/pkg/` de git (añadiendo `/example/web/pkg/` y `/web/pkg/` a `.pubignore` y `example/.gitignore`).

---

### 2.2 Análisis de Compilación para macOS e iOS (Rutas, Xcode, Frameworks y Loader)

Revisando `hook/build.dart`, `rust/build.rs`, `lib/src/loader/platform_loader_io.dart` y `flutter_tools/lib/src/isolated/native_assets/{macos,ios}/`:

1. **Cómo empaqueta Flutter los `CodeAsset` en Darwin:**
   * Cuando `hook/build.dart` entrega `CodeAsset(linkMode: DynamicLoadingBundled(), file: .../libminiaudio_player.dylib)`, Flutter invoca `copyNativeCodeAssetsMacOS` / `copyNativeCodeAssetsIOS` (`macos/native_assets_host.dart`):
     * Combina slices (`arm64` + `x86_64`) con `xcrun lipo`.
     * Convierte `libminiaudio_player.dylib` en el framework `miniaudio_player.framework/miniaudio_player` (`frameworkUri` quita el prefijo `lib` y la extensión `.dylib`).
     * Reemplaza el `install_name` por `@rpath/miniaudio_player.framework/miniaudio_player` vía `install_name_tool` (compatible gracias a `-Wl,-headerpad_max_install_names` en `rust/build.rs:47`), genera `Info.plist`, extrae `dSYM` en non-debug y ejecuta `codesign`.
   * En `flutter test` (`flutter_tester`), macOS **no** crea `.framework`, sino `build/native_assets/macos/libminiaudio_player.dylib` con install-name absoluto.

2. **Problemas reales detectados en macOS / iOS:**
   * **Filtro destructivo de `PATH` (`hook/build.dart:739-744`):**
     ```dart
     if (Platform.isMacOS && targetOS == OS.iOS) {
       currentPath = currentPath
           .split(':')
           .where((e) => !p.split(e).contains('Developer'))
           .join(':');
     }
     ```
     Si el usuario guarda proyectos, Homebrew o toolchains en una carpeta llamada `Developer` (muy común en macOS: `~/Developer/...`), este filtro rompe `PATH` o elimina herramientas necesarias. Además, no limpia las variables globales de Xcode que sí rompen los scripts `build.rs` del host al compilar para iOS (`SDKROOT`, `PLATFORM_NAME`, `ARCHS`, `CC`, `CXX`, `CFLAGS`, `LDFLAGS`, `LIBRARY_PATH`, `CPATH`).
   * **`codeConfig.cCompiler` ignorado y `deploymentVersion` deprecada:**
     * `hook/build.dart:749,752` lee `codeConfig.iOS.targetVersion` y `codeConfig.macOS.targetVersion` (`@Deprecated`, solo entero mayor), ignorando `deploymentVersion` (`AppleVersion` `major.minor`).
     * Flutter ya pasa en `codeConfig.cCompiler` el compilador exacto elegido con `xcrun --find` (`macos/native_assets_host.dart:208-236`), pero `hook/build.dart` no configura `CC_<triple>` / `AR_<triple>` por target ni desacopla el compilador del host del compilador objetivo iOS. Si el desarrollador tiene múltiples instalaciones de Xcode (`Xcode.app` vs `Xcode 16.app` con espacios en la ruta), `cc::Build` puede elegir un SDK distinto al de Flutter.
   * **Rutas con espacios en Xcode / macOS:**
     * A diferencia de Android, hoy `hook/build.dart` no pasa rutas en `RUSTFLAGS` para Apple; sin embargo, si se pasan rutas de `xcrun` / `--sysroot` mediante `CARGO_TARGET_*_RUSTFLAGS` separadas por espacio en lugar de `CARGO_ENCODED_RUSTFLAGS` (`\x1f`), cualquier Xcode con espacio en el nombre fallará.
   * **`platform_loader_io.dart` puede cargar el binario incorrecto en desarrollo macOS:**
     * `platform_loader_io.dart` prueba rutas relativas al `CWD` (`rust/target/release/libminiaudio_player.dylib`, `.dart_tool/lib/`, `build/native_assets/macos/`) **antes** de llegar al fallback FRB (`miniaudio_player.framework/miniaudio_player` en `_io.dart:72-81`). Si existe una `.dylib` antigua en `rust/target/release/` al correr `flutter run -d macos` desde el repo, puede abrir esa en lugar del `.framework` firmado dentro de la `.app`.
   * **Falta de `Architecture.arm64e` en `_resolveRustTriple`:** si en el futuro `code_assets` o un target Apple solicita `arm64e`, actualmente lanza `Unsupported platform/architecture`.

---

### 2.3 Precompilados para `x86`, `Windows ARM64`, Formato de Descarga y Paralelismo de CI

#### Cobertura de arquitecturas objetivo

| Plataforma | Arquitecturas actuales en CI | Arquitecturas faltantes / rotas (ahora requeridas) | Rust triple | Notas críticas |
|---|---|---|---|---|
| **Android** | `arm64`, `armv7`, `x64` | **`x86` (`Architecture.ia32`)** faltante | `i686-linux-android` | Sin verificación `16 KB` (solo aplica a 64-bit). *Nota: `flutter_tools` `AndroidArch` en Flutter 3.47 emite `armeabi-v7a`, `arm64-v8a` y `x86_64`, pero `code_assets` / `hooks` y NDK sí definen `Abi.androidIA32` (`Architecture.ia32`).* |
| **Windows** | `x64`, `arm64` (roto en CI) | **`arm64` (`Architecture.arm64`)** sin env MSVC ARM64 + **`x86` (`Architecture.ia32`)** faltante | `aarch64-pc-windows-msvc`<br>`i686-pc-windows-msvc` | El job actual corre `aarch64-pc-windows-msvc` en `windows-latest` sin `ilammy/msvc-dev-cmd` (`amd64_arm64`) ni runner nativo ARM64; falta añadir `i686-pc-windows-msvc` (`x86`). |
| **Linux** | `x64`, `arm64` | **`x86` (`Architecture.ia32`)** faltante | `i686-unknown-linux-gnu` | `cargo-zigbuild` soporta `--target i686-unknown-linux-gnu.2.17`. Verificar compatibilidad de `-Wl,--gc-sections` / `--as-needed` de `rust/.cargo/config.toml`. |
| **Apple** | `macos (arm64, x64)`, `ios (arm64, arm64-sim, x64-sim)` | Completo | — | Revisar `MACOSX_DEPLOYMENT_TARGET` (`13.0` o `11.0`) e `IPHONEOS_DEPLOYMENT_TARGET` (`15.0` o `13.0`). |
| **Web** | `wasm32` (roto en CI) | `wasm32-unknown-unknown` (multi-thread) | `wasm32-unknown-unknown` | Requiere `nightly` + `rust-src` + `wasm-bindgen-cli 0.2.130` + `wasm-pack`. |

#### Análisis del formato de descarga en GitHub Releases: Sin comprimir vs `.gz` único vs `.tar.gz`

Cada plataforma nativa distribuye **exactamente 1 binario dinámico** (`libminiaudio_player.so`, `miniaudio_player.dll` o `libminiaudio_player.dylib`), por lo que el contenedor `.tar` actual en `.tar.gz` no aporta nada y añade un fallo de portabilidad (`Process.run('tar', ...)` en `hook/build.dart:283` o necesidad de `package:archive`).

**Tamaños reales medidos en este workspace (`rust/target/release/libminiaudio_player.so`):**
* Con `strip = "debuginfo"` (configuración actual en `rust/Cargo.toml:118`, `file` reporta `not stripped`): **`12,206,176` bytes (`~11.6 MiB` / `12.2 MB`)** sin comprimir → **`3,904,343` bytes (`~3.7 MiB` / `3.9 MB`)** con `gzip -9`.
* Con `strip --strip-unneeded` (equivalente a `strip = "symbols"` / `strip = true` en `rust/Cargo.toml`): **`8,721,592` bytes (`~8.3 MiB` / `8.7 MB`)** sin comprimir → **`3,476,513` bytes (`~3.3 MiB` / `3.5 MB`)** con `gzip -9`.

| Criterio | A) Descarga directa sin comprimir (`<pkg>-vX.Y.Z-<triple>.<ext>`) | B) Archivo `.gz` único sin `.tar` (`<pkg>-vX.Y.Z-<triple>.<ext>.gz`) | C) `.tar.gz` actual |
|---|---|---|---|
| **Dependencias / código en `hook/build.dart`** | **Cero extracción:** descargar -> SHA-256 -> validar cabecera ELF/PE/Mach-O -> listo. | **Solo stdlib (`dart:io` `gzip`):** `gzip.decoder` en ~4 líneas puras de Dart; **cero `tar`**, **cero paquetes externos**. | Requiere `tar` en `PATH` (frágil en Windows) o `package:archive`. |
| **Tamaño transferido por target** | ~`8.7 MB` (stripped) / ~`12.2 MB` (actual) (~2.5×–3.1× mayor). | ~`3.5 MB` (stripped) / ~`3.9 MB` (~60–68% menos tráfico). | ~`3.5–3.9 MB`. |
| **Impacto en Android multi-ABI (4 ABIs en APK release)** | ~`35–49 MB` descargados en primera compilación. | ~`14–16 MB` descargados en primera compilación. | ~`14–16 MB`. |
| **SHA-256 / caché** | El hash de `checksums.sha256` valida el binario ejecutable directo. | El hash valida el `.gz` antes de descomprimir y la caché guarda el binario validado por ELF/PE/Mach-O. | Igual que `.gz`, con extracción compleja. |
| **Proxies / Antivirus corporativos** | Algunas redes bloquean descarga HTTP directa de URLs terminadas en `.dll`. | Extensión `.gz` suele pasar limpio por proxies y antivirus HTTP. | Extensión `.tar.gz` suele pasar limpio. |

**Conclusión de diseño recomendada:**
1. **Eliminar `.tar.gz` definitivamente** y eliminar `Process.run('tar', ...)` de `hook/build.dart`.
2. Cambiar `strip = "debuginfo"` → `strip = "symbols"` en `rust/Cargo.toml` (`[profile.release]`) para reducir ~`3.5 MB` (~29%) por binario en todas las plataformas nativas (manteniendo `opt-level = "s"`, `lto = true` y `panic = "abort"`).
3. Elegir entre:
   * **Descarga directa sin comprimir** (p. ej. `miniaudio_player-v3.1.0-x86_64-pc-windows-msvc.dll`) si priorizas **simplicidad absoluta y cero decodificación** en `hook/build.dart` (asumiendo ~`8.7 MB` por binario y sin contenedor); **o**
   * **`.gz` único sin `.tar`** (`miniaudio_player-v3.1.0-<triple>.<ext>.gz`) usando `gzip.decoder` nativo de `dart:io` si priorizas ahorrar ~60% de ancho de banda y evitar filtros HTTP a `.dll` manteniendo cero dependencias externas.
   *(Nota: Web en Releases sigue publicando `miniaudio_player.js` + `miniaudio_player_bg.wasm` como artefactos de auditoría/respaldo o `.gz` individuales, aunque los consumidores Web de Flutter ya los recibirán dentro de `assets/web/` vía `pub.dev`.)*

#### Diseño del workflow paralelo en `.github/workflows/release-binaries.yml`

Todos los jobs corren en paralelo por OS y por arquitectura dentro de cada matriz (`fail-fast: false`), incorporando caché compartida (`Swatinem/rust-cache@v2`) y verificación de arquitectura de cada binario generado:

1. **`build-linux` (`ubuntu-22.04`):**
   * Matrix en paralelo: `x86_64-unknown-linux-gnu` (`zigbuild .2.17`), `aarch64-unknown-linux-gnu` (`zigbuild .2.17`), **`i686-unknown-linux-gnu`** (`zigbuild .2.17`).
   * *Validación crítica:* comprobar con `file` / `readelf -h` que `Machine` coincida (`X86-64`, `AArch64`, `Intel 80386`) y que las flags de `rust/.cargo/config.toml` (`-Wl,--gc-sections`, `--as-needed`) funcionen limpio en las 3 arquitecturas con `zigbuild` 0.13.0.
2. **`build-android` (`ubuntu-22.04`):**
   * Matrix en paralelo: `arm64-v8a` (`aarch64-linux-android`), `armeabi-v7a` (`armv7-linux-androideabi`), `x86_64` (`x86_64-linux-android`), **`x86` (`i686-linux-android`)**.
   * Usar `cargo install --locked cargo-ndk` y fijar NDK explícito / `--platform 24`.
   * Mantener `CARGO_ENCODED_RUSTFLAGS="-Clink-arg=-Wl,-z,max-page-size=16384"` y verificar alineamiento `0x4000` con `readelf -l` en los targets 64-bit (`arm64-v8a`, `x86_64`).
   * Validar arquitectura ELF con `readelf -h` (`AArch64`, `ARM`, `X86-64`, `Intel 80386`).
3. **`build-windows` (separación explícita de runners / toolchain MSVC):**
   * Matrix en paralelo usando `ilammy/msvc-dev-cmd@v1`:
     * `x86_64-pc-windows-msvc` → `runs-on: windows-latest`, `msvc_arch: x64`
     * `aarch64-pc-windows-msvc` → **`runs-on: windows-11-arm`** (runner ARM64 nativo, `msvc_arch: arm64`) **o** cross-compile en `windows-latest` con `msvc_arch: amd64_arm64` (preferible `windows-11-arm` si está disponible en el plan, con `amd64_arm64` como alternativa instalando el componente MSVC ARM64 si faltara).
     * **`i686-pc-windows-msvc`** → `runs-on: windows-latest`, `msvc_arch: x86`
   * Validar cabecera PE (`Machine` = `0x8664`, `0xAA64`, `0x014C`) antes de empaquetar/subir.
4. **`build-apple` (`macos-14` ARM64):**
   * Matrix en paralelo: `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`.
   * Verificar `lipo -info` de cada `.dylib` para garantizar que la arquitectura Mach-O coincide con el artefacto.
5. **`build-web` (`ubuntu-22.04`):**
   * Toolchain **`dtolnay/rust-toolchain@nightly`** con `components: rust-src` y `targets: wasm32-unknown-unknown`.
   * Instalar `wasm-bindgen-cli --version 0.2.130` (exactamente igual que `rust/Cargo.lock`) y `wasm-pack` / `flutter_rust_bridge_codegen` (con `--locked`).
   * Compilar con los `RUSTFLAGS` multi-thread (`+atomics,+bulk-memory,+mutable-globals`, `--shared-memory`, `--max-memory=1073741824`, `--import-memory`, exports TLS/heap, `-Z build-std=std,panic_abort`).
   * Subir `miniaudio_player.js` y `miniaudio_player_bg.wasm` al Release y verificar coincidencia contra `assets/web/`.
6. **Publicación de artefactos en Release (sin `.tar`):**
   * Publicar cada binario directamente como `miniaudio_player-${TAG}-${triple}.${ext}` (descarga directa sin comprimir) **o** comprimido individualmente con `gzip -9` (`miniaudio_player-${TAG}-${triple}.${ext}.gz`), generar `checksums.sha256` sobre esos archivos finales y adjuntar todo al Release.

---

### 2.4 Validación de Opción A (`native_toolchain_rust`) vs Opción B (Hook Propio)

Se descargó e inspeccionó el código fuente real de **`native_toolchain_rust 1.1.1`** y **`flutter_rust_bridge_hooks 2.13.0`** desde `pub.dev` para verificar exactamente qué flags expone, qué configura por defecto y qué limitaciones tiene.

#### A. Flags configurables y valores por defecto verificados en `native_toolchain_rust 1.1.1`

1. **Parámetros que expone `RustBuilder` (`lib/native_toolchain_rust.dart`) y `FlutterRustBridgeNativeAssetsBuilder`:**
   * **Estables:** `assetName`, `cratePath` (por defecto prueba `'rust'` o `'native'`), `buildMode` (`BuildMode.release` por defecto, o `BuildMode.debug`), `enableDefaultFeatures` (`true`), `features` (`<String>[]`), y `assetRouting` (`[ToAppBundle()]` en el wrapper FRB).
   * **Marcados `@experimental`** *(su API advierte: "It may change on any new release without notice!")*:
     * `extraCargoBuildArgs` (`List<String>`): argumentos anexados al final de `cargo build`.
     * `extraCargoEnvironmentVariables` (`Map<String, String>`): variables de entorno pasadas al proceso (`RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS`, `CARGO_TARGET_DIR`, `CC_*`, etc.).

2. **Flags, comandos y entorno que `native_toolchain_rust 1.1.1` ya configura por defecto (`build_runner.dart` + `build_environment.dart`):**
   * **Invocación Cargo:** ejecuta `rustup run <toolchainChannel> cargo build [--release] --manifest-path <Cargo.toml> --package <crateName> --target <targetTriple> --target-dir <outputDir>` (`<input.outputDirectory>/target`, salvo override de `CARGO_TARGET_DIR`).
   * **macOS host:** limpia `PATH` filtrando `.where((e) => !e.contains('Contents/Developer/'))` (seguro frente a carpetas personales como `~/Developer/`).
   * **Android (`AndroidBuildEnvironmentFactory`):**
     * Valida que `codeConfig.cCompiler != null` y que el NDK contenga `${ndkTriple}35-clang` / `35-clang++` (exige **NDK >= r27** incluso si `targetNdkApi` es 24).
     * Corrige los triples NDK (`armv7-linux-androideabi` → `armv7a-linux-androideabi` para clang y `arm-linux-androideabi` para sysroot).
     * Exporta `AR_<triple>`, `CC_<triple>` (`<ndkTriple><apiTarget>-clang`), `CXX_<triple>`, `RANLIB_<triple>` (`llvm-ranlib`), `CARGO_TARGET_<TRIPLE>_LINKER`, y `BINDGEN_EXTRA_CLANG_ARGS_<triple>` (`--sysroot=... -I...` con `/` en Windows).
     * Inyecta **`CARGO_TARGET_<TRIPLE>_RUSTFLAGS: '-C link-arg=-Wl,-z,max-page-size=16384'`** en `aarch64-linux-android` y `x86_64-linux-android` **solo bajo ciertas condiciones** (ver bloqueante #2 abajo).
   * **Incrementalidad (`.d` dep-info):** parsea el `.d` de Cargo soportando espacios escapados (`\ `) y excluye el propio archivo `.d` de `output.dependencies` (evitando bucles de rebuild en Flutter), añadiendo además `Cargo.toml`, `build.rs`, `rust-toolchain.toml` y `Cargo.lock`.
   * **Wrapper `flutter_rust_bridge_hooks` (`2.13.0`):** añade bloqueo exclusivo de archivo (`FileLock.exclusive`) por `outputDirectory` y en Windows acorta `out_dir_shared` a `%TEMP%\frb_native_assets_<hash>` para evitar `MAX_PATH`.

3. **Lo que `native_toolchain_rust 1.1.1` NO configura por defecto:**
   * **Linux y Windows:** `BuildEnvironmentFactory.createBuildEnvVars` solo maneja `Platform.isMacOS` (PATH) y `OS.android`. **No** propaga `codeConfig.cCompiler` (`CC_<triple>`, `AR_<triple>`, `CARGO_TARGET_<TRIPLE>_LINKER`) en Linux ni invoca `cCompiler.windows.developerCommandPrompt` (`vcvarsall.bat`) en Windows (necesario para `arm64`/`x86` cross-compile).
   * **macOS e iOS:** **no** lee `codeConfig.iOS.deploymentVersion` ni `codeConfig.macOS.deploymentVersion`, **no** exporta `IPHONEOS_DEPLOYMENT_TARGET` / `MACOSX_DEPLOYMENT_TARGET`, y **no** limpia `SDKROOT`/`PLATFORM_NAME`/`ARCHS` si el proceso viene de Xcode.
   * **Precompilados:** no tiene soporte alguno para descargar ni verificar binarios precompilados de GitHub Releases.

#### B. Incompatibilidades bloqueantes detectadas en Opción A para `miniaudio_player`

1. ❌ **No soporta `x86` (`Architecture.ia32`) en ninguna plataforma (`config_mapping.dart:7-39`):**
   Su mapeo `CodeConfigMapping.targetTriple` solo implementa `arm64`, `arm` (Android) y `x64`. Cualquier build para `i686-pc-windows-msvc`, `i686-unknown-linux-gnu` o `i686-linux-android` lanza inmediatamente `UnsupportedError('Unsupported target: ... on ia32')`. Al haberse decidido incluir **`x86` en Windows, Linux y Android**, `native_toolchain_rust 1.1.1` queda descartado sin parchearlo o hacer fork.
2. ❌ **Conflicto silencioso con `rust/.cargo/config.toml` que desactiva el alineamiento `16 KB` en Android:**
   En `build_environment.dart:86-88` y `133-147`, `_configuresRustflags` inspecciona cualquier `.cargo/config.toml` cercano y devuelve `true` si existe `rustflags` bajo `[build]` **o bajo cualquier clave de `[target.*]`**. Como `rust/.cargo/config.toml` ya define `[target.'cfg(target_os = "linux")'] rustflags = [...]`, `native_toolchain_rust` **dejaría de emitir `-Wl,-z,max-page-size=16384` en Android** sin mostrar advertencia (mismo problema si pasáramos cualquier `RUSTFLAGS` o `CARGO_ENCODED_RUSTFLAGS` extra).
3. ❌ **Exige obligatoriamente `rust/rust-toolchain.toml` con canal de versión exacta y todos los targets (`crate_info_validator.dart:52-84`):**
   Rechaza explícitamente `'stable'`, `'beta'` y `'nightly'`, obligando a fijar una versión exacta (p. ej. `channel = "1.90.0"`) y listar cada triple soportado en `toolchain.targets`. Actualmente `rust/` no usa `rust-toolchain.toml`. Imponerlo forzaría a todo usuario que caiga a compilación local a tener/descargar ese toolchain exacto (~1 GB) aunque ya tenga `rust` `stable` instalado, y obligaría a sobrescribirlo con `+nightly` en builds Web WASM.
4. ❌ **Sube el piso de Dart SDK y acopla flags críticos a API `@experimental`:** requiere `sdk: ^3.9.0` (actualmente `pubspec.yaml` usa `>=3.6.0`), exige NDK >= r27 hardcoded, no gestiona `cCompiler` en Linux/Windows ni `deploymentVersion` en Apple, y deja la descarga precompilada completamente fuera.

#### C. Comparativa actualizada: Opción A vs Opción B

| Criterio | Opción A (Híbrida: Prebuilts propios + `native_toolchain_rust 1.1.1` fallback) | Opción B (Hook propio limpio, modularizado, cero deps de build extra) |
|---|---|---|
| **Soporte `x86` (`Windows`, `Linux`, `Android`)** | ❌ **Bloqueado en `1.1.1`:** lanza `UnsupportedError` para `Architecture.ia32`. | ✅ **Soporte total** (`i686-pc-windows-msvc`, `i686-unknown-linux-gnu`, `i686-linux-android`). |
| **Android `16 KB` page size con `rust/.cargo/config.toml`** | ❌ **Silenciosamente desactivado** porque `.cargo/config.toml` define `rustflags` para Linux. | ✅ **Garantizado siempre** mediante `CARGO_ENCODED_RUSTFLAGS` por target Android 64-bit. |
| **Requisitos al usuario final en fallback local** | ❌ Exige `rust-toolchain.toml` con versión fija (rechaza `stable`) + descarga automática del toolchain exacto + NDK >= r27. | ✅ Usa el `cargo` / toolchain ya instalado por el usuario (auto-añadiendo solo el target con `rustup target add` si existe `rustup`). |
| **Apple (`macOS`/`iOS`) + Linux + Windows `cCompiler`** | ⚠️ Solo filtra `Contents/Developer/` en macOS; ignora `deploymentVersion`, `SDKROOT` y `cCompiler` en Linux/Windows. | ✅ Soporte completo para `deploymentVersion`, limpieza Xcode, `cCompiler` Linux y `developerCommandPrompt` Windows (`arm64`/`x86`). |
| **Descarga prebuilt sin `tar` + validación ELF/PE/Mach-O** | Requiere implementarse igual en el hook propio. | ✅ Integrado de forma limpia (descarga directa o `.gz` con `dart:io` `gzip`). |
| **Dependencias transitivas y SDK mínimo** | Añade `native_toolchain_rust` (`sdk: ^3.9.0`), `toml`, `logging`, (`flutter_rust_bridge_hooks`). | ✅ Solo `hooks`, `code_assets`, `crypto`, `path`. |

**Veredicto definitivo:** Se **descarta Opción A** (`native_toolchain_rust`) y se adopta **Opción B (hook propio limpio y modularizado)**, **portando únicamente** las mejores prácticas verificadas de `native_toolchain_rust` y `flutter_rust_bridge_hooks`:
1. Filtro quirúrgico de `PATH` en macOS (`!e.contains('Contents/Developer/')`) en lugar de `!p.split(e).contains('Developer')`.
2. Parseo robusto de dep-info `.d` (escapando `\ ` en rutas y **sin** registrar el `.d` mismo en `output.dependencies`).
3. `FileLock.exclusive` para serializar builds concurrentes del mismo `outputDirectoryShared` y directorio corto en `%TEMP%` en Windows para evitar `MAX_PATH`.
4. Validación explícita de `cargo`/`rustup`/`NDK` (`<triple><api>-clang`) con `BuildError` claros y rutas con `/` en `BINDGEN_EXTRA_CLANG_ARGS`.

---

### 2.5 Prevención de Mala Detección o Empaquetado Incorrecto de Arquitecturas

Cómo puede ocurrir hoy que un sistema Linux o Windows descargue/cargue un binario de `x86_64` siendo `ARM64` (o viceversa), y cómo blindarlo:

1. **Origen 1 — SDK Dart/Flutter corriendo bajo emulación (`Abi.current()`):**
   * Verificado en `flutter_tools/lib/src/base/os.dart` (`hostPlatform` usa `Abi.current()`), `linux_device.dart`, `windows_device.dart` y `targets.dart:390` (`FlutterTesterAssetTarget` usa `Architecture.current`).
   * Si en **Windows ARM64** el usuario instala el Flutter/Dart SDK `x64` (ejecutado vía emulación Prism/WOW64) o en **Linux ARM64** corre Dart `x64` en emulador/contenedor, `Abi.current()` reporta `x64`, por lo que `flutter run -d windows` / `flutter test` solicitará `x86_64` aunque el hardware sea ARM64. En cambio, al compilar explícitamente con `--target-platform windows-arm64` / `linux-arm64`, `codeConfig.targetArchitecture` sí llega como `Architecture.arm64`.
   * *Regla estricta en `hook/build.dart`:* **Jamás** usar `Abi.current()`, `Platform.version` ni `uname` del host para elegir el binario a descargar; usar **siempre** `input.config.code.targetOS` + `input.config.code.targetArchitecture` (que además determina la arquitectura del proceso que finalmente cargará la FFI).

2. **Origen 2 — Error de cross-compile en Priority 5 (local fallback):**
   * Hoy `hook/build.dart` ignora `codeConfig.cCompiler` en Linux y Windows:
     * En **Linux x64** compilando hacia `Architecture.arm64` (`flutter build linux --target-platform linux-arm64`), `cargo build --release --target aarch64-unknown-linux-gnu` falla o usa el linker equivocado si no se configura `CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER` / `CC_aarch64_unknown_linux_gnu` desde `codeConfig.cCompiler` o un cross-linker detectado (`aarch64-linux-gnu-gcc` / `zig`).
     * En **Windows x64** compilando hacia `Architecture.arm64`, debe invocarse a través del `cCompiler.windows.developerCommandPrompt` (`vcvarsall.bat amd64_arm64` o `vcvars`) provisto por `code_assets`.

3. **Origen 3 — Validación binaria de cabeceras (ELF / PE / Mach-O) en `hook/build.dart` y CI:**
   * `code_assets` (`2.2.0`) incluye validadores internos (`ElfValidator`, `MachOValidator`, `PortableExecutableValidator`), pero conviene validar **en CI antes de publicar** y **en `hook/build.dart` justo antes de copiar a `finalOutFile`** (tanto en Priority 4 de descarga directa/`.gz` como en Priority 1 `MINIAUDIO_PLAYER_LIB_PATH`):
     * **ELF (Linux / Android):** bytes `18..19` (`e_machine` little-endian): `0x003E` (`x86_64`), `0x00B7` (`aarch64`), `0x0028` (`arm`/`armv7`), `0x0003` (`x86`/`i686`).
     * **PE (Windows):** offset `PE\0\0` + `Machine`: `0x8664` (`x64`), `0xAA64` (`arm64`), `0x014C` (`x86`/`ia32`).
     * **Mach-O (macOS / iOS):** magic `0xFEEDFACF` / fat `0xCAFEBABE` + `cputype`: `0x01000007` (`x86_64`), `0x0100000C` (`arm64`).
   * Si el binario descargado o provisto no coincide con `(targetOS, targetArchitecture)`, **borrar caché corrupta y fallar explícitamente con `BuildError`** en vez de empaquetar un binario incompatible.

4. **Origen 4 — `platform_loader_io.dart` cargando artefactos residuales de otra arquitectura:**
   * `platform_loader_io.dart` busca `rust/target/release/<lib>`, `.dart_tool/lib/<lib>` y `build/native_assets/<os>/<lib>` por orden de existencia. En Windows o entornos multi-arquitectura, si queda una `.dll`/`.so` residual de otra arquitectura (ej. tras correr `flutter test` y luego compilar otro target), `ExternalLibrary.open` puede fallar o cargar la equivocada bajo emulación. Debe priorizar el mecanismo nativo estándar o aislar/validar rutas correctamente.

---

## 3. Plan de Acción Paso a Paso (Checklist de Implementación)

> Marca `[x]` conforme se complete y valide cada tarea en futuros cambios.

### Fase 1: Alinear Versiones, Limpiar Web Assets y Evitar Copia en No-Web
- [x] **1.1. Alinear versiones en todo el repositorio:**
  - Unificado a `4.0.0` en [`pubspec.yaml`](../pubspec.yaml), [`rust/Cargo.toml`](../rust/Cargo.toml), [`rust/Cargo.lock`](../rust/Cargo.lock), `_defaultVersion` en [`hook/build.dart`](../hook/build.dart), alineado con [`CHANGELOG.md`](../CHANGELOG.md) y [`README.md`](../README.md).
- [x] **1.2. Desacoplar compilación WASM (`web/pkg/`) del asset empaquetado (`assets/web/`):**
  - Creado [`tool/build_web_wasm.dart`](../tool/build_web_wasm.dart) (compila en `build/web_wasm/pkg/` preservando `target_features` con `CARGO_PROFILE_RELEASE_STRIP=none` para `wasm-bindgen` + `wasm-opt`, y publica únicamente `miniaudio_player.js` y `miniaudio_player_bg.wasm` hacia `assets/web/`).
  - Excluidos `/web/pkg/` y `/example/web/pkg/` en [`.gitignore`](../.gitignore), [`.pubignore`](../.pubignore) y [`example/.gitignore`](../example/.gitignore), y actualizado [`README.md`](../README.md) y [`.vscode/tasks.json`](../.vscode/tasks.json).
- [x] **1.3. Configurar assets exclusivos de Web en `pubspec.yaml`:**
  - Declarado `flutter: ">=3.41.0"` en [`pubspec.yaml`](../pubspec.yaml) y configurado `platforms: [web]` para `assets/web/miniaudio_player.js` y `assets/web/miniaudio_player_bg.wasm`.
- [x] **1.4. Actualizar loader Web, fallback Rust Web y remover provisión intrusiva en `hook/build.dart`:**
  - Actualizado `_candidateWebPrefixes` en [`lib/src/loader/platform_loader_web.dart`](../lib/src/loader/platform_loader_web.dart) (`assets/packages/miniaudio_player/assets/web/`, `packages/miniaudio_player/assets/web/`, `assets/web/`, `pkg/`) y el fallback `resolve_script_src()` en [`rust/src/sync/mod.rs`](../rust/src/sync/mod.rs).
  - Eliminado `_provisionWebAssetsIfNeeded` de [`hook/build.dart`](../hook/build.dart) y removidos `web/pkg/` y `example/web/pkg/` de git.
- [x] **1.5. Evaluación de `wasmBindgenName`:**
  - Evaluado y documentado: `wasm-pack build` no expone `--no-modules-global`, por lo que se mantiene `wasm_bindgen` alineado con `flutter_rust_bridge.yaml` y `frb_generated.dart`.
- [x] **1.6. Validación de Fase 1:**
  - [x] `flutter pub publish --dry-run`: incluye `assets/web/miniaudio_player.{js,wasm}` (3 MB total), cero `example/web/pkg/` ni advertencias de `.gitignore`.
  - [x] `flutter build linux --debug` y `flutter build apk --debug` (en `example/`): **cero** archivos `.wasm` o `.js` dentro de `flutter_assets/` ni `app-debug.apk`.
  - [x] `flutter build web --release` y `--profile`: genera `example/build/web/assets/packages/miniaudio_player/assets/web/miniaudio_player.{js,wasm}` sin `build/web/pkg`.
  - [x] Prueba de reproducción y análisis en navegador sobre `example/build/web` (`profile` y `release`) post-refactor: verificada reproducción sin errores ni 404s (incluyendo pistas con `#`, espacios y paréntesis en `asset://`).

---

### Fase 2: Robustecer `hook/build.dart` (Opción B) y Resolución Cross-Platform
- [x] **2.1. Ampliar mapeo de arquitecturas en `resolveRustTriple` (obligatorio `x86` / `ia32` en Android, Windows y Linux):**
  - Implementado en [`hook/src/target_triple.dart`](../hook/src/target_triple.dart) con las 15 combinaciones (Android `arm64`/`arm`/`x64`/`ia32`, Windows `x64`/`arm64`/`ia32`, Linux `x64`/`arm64`/`ia32`, macOS `arm64`/`x64`/`arm64e`, iOS `arm64`/`arm64e`/`arm64-sim`/`x64-sim`).
- [x] **2.2. Corregir escapes de rutas, env vars de compilación y fallos silenciosos:**
  - Implementado en [`hook/src/cargo_env.dart`](../hook/src/cargo_env.dart): `CARGO_ENCODED_RUSTFLAGS` (`\u001f`), `CC_SHELL_ESCAPED_FLAGS='1'`, verificación de `exitCode` en `rustup target add`, error explícito si `cCompiler == null` en Android, además del cast de punteros AAudio para Clang/NDK r28 en [`rust/c_src/miniaudio_device_bridge.c`](../rust/c_src/miniaudio_device_bridge.c).
- [x] **2.3. Limpiar soporte macOS / iOS (`hook/build.dart`, `cargo_env.dart` y `platform_loader_io.dart`):**
  - Implementado [`resolveAppleDeploymentTarget`](../hook/src/target_triple.dart) leyendo JSON `deployment_version` / `target_version` compatible con `code_assets` `1.x`–`2.2+`, filtro `!e.contains('Contents/Developer/')`, limpieza Xcode y propagación de `cCompiler` Apple.
  - Actualizado [`lib/src/loader/platform_loader_io.dart`](../lib/src/loader/platform_loader_io.dart) para priorizar `Frameworks/miniaudio_player.framework/miniaudio_player` en bundles AOT macOS/iOS y no sondear `rust/target/` en apps compiladas.
- [x] **2.4. Propagar `codeConfig.cCompiler` en Linux y Windows:**
  - Implementado en [`hook/src/cargo_env.dart`](../hook/src/cargo_env.dart): driver C exacto en Linux, fallbacks `arm64`/`ia32` y ejecución de `developerCommandPrompt` (`vcvarsall.bat`) en Windows.
- [x] **2.5. Reducir tamaño binario, portar mejoras de `ntr`/`frb_hooks` y reemplazar `.tar.gz`:**
  - Cambiado `strip = "debuginfo"` → `strip = "symbols"` en [`rust/Cargo.toml`](../rust/Cargo.toml) (`7.8 MB` observado en Linux `.so`).
  - Hash de crate ampliado (`rustTriple`, `cCompiler`, `ndkApi`, Apple SDK/versión), [`hook/src/depfile_parser.dart`](../hook/src/depfile_parser.dart) con espacios `\ ` y exclusión de `.d`, `FileLock.exclusive`, [`hook/src/binary_validator.dart`](../hook/src/binary_validator.dart) (ELF/PE/Mach-O), y [`hook/src/gzip_extractor.dart`](../hook/src/gzip_extractor.dart) usando `gzip.decoder` nativo de `dart:io` sin `tar`.
- [x] **2.6. Manejo de fallback y errores en Priority 4:**
  - `BuildError` (SHA-256 / header inválido) aborta sin fallback; `InfraError` / HTTP 404 / entrada faltante cae a Priority 5; caché `.download-complete` invalidada si cambia `download_base_url`; soporte `CARGO_TARGET_DIR` y `%TEMP%\map_cargo_<hash>` en Windows.

---

### Fase 3: Workflow CI Paralelo Completo (`.github/workflows/release-binaries.yml`)
> Nota: las definiciones YAML están implementadas en [`.github/workflows/release-binaries.yml`](../.github/workflows/release-binaries.yml); su ejecución real en runners de GitHub queda pendiente al publicar el tag `v4.0.0`.
- [x] **3.1. Definido `build-android` en paralelo (4 ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`)** con `--locked`, `readelf -h` y verificación `0x4000` en 64-bit.
- [x] **3.2. Definido `build-windows` en paralelo (`x64`, `windows-11-arm`, `x86`)** con `ilammy/msvc-dev-cmd@v1` y validación PE `Machine` (`0x8664`, `0xAA64`, `0x014C`).
- [x] **3.3. Definido `build-linux` en paralelo (`x64`, `arm64`, `x86`)** con `cargo-zigbuild` (`.2.17`) y validación ELF `readelf -h`.
- [x] **3.4. Definido `build-apple` en paralelo (`darwin` + `ios` + `ios-sim`)** con validación `lipo -info` y `otool -D`.
- [x] **3.5. Definido `build-web` para WASM multi-thread (`nightly` + `wasm-bindgen-cli 0.2.130`)** con `CARGO_PROFILE_RELEASE_STRIP=none` y artefactos `miniaudio_player.{js,wasm}`.
- [x] **3.6. Publicación `.gz` sin `.tar`, `Swatinem/rust-cache@v2` y verificación de completitud en `publish-release`** + guard en [`tool/update_release_hashes.dart`](../tool/update_release_hashes.dart).

---

### Fase 4: Verificación End-to-End Post-Implementación
- [x] **4.1. Validación local de empaquetado (`pub`):**
  - `flutter pub publish --dry-run` sin advertencias de `.gitignore` ni duplicados en `example/web/pkg/` (solo aviso esperado por archivos locales sin commitear).
- [ ] **4.2. Validación de hooks y carga por plataforma:**
  - [x] Pruebas unitarias y E2E en [`test/loader_and_hook_test.dart`](../test/loader_and_hook_test.dart): mapeo de las 15 triples, validadores ELF/PE/Mach-O, descompresión `.gz` con `dart:io`, depfiles con `\ `, higiene `assets/web/` y prueba HTTP mock contra `hook/build.dart` para los **15 targets** + rechazo de SHA-256 inválido y ELF cross-arch incorrecto.
  - [x] Build nativo local Priority 5 verificado en Linux x64 y Android NDK r28 (`arm64-v8a` con segmentos `LOAD 0x4000`, `armeabi-v7a`, `x86_64`).
  - [ ] Ejecución de `MINIAUDIO_PLAYER_BUILD_FROM_SOURCE=1` nativa en runners macOS/iOS y Windows pendiente de CI/hosts respectivos.
- [ ] **4.3. Validación de tamaño y runtime:**
  - [x] Confirmada ausencia de `.wasm`/`.js` en `example/build/linux` y `app-debug.apk`.
  - [x] Reproducción Web interactiva con `assets/web/` validada en navegador (`profile` y `release`).
  - [ ] Build nativo Windows pendiente en host/runner respectivo.
