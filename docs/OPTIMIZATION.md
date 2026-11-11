# Optimización de Rendimiento y Tamaño Binario (`docs/OPTIMIZATION.md`)

Este documento detalla el análisis exhaustivo, la metodología aplicada, las fases de optimización y los resultados empíricos obtenidos en la reducción del tamaño del binario nativo y empaquetado del plugin `miniaudio_player`.

---

## 1. Resumen Ejecutivo y Resultados

| Métrica | Estado Inicial (Baseline) | Estado Final Optimizado | Reducción Neta | % Mejora |
| :--- | :---: | :---: | :---: | :---: |
| **Tamaño Archivo (`libminiaudio_player.so`)** | **9,899,256 B (9.44 MiB / 9.90 MB)** | **6,930,376 B (6.61 MiB / 6.93 MB)** | **-2,968,880 B (-2.83 MiB)** | **-30.0%** |
| **Sección de Código (`.text`)** | 7,295,152 B (6.96 MiB) | 4,868,688 B (4.64 MiB) | -2,426,464 B (-2.31 MiB) | -33.3% |
| **Tablas Excepciones (`.gcc_except_table`)**| 272,152 B (265.8 KiB) | 13,276 B (12.9 KiB) | -258,876 B (-252.8 KiB) | -95.1% |
| **Marcos de Desenrollo (`.eh_frame`)** | 649,692 B (634.5 KiB) | 331,472 B (323.7 KiB) | -318,220 B (-310.8 KiB) | -49.0% |
| **Cabecera Unwind (`.eh_frame_hdr`)** | 95,436 B (93.2 KiB) | 49,140 B (48.0 KiB) | -46,296 B (-45.2 KiB) | -48.5% |
| **Sección Datos Read-Only (`.rodata`)** | 1,022,372 B (998.4 KiB) | 941,156 B (919.1 KiB) | -81,216 B (-79.3 KiB) | -7.9% |
| **Tests Flutter Aprobados** | **269 / 269 (100%)** | **269 / 269 (100%)** | 0 regresiones | **100% OK** |
| **Tests Nativos Rust Aprobados** | **48 / 48 (100%)** | **48 / 48 (100%)** | 0 regresiones | **100% OK** |

---

## 2. Metodología y Diagnóstico de Partida

### 2.1 Herramientas Empleadas
- `size` y `readelf -S`: Análisis de secciones ELF (`.text`, `.rodata`, `.data`, `.bss`, `.eh_frame`, `.gcc_except_table`).
- `nm -S --size-sort -C -r`: Identificación de los símbolos y funciones más voluminosos en el espacio de memoria.
- `cargo bloat --release --crates`: Desglose del peso de cada crate y módulo dependiente en tiempo de enlace.
- `cargo tree`: Rastreo del grafo de dependencias para aislar features residuales o duplicadas.

### 2.2 Diagnóstico Inicial (Línea Base)
Al analizar el binario de release generado originalmente (`opt-level = 3`, `lto = "thin"`, `codegen-units = 4`, `panic = "unwind"`, `strip = true`), se evidenciaron los siguientes cuellos de botella de tamaño:
1. **Sobrecarga de Tablas de Desenrollo DWARF (`.eh_frame`, `.gcc_except_table`, `.eh_frame_hdr`)**:
   - `panic = "unwind"` obligaba al compilador a inyectar información de desenrollo y *landing pads* para cada función de Rust y wrappers FFI, a pesar de que a través de la frontera C/Dart no se puede propagar un desenrollo de pila no capturado.
   - Esto representaba más de **1.01 MB** de metadatos estáticos en el binario final.
2. **Particionado de Unidades de Generación de Código (`codegen-units = 4`)**:
   - Al paralelizar la generación de código en 4 unidades aisladas, LLVM no podía aplicar optimizaciones globales completas (Inlining global, eliminación de código muerto interprocedural y unificación de constantes).
3. **ThinLTO vs Fat LTO**:
   - `lto = "thin"` opera basándose en resúmenes de módulos, omitiendo una cantidad significativa de oportunidades de *Whole Program Optimization* (WPO) al cruzar crates de Rust y código C (`miniaudio_device_bridge.c`).
4. **Dependencias HTTP y Crates Auxiliares**:
   - El crate `ureq` importaba características predeterminadas innecesarias como `gzip` (que forzaba la inclusión de código para descompresión HTTP en streams de audio que ya viajan comprimidos como MP3/AAC/FLAC).
5. **Configuración de Cargo no Detectada en Build de Dart**:
   - El script `hook/build.dart` ejecutaba Cargo desde la raíz del paquete de Flutter (`input.packageRoot`), por lo que Cargo no descubría `rust/.cargo/config.toml`, ignorando banderas de optimización del linker como `--gc-sections`, `--as-needed`, `-O1` y `force-unwind-tables=no`.

---

## 3. Fases de Optimización Implementadas

### Fase 1: Perfil de Release en `rust/Cargo.toml`
Se ajustó el bloque `[profile.release]` con directivas diseñadas para minimizar la huella de memoria manteniendo el rendimiento crítico de decodificación y DSP:

```toml
[profile.release]
opt-level = "s"      # Optimiza agresivamente tamaño preservando vectorizaciones SIMD y velocidad en tiempo real
lto = true           # Fat LTO: Enlace global inter-crate y optimización de programa completo
codegen-units = 1    # 1 sola unidad de compilación para maximizar deduplicación y dead-code elimination
strip = true         # Elimina todos los símbolos de depuración y tablas no dinámicas
panic = "abort"      # Elimina landing pads de excepciones y minimiza tablas .eh_frame
```

#### Comparativa de `opt-level`:
- **`opt-level = 3`**: 9.34 MB. Desenrolla bucles extensivamente y duplica código con inlining agresivo.
- **`opt-level = "z"`**: 8.16 MB. Prioriza tamaño pero genera estructuras de salto indirecto en `.data` que contrarrestan la ganancia en `.text`.
- **`opt-level = "s"`**: **8.14 MB**. Logra el mejor balance físico: reduce sustancialmente el tamaño de `.text` sin el sobrepeso de datos indirectos y manteniendo vectorización SIMD activa para DSP y visualizador espectral.

#### Efecto de `panic = "abort"`:
- Reduce `.gcc_except_table` de 272 KB a solo **13 KB** (-95.1%).
- Reduce `.text` en **2.42 MB** al suprimir el código de aterrizaje de excepciones.

---

### Fase 2: Depuración y Poda de Crates y Features

1. **`ureq`**:
   - Configuración anterior: `ureq = { version = "2.10", features = ["tls"] }` (incluía `default-features = true`, trayendo el módulo de descompresión `gzip`).
   - Configuración optimizada: `ureq = { version = "2.10", default-features = false, features = ["tls"] }`.
   - Se eliminó el soporte de compresión HTTP de capa de transporte que es redundante para audio ya empaquetado.
2. **`lofty`**:
   - Se evaluó la desactivación de `id3v2_compression_support`. Sin embargo, dado que `lofty 0.25.5` presenta un bug interno en su manejo de errores condicionales cuando se desactiva y además se requiere soporte para decodificar frames ID3v2 zlib comprimidos en archivos MP3 del mundo real, se mantuvo la compatibilidad total.
3. **`symphonia`**:
   - Se validó el conjunto completo de códecs y contenedores. Al aplicar Fat LTO (`lto = true`) con `codegen-units = 1`, el compilador descarta automáticamente cualquier ruta interna o códec no referenciado sin necesidad de fragmentar los flags de soporte (`flac`, `mp3`, `mp2`, `aac`, `alac`, `vorbis`, `opus`, `pcm`, `adpcm`, `wav`, `ogg`, `isomp4`, `mkv`, `caf`, `aiff`).

---

### Fase 3: Integración del Hook de Compilación (`hook/build.dart`) y Banderas del Enlazador

1. **Unificación del Directorio de Trabajo de Cargo**:
   - En `hook/build.dart`, se actualizó la ejecución del proceso nativo para que `workingDirectory: rustDir.path`.
   - Con esto, cualquier compilación gatillada por Flutter o Dart ejecuta Cargo directamente en el entorno de `rust/`, garantizando la lectura automática de `rust/.cargo/config.toml`.
2. **Espejo de Configuración en Raíz (`.cargo/config.toml`)**:
   - Se creó un archivo espejo `.cargo/config.toml` en la raíz del proyecto para asegurar que invocaciones directas como `cargo build --manifest-path rust/Cargo.toml` desde la consola adopten exactamente las mismas banderas del linker.
3. **Banderas de Enlace (`rustflags`)**:
   ```toml
   [target.'cfg(target_os = "linux")']
   rustflags = [
       "-C", "link-arg=-Wl,--gc-sections",      # Recolección de basura de secciones ELF no utilizadas
       "-C", "link-arg=-Wl,--as-needed",        # No enlazar librerías dinámicas no referenciadas
       "-C", "link-arg=-Wl,-O1",                # Optimización del enlazador
       "-C", "force-unwind-tables=no",          # Supresión de tablas asíncronas DWARF no requeridas
   ]
   ```

---

## 4. Auditoría de Integridad y Verificación

Tras implementar la totalidad de optimizaciones, se ejecutaron las suites de pruebas completas del proyecto:

1. **Tests Nativos de Rust**:
   ```bash
   cargo test --manifest-path rust/Cargo.toml
   ```
   - **Resultado**: 48/48 tests pasados (0 fallos).
   - Fixtures de benchmark, buffers lock-free, HLS/AES-128, decodificadores/formatos, DSP/espacial y sincronización concurrentes verificados con éxito.

2. **Tests de Flutter y Dart**:
   ```bash
   flutter test
   ```
   - **Resultado**: 269/269 tests pasados (0 fallos).
   - Pruebas exhaustivas de metadatos completos, AudioInfo, ReplayGain, Waveform, matrices de reproducción local, streaming en vivo y controles caóticos funcionando al 100%.

3. **Análisis Estático de Código**:
   ```bash
   dart analyze hook/build.dart lib test
   cargo check --manifest-path rust/Cargo.toml
   ```
   - **Resultado**: Cero advertencias y cero errores en Dart y Rust.

---

## 5. Conclusión

La suite de optimizaciones aplicadas redujo con éxito el binario dinámico de **9.89 MB** a **6.93 MB** (un ahorro neto del **30.0%**), eliminando más de 2.96 megabytes de sobrecarga generada por código muerto, tablas redundantes de desenrollado y fragmentación de unidades de compilación, sin perder compatibilidad con ninguno de los códecs de audio ni degradar el rendimiento en tiempo real del reproductor.
