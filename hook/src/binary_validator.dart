import 'dart:io';
import 'dart:typed_data';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const int _maxHeaderReadBytes = 8192;

/// Validates that [file] has an ELF, PE, or Mach-O binary header matching
/// ([targetOS], [targetArch]), throwing a [BuildError] on mismatch.
void validateBinaryArchitectureOrThrow({
  required File file,
  required OS targetOS,
  required Architecture targetArch,
  required String sourceDescription,
}) {
  if (!file.existsSync()) {
    throw BuildError(
      message: 'Native binary ($sourceDescription) does not exist at ${file.path}.',
    );
  }
  final length = file.lengthSync();
  final toRead = length < _maxHeaderReadBytes ? length : _maxHeaderReadBytes;
  final raf = file.openSync(mode: FileMode.read);
  final Uint8List bytes;
  try {
    bytes = raf.readSync(toRead);
  } finally {
    raf.closeSync();
  }

  final error = validateBinaryHeaderBytes(bytes, targetOS, targetArch);
  if (error != null) {
    throw BuildError(
      message:
          'Architecture mismatch in $sourceDescription (${file.path}): $error',
    );
  }
}

/// Validates raw binary header [bytes] for ([targetOS], [targetArch]).
///
/// Returns `null` when the header matches, or a human-readable error message.
String? validateBinaryHeaderBytes(
  Uint8List bytes,
  OS targetOS,
  Architecture targetArch,
) {
  if (targetOS == OS.linux || targetOS == OS.android) {
    return _validateElfHeader(bytes, targetArch);
  }
  if (targetOS == OS.windows) {
    return _validatePeHeader(bytes, targetArch);
  }
  if (targetOS == OS.macOS || targetOS == OS.iOS) {
    return _validateMachOHeader(bytes, targetArch);
  }
  return 'Unsupported OS for header validation: $targetOS';
}

String? _validateElfHeader(Uint8List bytes, Architecture targetArch) {
  if (bytes.length < 20) {
    return 'File too small (${bytes.length} B) to be a valid ELF binary.';
  }
  if (bytes[0] != 0x7f ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4c ||
      bytes[3] != 0x46) {
    return 'Invalid ELF magic bytes.';
  }

  final eiClass = bytes[4];
  final eiData = bytes[5];
  if (eiData != 1 && eiData != 2) {
    return 'Unsupported ELF endianness encoding ($eiData).';
  }
  final endian = eiData == 1 ? Endian.little : Endian.big;
  final bd = ByteData.sublistView(bytes);
  final eMachine = bd.getUint16(18, endian);

  final (expectedClass, expectedMachine, label) = switch (targetArch) {
    Architecture.x64 => (2, 0x003e, 'x86_64 (EM_X86_64)'),
    Architecture.arm64 => (2, 0x00b7, 'arm64 (EM_AARCH64)'),
    Architecture.arm => (1, 0x0028, 'armv7 (EM_ARM)'),
    Architecture.ia32 => (1, 0x0003, 'x86 (EM_386)'),
    _ => (null, null, targetArch.toString()),
  };

  if (expectedClass == null || expectedMachine == null) {
    return 'Unsupported ELF target architecture: $targetArch';
  }
  if (eiClass != expectedClass || eMachine != expectedMachine) {
    return 'Expected ELF $label [class=$expectedClass, machine=0x${expectedMachine.toRadixString(16)}], '
        'found [class=$eiClass, machine=0x${eMachine.toRadixString(16)}].';
  }
  return null;
}

String? _validatePeHeader(Uint8List bytes, Architecture targetArch) {
  if (bytes.length < 64) {
    return 'File too small (${bytes.length} B) to be a valid PE DLL.';
  }
  if (bytes[0] != 0x4d || bytes[1] != 0x5a) {
    return 'Invalid DOS MZ header in PE binary.';
  }
  final bd = ByteData.sublistView(bytes);
  final peOffset = bd.getUint32(60, Endian.little);
  if (peOffset + 6 > bytes.length) {
    return 'PE header offset ($peOffset) out of range (${bytes.length} B).';
  }
  if (bytes[peOffset] != 0x50 ||
      bytes[peOffset + 1] != 0x45 ||
      bytes[peOffset + 2] != 0x00 ||
      bytes[peOffset + 3] != 0x00) {
    return 'Invalid PE\\0\\0 signature at offset $peOffset.';
  }

  final machine = bd.getUint16(peOffset + 4, Endian.little);
  final (expectedMachine, label) = switch (targetArch) {
    Architecture.x64 => (0x8664, 'x64 (0x8664)'),
    Architecture.arm64 => (0xaa64, 'arm64 (0xAA64)'),
    Architecture.ia32 => (0x014c, 'x86 (0x014C)'),
    _ => (null, targetArch.toString()),
  };
  if (expectedMachine == null) {
    return 'Unsupported PE target architecture: $targetArch';
  }
  if (machine != expectedMachine) {
    return 'Expected PE $label, found machine=0x${machine.toRadixString(16)}.';
  }
  return null;
}

String? _validateMachOHeader(Uint8List bytes, Architecture targetArch) {
  if (bytes.length < 16) {
    return 'File too small (${bytes.length} B) to be a valid Mach-O binary.';
  }
  final int? expectedCpuType;
  if (targetArch == Architecture.x64) {
    expectedCpuType = 0x01000007; // CPU_TYPE_X86_64
  } else if (targetArch == Architecture.arm64 || targetArch.name == 'arm64e') {
    expectedCpuType = 0x0100000c; // CPU_TYPE_ARM64
  } else {
    expectedCpuType = null;
  }
  if (expectedCpuType == null) {
    return 'Unsupported Mach-O target architecture: $targetArch';
  }

  final bd = ByteData.sublistView(bytes);
  final magicBe = bd.getUint32(0, Endian.big);
  final magicLe = bd.getUint32(0, Endian.little);

  // Thin Mach-O (64-bit or 32-bit, little or big endian)
  if (magicLe == 0xfeedfacf || magicLe == 0xfeedface) {
    final cpuType = bd.getUint32(4, Endian.little);
    if (cpuType != expectedCpuType) {
      return 'Expected Mach-O cputype=0x${expectedCpuType.toRadixString(16)}, '
          'found cputype=0x${cpuType.toRadixString(16)}.';
    }
    return null;
  }
  if (magicBe == 0xfeedfacf || magicBe == 0xfeedface) {
    final cpuType = bd.getUint32(4, Endian.big);
    if (cpuType != expectedCpuType) {
      return 'Expected Mach-O cputype=0x${expectedCpuType.toRadixString(16)}, '
          'found cputype=0x${cpuType.toRadixString(16)}.';
    }
    return null;
  }

  // Fat / Universal Mach-O binary (always big-endian header)
  if (magicBe == 0xcafebabe || magicBe == 0xcafebabf) {
    final nFatArch = bd.getUint32(4, Endian.big);
    if (nFatArch == 0 || nFatArch > 16) {
      return 'Invalid Mach-O universal slice count ($nFatArch).';
    }
    final stride = magicBe == 0xcafebabf ? 32 : 20;
    final foundTypes = <String>[];
    for (var i = 0; i < nFatArch; i++) {
      final offset = 8 + i * stride;
      if (offset + 4 > bytes.length) break;
      final sliceCpuType = bd.getUint32(offset, Endian.big);
      foundTypes.add('0x${sliceCpuType.toRadixString(16)}');
      if (sliceCpuType == expectedCpuType) {
        return null;
      }
    }
    return 'Universal Mach-O binary does not contain cputype=0x${expectedCpuType.toRadixString(16)} '
        '(found slices: ${foundTypes.join(', ')}).';
  }

  return 'Invalid Mach-O magic bytes (0x${magicBe.toRadixString(16)}).';
}
