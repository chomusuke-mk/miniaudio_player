import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

/// Maps a Dart Native Assets `(os, arch, iosSdk)` tuple to its Rust target triple.
String resolveRustTriple(OS os, Architecture arch, IOSSdk? iosSdk) {
  switch (os) {
    case OS.android:
      if (arch == Architecture.arm64) return 'aarch64-linux-android';
      if (arch == Architecture.arm) return 'armv7-linux-androideabi';
      if (arch == Architecture.x64) return 'x86_64-linux-android';
      if (arch == Architecture.ia32) return 'i686-linux-android';
      break;
    case OS.iOS:
      if (arch == Architecture.arm64 || arch.name == 'arm64e') {
        return iosSdk == IOSSdk.iPhoneSimulator
            ? 'aarch64-apple-ios-sim'
            : 'aarch64-apple-ios';
      }
      if (arch == Architecture.x64) return 'x86_64-apple-ios';
      break;
    case OS.macOS:
      if (arch == Architecture.arm64 || arch.name == 'arm64e') {
        return 'aarch64-apple-darwin';
      }
      if (arch == Architecture.x64) return 'x86_64-apple-darwin';
      break;
    case OS.linux:
      if (arch == Architecture.x64) return 'x86_64-unknown-linux-gnu';
      if (arch == Architecture.arm64) return 'aarch64-unknown-linux-gnu';
      if (arch == Architecture.ia32) return 'i686-unknown-linux-gnu';
      break;
    case OS.windows:
      if (arch == Architecture.x64) return 'x86_64-pc-windows-msvc';
      if (arch == Architecture.arm64) return 'aarch64-pc-windows-msvc';
      if (arch == Architecture.ia32) return 'i686-pc-windows-msvc';
      break;
  }
  throw BuildError(message: 'Unsupported platform/architecture: $os / $arch');
}

/// Returns the `.gz` release asset filename for [packageName] v[version] on [rustTriple].
String prebuiltArchiveName({
  required String packageName,
  required String version,
  required String rustTriple,
  required String libFileName,
}) {
  final ext = p.extension(libFileName);
  return '$packageName-v$version-$rustTriple$ext.gz';
}

/// Resolves the Apple deployment target (`major.minor` or `major.minor.patch`)
/// from raw hook [inputJson] safely across `code_assets` 1.x, 2.0/2.1
/// (`target_version`) and 2.2+ (`deployment_version`) without deprecated APIs.
String resolveAppleDeploymentTarget(
  Map<String, Object?> inputJson,
  OS targetOS,
) {
  final sectionKey = targetOS == OS.iOS ? 'iOS' : 'macOS';
  final config = inputJson['config'];
  final code = config is Map ? config['code'] : null;
  final osSection = code is Map ? code[sectionKey] : null;

  if (osSection is Map) {
    final depVer = osSection['deployment_version'];
    if (depVer is Map) {
      final major = depVer['major'];
      final minor = depVer['minor'];
      final patch = depVer['patch'];
      if (major is int && minor is int) {
        return formatAppleDeploymentTarget(
          major: major,
          minor: minor,
          patch: patch is int ? patch : 0,
        );
      }
    }
    final legacyMajor = osSection['target_version'];
    if (legacyMajor is int) {
      return formatAppleDeploymentTarget(major: legacyMajor);
    }
  }
  return targetOS == OS.iOS ? '12.0' : '11.0';
}

/// Formats an Apple deployment version for `IPHONEOS_DEPLOYMENT_TARGET` /
/// `MACOSX_DEPLOYMENT_TARGET`.
String formatAppleDeploymentTarget({
  required int major,
  int minor = 0,
  int patch = 0,
}) {
  if (patch > 0) {
    return '$major.$minor.$patch';
  }
  return '$major.$minor';
}
