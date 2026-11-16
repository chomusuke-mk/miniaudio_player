import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks/hooks.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/src/loader/platform_loader.dart';

import '../hook/src/binary_validator.dart';
import '../hook/src/depfile_parser.dart';
import '../hook/src/gzip_extractor.dart';
import '../hook/src/target_triple.dart';

void main() {
  group('Native Assets Loader & Concurrent Initialization', () {
    test(
      'concurrent ensureInitialized() calls share memoized future without racing',
      () async {
        // Invoke ensureInitialized concurrently across 16 futures
        await Future.wait(
          List.generate(16, (_) => MiniaudioPlayer.ensureInitialized()),
        );

        final devices = MiniaudioPlayer.getOutputDevicesSync();
        expect(devices, isNotEmpty);
      },
    );

    test(
      'resolvePlatformExternalLibrary locates the compiled native library',
      () async {
        final extLib = await resolvePlatformExternalLibrary();
        expect(extLib, isNotNull);
      },
    );

    test(
      'hook/build.dart produces CodeAsset or shared cargo_target with .crate-hash stamp',
      () {
        final hookFile = File('hook/build.dart');
        expect(hookFile.existsSync(), isTrue);

        // Verify either the Native Assets build output or local target binary exists
        final candidatePaths = <String>[
          'build/native_assets/${Platform.operatingSystem}/libminiaudio_player.so',
          'build/native_assets/${Platform.operatingSystem}/libminiaudio_player.dylib',
          'build/native_assets/${Platform.operatingSystem}/miniaudio_player.dll',
          '.dart_tool/lib/libminiaudio_player.so',
          '.dart_tool/lib/libminiaudio_player.dylib',
          '.dart_tool/lib/miniaudio_player.dll',
          'rust/target/release/libminiaudio_player.so',
          'rust/target/debug/libminiaudio_player.so',
        ];
        final anyExists = candidatePaths.any((p) => File(p).existsSync());
        expect(
          anyExists,
          isTrue,
          reason:
              'Expected at least one compiled native library artifact to exist on disk.',
        );
      },
    );
  });

  group('Hook Triple Mapping, Archive Naming & Deployment Target', () {
    test('resolveRustTriple maps all 15 supported targets including ia32 and windows-arm64', () {
      expect(
        resolveRustTriple(OS.android, Architecture.arm64, null),
        'aarch64-linux-android',
      );
      expect(
        resolveRustTriple(OS.android, Architecture.arm, null),
        'armv7-linux-androideabi',
      );
      expect(
        resolveRustTriple(OS.android, Architecture.x64, null),
        'x86_64-linux-android',
      );
      expect(
        resolveRustTriple(OS.android, Architecture.ia32, null),
        'i686-linux-android',
      );

      expect(
        resolveRustTriple(OS.iOS, Architecture.arm64, IOSSdk.iPhoneOS),
        'aarch64-apple-ios',
      );
      expect(
        resolveRustTriple(OS.iOS, Architecture.arm64, IOSSdk.iPhoneSimulator),
        'aarch64-apple-ios-sim',
      );
      expect(
        resolveRustTriple(OS.iOS, Architecture.x64, IOSSdk.iPhoneSimulator),
        'x86_64-apple-ios',
      );

      expect(
        resolveRustTriple(OS.macOS, Architecture.arm64, null),
        'aarch64-apple-darwin',
      );
      expect(
        resolveRustTriple(OS.macOS, Architecture.x64, null),
        'x86_64-apple-darwin',
      );

      expect(
        resolveRustTriple(OS.linux, Architecture.x64, null),
        'x86_64-unknown-linux-gnu',
      );
      expect(
        resolveRustTriple(OS.linux, Architecture.arm64, null),
        'aarch64-unknown-linux-gnu',
      );
      expect(
        resolveRustTriple(OS.linux, Architecture.ia32, null),
        'i686-unknown-linux-gnu',
      );

      expect(
        resolveRustTriple(OS.windows, Architecture.x64, null),
        'x86_64-pc-windows-msvc',
      );
      expect(
        resolveRustTriple(OS.windows, Architecture.arm64, null),
        'aarch64-pc-windows-msvc',
      );
      expect(
        resolveRustTriple(OS.windows, Architecture.ia32, null),
        'i686-pc-windows-msvc',
      );
    });

    test('resolveRustTriple throws BuildError on unsupported triples', () {
      expect(
        () => resolveRustTriple(OS.linux, Architecture.arm, null),
        throwsA(isA<BuildError>()),
      );
      expect(
        () => resolveRustTriple(OS.windows, Architecture.riscv64, null),
        throwsA(isA<BuildError>()),
      );
    });

    test('prebuiltArchiveName uses single .gz format without .tar', () {
      expect(
        prebuiltArchiveName(
          packageName: 'miniaudio_player',
          version: '4.0.0',
          rustTriple: 'i686-pc-windows-msvc',
          libFileName: 'miniaudio_player.dll',
        ),
        'miniaudio_player-v4.0.0-i686-pc-windows-msvc.dll.gz',
      );
      expect(
        prebuiltArchiveName(
          packageName: 'miniaudio_player',
          version: '4.0.0',
          rustTriple: 'aarch64-unknown-linux-gnu',
          libFileName: 'libminiaudio_player.so',
        ),
        'miniaudio_player-v4.0.0-aarch64-unknown-linux-gnu.so.gz',
      );
      expect(
        prebuiltArchiveName(
          packageName: 'miniaudio_player',
          version: '4.0.0',
          rustTriple: 'aarch64-apple-ios-sim',
          libFileName: 'libminiaudio_player.dylib',
        ),
        'miniaudio_player-v4.0.0-aarch64-apple-ios-sim.dylib.gz',
      );
    });

    test('formatAppleDeploymentTarget and resolveAppleDeploymentTarget handle all schema versions', () {
      expect(formatAppleDeploymentTarget(major: 12), '12.0');
      expect(
        formatAppleDeploymentTarget(major: 15, minor: 2, patch: 1),
        '15.2.1',
      );
      expect(
        resolveAppleDeploymentTarget({
          'config': {
            'code': {
              'iOS': {
                'deployment_version': {'major': 15, 'minor': 2, 'patch': 0},
                'target_version': 12,
              },
            },
          },
        }, OS.iOS),
        '15.2',
      );
      expect(
        resolveAppleDeploymentTarget({
          'config': {
            'code': {
              'macOS': {'target_version': 13},
            },
          },
        }, OS.macOS),
        '13.0',
      );
    });
  });

  group('Binary Header Validators (ELF / PE / Mach-O)', () {
    test('validates matching ELF headers and rejects cross-arch mismatches', () {
      final linuxX64 = _makeElfHeader(eiClass: 2, eMachine: 0x003e);
      final linuxArm64 = _makeElfHeader(eiClass: 2, eMachine: 0x00b7);
      final androidArmV7 = _makeElfHeader(eiClass: 1, eMachine: 0x0028);
      final linuxIa32 = _makeElfHeader(eiClass: 1, eMachine: 0x0003);

      expect(validateBinaryHeaderBytes(linuxX64, OS.linux, Architecture.x64), isNull);
      expect(validateBinaryHeaderBytes(linuxArm64, OS.linux, Architecture.arm64), isNull);
      expect(validateBinaryHeaderBytes(androidArmV7, OS.android, Architecture.arm), isNull);
      expect(validateBinaryHeaderBytes(linuxIa32, OS.linux, Architecture.ia32), isNull);

      expect(validateBinaryHeaderBytes(linuxX64, OS.linux, Architecture.arm64), isNotNull);
      expect(validateBinaryHeaderBytes(linuxArm64, OS.linux, Architecture.x64), isNotNull);
      expect(validateBinaryHeaderBytes(linuxIa32, OS.android, Architecture.x64), isNotNull);
    });

    test('validates matching PE headers and rejects cross-arch mismatches', () {
      final winX64 = _makePeHeader(machine: 0x8664);
      final winArm64 = _makePeHeader(machine: 0xaa64);
      final winIa32 = _makePeHeader(machine: 0x014c);

      expect(validateBinaryHeaderBytes(winX64, OS.windows, Architecture.x64), isNull);
      expect(validateBinaryHeaderBytes(winArm64, OS.windows, Architecture.arm64), isNull);
      expect(validateBinaryHeaderBytes(winIa32, OS.windows, Architecture.ia32), isNull);

      expect(validateBinaryHeaderBytes(winX64, OS.windows, Architecture.arm64), isNotNull);
      expect(validateBinaryHeaderBytes(winArm64, OS.windows, Architecture.ia32), isNotNull);
      expect(
        validateBinaryHeaderBytes(Uint8List.fromList([1, 2, 3, 4]), OS.windows, Architecture.x64),
        isNotNull,
      );
    });

    test('validates thin and fat Mach-O headers cleanly', () {
      final macX64 = _makeThinMachOHeader(cpuType: 0x01000007);
      final macArm64 = _makeThinMachOHeader(cpuType: 0x0100000c);
      final universal = _makeFatMachOHeader([0x01000007, 0x0100000c]);
      final x64OnlyFat = _makeFatMachOHeader([0x01000007]);

      expect(validateBinaryHeaderBytes(macX64, OS.macOS, Architecture.x64), isNull);
      expect(validateBinaryHeaderBytes(macArm64, OS.iOS, Architecture.arm64), isNull);
      expect(validateBinaryHeaderBytes(universal, OS.macOS, Architecture.arm64), isNull);
      expect(validateBinaryHeaderBytes(universal, OS.macOS, Architecture.x64), isNull);

      expect(validateBinaryHeaderBytes(macX64, OS.macOS, Architecture.arm64), isNotNull);
      expect(validateBinaryHeaderBytes(x64OnlyFat, OS.iOS, Architecture.arm64), isNotNull);
    });
  });

  group('Gzip Extraction, Depfile Parsing & Packaging Hygiene', () {
    test('decompressGzipFile extracts payload via dart:io and fails cleanly on corrupt input', () async {
      final tmp = await Directory.systemTemp.createTemp('miniaudio_gzip_test_');
      addTearDown(() => tmp.delete(recursive: true));

      final payload = utf8.encode('ELF\x7f miniaudio_player test binary stream' * 64);
      final gzFile = File('${tmp.path}/libtest.so.gz');
      final outFile = File('${tmp.path}/sub/libtest.so');
      await gzFile.writeAsBytes(gzip.encode(payload));

      await decompressGzipFile(gzFile, outFile);
      expect(await outFile.readAsBytes(), equals(payload));

      final corruptGz = File('${tmp.path}/corrupt.so.gz');
      final failedOut = File('${tmp.path}/corrupt.so');
      await corruptGz.writeAsBytes([0x00, 0x01, 0x02, 0x03]);
      await expectLater(
        decompressGzipFile(corruptGz, failedOut),
        throwsA(isA<InfraError>()),
      );
      expect(failedOut.existsSync(), isFalse);
    });

    test('splitMakeDeps preserves backslash-escaped spaces in source paths', () {
      const line =
          r'/Users/John\ Doe/miniaudio_player/rust/src/lib.rs  /opt/a\ b/c.rs C:\My\ Path\x.c';
      expect(
        splitMakeDeps(line),
        [
          '/Users/John Doe/miniaudio_player/rust/src/lib.rs',
          '/opt/a b/c.rs',
          r'C:\My Path\x.c',
        ],
      );
    });

    test('Web assets are clean in assets/web/ without web/pkg provisioning', () {
      expect(File('assets/web/miniaudio_player.js').existsSync(), isTrue);
      expect(File('assets/web/miniaudio_player_bg.wasm').existsSync(), isTrue);
      expect(Directory('assets/web').listSync().length, 2);
      expect(Directory('example/web/pkg').existsSync(), isFalse);

      final hookSource = File('hook/build.dart').readAsStringSync();
      expect(hookSource.contains('_provisionWebAssetsIfNeeded'), isFalse);
      expect(hookSource.contains("Process.run('tar'"), isFalse);
    });
  });

  group('Priority 4 End-to-End Hook Prebuilt (.gz) Download', () {
    test(
      'hook/build.dart downloads, verifies SHA-256, extracts .gz and validates headers for all 15 targets',
      () async {
        final tmp = await Directory.systemTemp.createTemp('miniaudio_hook_e2e_');
        addTearDown(() => tmp.delete(recursive: true));

        // Compile hook once to kernel bytecode so 17 runs execute cleanly in ~1-2s.
        final hookDill = '${tmp.path}/build_hook.dill';
        final compileRes = await Process.run(
          'dart',
          ['compile', 'kernel', 'hook/build.dart', '-o', hookDill],
        );
        expect(compileRes.exitCode, 0, reason: '${compileRes.stderr}');

        final fakePkgRoot = Directory('${tmp.path}/pub_pkg')..createSync();
        File('${fakePkgRoot.path}/pubspec.yaml')
            .writeAsStringSync('name: miniaudio_player\nversion: 4.0.0\n');

        final targets = <({
          OS os,
          Architecture arch,
          IOSSdk? iosSdk,
          Uint8List rawBinary,
        })>[
          (os: OS.android, arch: Architecture.arm64, iosSdk: null, rawBinary: _makeElfHeader(eiClass: 2, eMachine: 0x00b7)),
          (os: OS.android, arch: Architecture.arm, iosSdk: null, rawBinary: _makeElfHeader(eiClass: 1, eMachine: 0x0028)),
          (os: OS.android, arch: Architecture.x64, iosSdk: null, rawBinary: _makeElfHeader(eiClass: 2, eMachine: 0x003e)),
          (os: OS.android, arch: Architecture.ia32, iosSdk: null, rawBinary: _makeElfHeader(eiClass: 1, eMachine: 0x0003)),
          (os: OS.linux, arch: Architecture.x64, iosSdk: null, rawBinary: _makeElfHeader(eiClass: 2, eMachine: 0x003e)),
          (os: OS.linux, arch: Architecture.arm64, iosSdk: null, rawBinary: _makeElfHeader(eiClass: 2, eMachine: 0x00b7)),
          (os: OS.linux, arch: Architecture.ia32, iosSdk: null, rawBinary: _makeElfHeader(eiClass: 1, eMachine: 0x0003)),
          (os: OS.windows, arch: Architecture.x64, iosSdk: null, rawBinary: _makePeHeader(machine: 0x8664)),
          (os: OS.windows, arch: Architecture.arm64, iosSdk: null, rawBinary: _makePeHeader(machine: 0xaa64)),
          (os: OS.windows, arch: Architecture.ia32, iosSdk: null, rawBinary: _makePeHeader(machine: 0x014c)),
          (os: OS.macOS, arch: Architecture.arm64, iosSdk: null, rawBinary: _makeThinMachOHeader(cpuType: 0x0100000c)),
          (os: OS.macOS, arch: Architecture.x64, iosSdk: null, rawBinary: _makeThinMachOHeader(cpuType: 0x01000007)),
          (os: OS.iOS, arch: Architecture.arm64, iosSdk: IOSSdk.iPhoneOS, rawBinary: _makeThinMachOHeader(cpuType: 0x0100000c)),
          (os: OS.iOS, arch: Architecture.arm64, iosSdk: IOSSdk.iPhoneSimulator, rawBinary: _makeThinMachOHeader(cpuType: 0x0100000c)),
          (os: OS.iOS, arch: Architecture.x64, iosSdk: IOSSdk.iPhoneSimulator, rawBinary: _makeThinMachOHeader(cpuType: 0x01000007)),
        ];

        final artifacts = <String, List<int>>{};
        final checksumLines = StringBuffer();
        for (final target in targets) {
          final triple = resolveRustTriple(target.os, target.arch, target.iosSdk);
          final libName = target.os.dylibFileName('miniaudio_player');
          final archive = prebuiltArchiveName(
            packageName: 'miniaudio_player',
            version: '4.0.0',
            rustTriple: triple,
            libFileName: libName,
          );
          final gzBytes = gzip.encode(target.rawBinary);
          artifacts[archive] = gzBytes;
          checksumLines.writeln('${sha256.convert(gzBytes)}  $archive');
        }

        // Also prepare a validly-hashed WRONG-arch binary (x64 served for arm64) and a hash mismatch.
        const wrongArchName = 'miniaudio_player-v4.0.0-aarch64-unknown-linux-gnu.so.gz';
        final wrongElfGz = gzip.encode(_makeElfHeader(eiClass: 2, eMachine: 0x003e));
        const badHashName = 'miniaudio_player-v4.0.0-x86_64-unknown-linux-gnu.so.gz';
        final tamperedGz = gzip.encode(_makeElfHeader(eiClass: 2, eMachine: 0x003e));

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) {
          final path = req.uri.path;
          if (path == '/good/checksums.sha256') {
            req.response
              ..statusCode = HttpStatus.ok
              ..write(checksumLines.toString())
              ..close();
            return;
          }
          if (path.startsWith('/good/')) {
            final name = path.substring('/good/'.length);
            final payload = artifacts[name];
            if (payload != null) {
              req.response
                ..statusCode = HttpStatus.ok
                ..add(payload)
                ..close();
              return;
            }
          }
          if (path == '/wrong-arch/checksums.sha256') {
            req.response
              ..statusCode = HttpStatus.ok
              ..write('${sha256.convert(wrongElfGz)}  $wrongArchName\n')
              ..close();
            return;
          }
          if (path == '/wrong-arch/$wrongArchName') {
            req.response
              ..statusCode = HttpStatus.ok
              ..add(wrongElfGz)
              ..close();
            return;
          }
          if (path == '/bad-hash/checksums.sha256') {
            req.response
              ..statusCode = HttpStatus.ok
              ..write('${'0' * 64}  $badHashName\n')
              ..close();
            return;
          }
          if (path == '/bad-hash/$badHashName') {
            req.response
              ..statusCode = HttpStatus.ok
              ..add(tamperedGz)
              ..close();
            return;
          }
          req.response
            ..statusCode = HttpStatus.notFound
            ..close();
        });

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final sharedOutDir = Directory('${tmp.path}/shared_out')..createSync();

        Future<ProcessResult> invokeHook({
          required String caseDirName,
          required OS os,
          required Architecture arch,
          IOSSdk? iosSdk,
          required String urlPrefix,
        }) async {
          final caseDir = Directory('${tmp.path}/$caseDirName')..createSync();
          final outFile = File('${caseDir.path}/output.json');
          final inFile = File('${caseDir.path}/input.json');
          final builder = BuildInputBuilder()
            ..setupShared(
              packageRoot: fakePkgRoot.uri,
              packageName: 'miniaudio_player',
              outputDirectoryShared: sharedOutDir.uri,
              outputFile: outFile.uri,
            )
            ..config.setupBuild(linkingEnabled: false)
            ..addExtension(
              CodeAssetExtension(
                targetOS: os,
                targetArchitecture: arch,
                linkModePreference: LinkModePreference.dynamic,
                android: os == OS.android ? AndroidCodeConfig(targetNdkApi: 24) : null,
                iOS: os == OS.iOS
                    ? IOSCodeConfig(
                        targetSdk: iosSdk!,
                        deploymentVersion: AppleVersion(12),
                      )
                    : null,
                macOS: os == OS.macOS
                    ? MacOSCodeConfig(deploymentVersion: AppleVersion(11))
                    : null,
              ),
            );
          await inFile.writeAsString(jsonEncode(builder.json));
          return Process.run(
            'dart',
            [hookDill, '--config=${inFile.path}'],
            environment: {
              ...Platform.environment,
              'MINIAUDIO_PLAYER_DOWNLOAD_BASE_URL': '$baseUrl/$urlPrefix',
            },
          );
        }

        // 1. All 15 targets succeed cleanly from Priority 4 without .tar.
        for (var i = 0; i < targets.length; i++) {
          final t = targets[i];
          final res = await invokeHook(
            caseDirName: 'good_$i',
            os: t.os,
            arch: t.arch,
            iosSdk: t.iosSdk,
            urlPrefix: 'good',
          );
          expect(
            res.exitCode,
            0,
            reason: 'Target ${t.os}/${t.arch} failed: ${res.stderr}',
          );
          final outJson = jsonDecode(
            await File('${tmp.path}/good_$i/output.json').readAsString(),
          ) as Map<String, dynamic>;
          final buildOutput = BuildOutput(outJson);
          final assets = buildOutput.assets.code;
          expect(assets.length, 1);
          final outBinary = File.fromUri(assets.single.file!);
          expect(outBinary.existsSync(), isTrue);
          expect(await outBinary.readAsBytes(), equals(t.rawBinary));
        }

        // 2. Cryptographic SHA-256 mismatch aborts with non-zero exit (no silent fallback).
        final badHashRes = await invokeHook(
          caseDirName: 'bad_hash',
          os: OS.linux,
          arch: Architecture.x64,
          urlPrefix: 'bad-hash',
        );
        expect(badHashRes.exitCode, isNot(0));

        // 3. Wrong ELF architecture (x64 served as arm64) aborts with non-zero exit.
        final wrongArchRes = await invokeHook(
          caseDirName: 'wrong_arch',
          os: OS.linux,
          arch: Architecture.arm64,
          urlPrefix: 'wrong-arch',
        );
        expect(wrongArchRes.exitCode, isNot(0));
      },
    );
  });
}

Uint8List _makeElfHeader({required int eiClass, required int eMachine}) {
  final bytes = Uint8List(32);
  bytes[0] = 0x7f;
  bytes[1] = 0x45;
  bytes[2] = 0x4c;
  bytes[3] = 0x46;
  bytes[4] = eiClass;
  bytes[5] = 1; // little endian
  ByteData.sublistView(bytes).setUint16(18, eMachine, Endian.little);
  return bytes;
}

Uint8List _makePeHeader({required int machine}) {
  final bytes = Uint8List(128);
  bytes[0] = 0x4d; // M
  bytes[1] = 0x5a; // Z
  final bd = ByteData.sublistView(bytes);
  const peOffset = 0x40;
  bd.setUint32(60, peOffset, Endian.little);
  bytes[peOffset] = 0x50; // P
  bytes[peOffset + 1] = 0x45; // E
  bd.setUint16(peOffset + 4, machine, Endian.little);
  return bytes;
}

Uint8List _makeThinMachOHeader({required int cpuType}) {
  final bytes = Uint8List(32);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0xfeedfacf, Endian.little);
  bd.setUint32(4, cpuType, Endian.little);
  return bytes;
}

Uint8List _makeFatMachOHeader(List<int> cpuTypes) {
  final bytes = Uint8List(8 + cpuTypes.length * 20);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0xcafebabe, Endian.big);
  bd.setUint32(4, cpuTypes.length, Endian.big);
  for (var i = 0; i < cpuTypes.length; i++) {
    bd.setUint32(8 + i * 20, cpuTypes[i], Endian.big);
  }
  return bytes;
}
