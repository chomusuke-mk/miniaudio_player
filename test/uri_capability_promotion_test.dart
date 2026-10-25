import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/src/ffi/native_types.dart';
import 'package:miniaudio_player/src/platform/fs_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  tearDown(() {
    MiniaudioPlayerGlobalConfig.resetUriConfig();
    MiniaudioPlayerGlobalConfig.assetLoader = null;
  });

  // ===========================================================================
  // 1. Unified Scheme Classification Table & Precaución 4 (Windows Paths)
  // ===========================================================================
  group('1. Unified URI Scheme Classification & Windows Path Disambiguation', () {
    test('POSIX and Windows drive / UNC paths classify immediately as FileAudioSource (Precaución 4)', () {
      final posix = AudioSource.uri('/home/user/music/track.mp3');
      expect(posix, isA<FileAudioSource>());
      expect((posix as FileAudioSource).filePath, equals('/home/user/music/track.mp3'));

      final winBackslash = AudioSource.uri(r'C:\Users\Audio\track.mp3');
      expect(winBackslash, isA<FileAudioSource>());
      expect((winBackslash as FileAudioSource).filePath, equals(r'C:\Users\Audio\track.mp3'));

      final winSlash = AudioSource.uri('D:/Music/Lossless/song.flac');
      expect(winSlash, isA<FileAudioSource>());
      expect((winSlash as FileAudioSource).filePath, equals('D:/Music/Lossless/song.flac'));

      final winUnc = AudioSource.uri(r'\\NASServer\MusicShare\album\track.wav');
      expect(winUnc, isA<FileAudioSource>());
      expect((winUnc as FileAudioSource).filePath, equals(r'\\NASServer\MusicShare\album\track.wav'));

      final itemWin = EngineItem.fromDynamic(r'C:\Users\Audio\track.mp3');
      expect(itemWin.source, isA<FileAudioSource>());
      expect(itemWin.filePath, equals(r'C:\Users\Audio\track.mp3'));
    });

    test('file:// URIs decode percent-encoding and handle Windows file:///C:/ paths', () {
      final unixFile = AudioSource.uri('file:///storage/emulated/0/Music/my%20song.mp3');
      expect(unixFile, isA<FileAudioSource>());
      expect(
        (unixFile as FileAudioSource).filePath,
        equals('/storage/emulated/0/Music/my song.mp3'),
      );

      final winFileUri = AudioSource.uri('file:///C:/Users/Audio/my%20track.mp3');
      expect(winFileUri, isA<FileAudioSource>());
      expect(
        (winFileUri as FileAudioSource).filePath,
        equals('C:/Users/Audio/my track.mp3'),
      );
    });

    test('package: scheme resolves to AssetAudioSource with package and assetKey', () {
      final source = AudioSource.uri('package:my_audio_pkg/assets/sfx/chime.wav');
      expect(source, isA<AssetAudioSource>());
      final asset = source as AssetAudioSource;
      expect(asset.package, equals('my_audio_pkg'));
      expect(asset.assetKey, equals('assets/sfx/chime.wav'));

      final item = EngineItem.uri(Uri.parse('package:my_audio_pkg/assets/sfx/chime.wav'));
      expect(item.sourceKey, equals('asset:packages/my_audio_pkg/assets/sfx/chime.wav'));
    });

    test('asset://, assets://, flutter-asset://, and assets/ resolve to AssetAudioSource', () {
      for (final raw in [
        'asset:///assets/music/a.mp3',
        'asset://assets/music/a.mp3',
        'assets://music/a.mp3',
        'flutter-asset:///assets/music/a.mp3',
        'assets/music/a.mp3',
      ]) {
        final s = AudioSource.uri(raw);
        expect(s, isA<AssetAudioSource>(), reason: 'Failed for $raw');
        expect((s as AssetAudioSource).assetKey, equals('assets/music/a.mp3'));
      }
    });

    test('data: URI (RFC 2397) resolves to MemoryAudioSource with embedded bytes and MIME', () {
      final payload = Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4]);
      final b64 = base64Encode(payload);
      final dataUri = 'data:audio/wav;base64,$b64';

      final source = AudioSource.uri(dataUri);
      expect(source, isA<MemoryAudioSource>());
      final mem = source as MemoryAudioSource;
      expect(mem.bytes, equals(payload));
      expect(mem.mimeType, equals('audio/wav'));
    });

    test('icy:// and icyx:// resolve to LiveStreamAudioSource over http:// with isLive: true', () {
      final icy = AudioSource.uri('icy://radio.example.com:8000/live');
      expect(icy, isA<LiveStreamAudioSource>());
      final live = icy as LiveStreamAudioSource;
      expect(live.uri, equals(Uri.parse('http://radio.example.com:8000/live')));
      expect(live.isLive, isTrue);

      final icyx = AudioSource.uri('icyx://radio.example.com:8000/stream');
      expect(icyx, isA<LiveStreamAudioSource>());
      expect(
        (icyx as LiveStreamAudioSource).uri,
        equals(Uri.parse('http://radio.example.com:8000/stream')),
      );
    });

    test('blob: URLs resolve to NetworkAudioSource', () {
      const blobStr = 'blob:https://app.example.com/550e8400-e29b-41d4-a716-446655440000';
      final s = AudioSource.uri(blobStr);
      expect(s, isA<NetworkAudioSource>());
      expect((s as NetworkAudioSource).uri.toString(), equals(blobStr));
    });

    test('fd:// and /proc/self/fd/<fd> resolve to ResolvingAudioSource', () {
      final fdSource1 = AudioSource.uri('fd://48');
      expect(fdSource1, isA<ResolvingAudioSource>());
      expect((fdSource1 as ResolvingAudioSource).uri, equals(Uri.parse('fd://48')));

      final fdSource2 = AudioSource.uri('/proc/self/fd/48');
      expect(fdSource2, isA<ResolvingAudioSource>());
      expect((fdSource2 as ResolvingAudioSource).uri, equals(Uri.parse('fd://48')));
    });

    test('opaque content:// MediaStore URI resolves to ResolvingAudioSource', () {
      final contentSource = AudioSource.uri('content://media/external/audio/media/10452');
      expect(contentSource, isA<ResolvingAudioSource>());
      final res = contentSource as ResolvingAudioSource;
      expect(res.uri.toString(), equals('content://media/external/audio/media/10452'));
      expect(res.canonicalFilePath, isNull);
    });
  });

  // ===========================================================================
  // 2. Step 1 Synchronous Capability Promotion (SAF raw:, primary:, appDirectories)
  // ===========================================================================
  group('2. Step 1 Synchronous Capability Promotion (Without Opening FD)', () {
    late Directory tempAppDir;
    late File appAudioFile;

    setUp(() async {
      tempAppDir = await Directory.systemTemp.createTemp('miniaudio_uri_step1_');
      final musicSubDir = Directory('${tempAppDir.path}/music')..createSync(recursive: true);
      final srcMp3 = resolveAsset('example/assets/music/salida.mp3');
      appAudioFile = File('${musicSubDir.path}/cancion.mp3');
      await srcMp3.copy(appAudioFile.path);
    });

    tearDown(() async {
      if (tempAppDir.existsSync()) {
        await tempAppDir.delete(recursive: true);
      }
    });

    test('SAF raw: URI pointing to readable local file promotes synchronously to FileAudioSource', () async {
      final encodedDoc = Uri.encodeComponent('raw:${appAudioFile.path}');
      final safRawUri =
          'content://com.android.providers.downloads.documents/document/$encodedDoc';

      final source = AudioSource.uri(safRawUri);
      expect(source, isA<FileAudioSource>());
      expect((source as FileAudioSource).filePath, equals(appAudioFile.path));

      final player = MiniaudioPlayer();
      try {
        await player.action.open(safRawUri);
        expect(player.loader?.provider, isA<FileByteProvider>());
        expect(player.state.duration.inSeconds, inInclusiveRange(65, 75));
      } finally {
        await player.dispose();
      }
    });

    test('FileProvider URI with registered appDirectories promotes synchronously to FileAudioSource', () async {
      MiniaudioPlayerGlobalConfig.appDirectories = [tempAppDir.path];

      // 1. Direct relative match: content://com.miapp.fileprovider/music/cancion.mp3
      final uri1 = 'content://com.miapp.fileprovider/music/cancion.mp3';
      final source1 = AudioSource.uri(uri1);
      expect(source1, isA<FileAudioSource>());
      expect((source1 as FileAudioSource).filePath, equals(appAudioFile.path));

      // 2. FileProvider alias segment: content://com.miapp.fileprovider/mis_audios/cancion.mp3
      MiniaudioPlayerGlobalConfig.fileProviderAliases = {
        'mis_audios': '${tempAppDir.path}/music',
      };
      final uri2 = 'content://com.miapp.fileprovider/mis_audios/cancion.mp3';
      final source2 = AudioSource.uri(uri2);
      expect(source2, isA<FileAudioSource>());
      expect((source2 as FileAudioSource).filePath, equals(appAudioFile.path));

      final player = MiniaudioPlayer();
      try {
        await player.action.open(uri2);
        expect(player.loader?.provider, isA<FileByteProvider>());
        expect(player.state.duration.inSeconds, inInclusiveRange(65, 75));
      } finally {
        await player.dispose();
      }
    });
  });

  // ===========================================================================
  // 3. Step 2 Kernel /proc/self/fd/<fd> Promotion (Escenario A vs Escenario B)
  // ===========================================================================
  group('3. Kernel /proc/self/fd/<fd> Resolution (Escenario A & Escenario B)', () {
    test(
      'Escenario A: opaque content:// pointing to readable app file promotes to FileByteProvider (Level 1) and closes temporary fd immediately',
      () async {
        final mp3File = resolveAsset('example/assets/music/salida.mp3').absolute;
        expect(mp3File.existsSync(), isTrue);

        int? openedFd;
        final closedFds = <int>[];

        MiniaudioPlayerGlobalConfig.contentFdOpener = (uri) {
          openedFd = openNativeFd(mp3File.path);
          expect(openedFd, greaterThanOrEqualTo(0));
          return openedFd;
        };

        MiniaudioPlayerGlobalConfig.fdCloser = (fd) {
          closedFds.add(fd);
          closeNativeFdSync(fd);
        };

        final player = MiniaudioPlayer();
        try {
          await player.action.open('content://media/external/audio/media/10452');

          // 1. Temporary fd must have been closed immediately in try/finally upon promotion!
          expect(openedFd, isNotNull);
          expect(closedFds, equals([openedFd]));

          // 2. Provider must be promoted to Level 1 FileByteProvider with exact realPath
          expect(player.loader?.provider, isA<FileByteProvider>());
          final fileProvider = player.loader!.provider as FileByteProvider;
          expect(
            File(fileProvider.filePath).resolveSymbolicLinksSync(),
            equals(mp3File.resolveSymbolicLinksSync()),
          );

          // 3. Plays and seeks identically to openFile()
          expect(player.state.duration.inSeconds, inInclusiveRange(65, 75));
          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(player.state.playing, isTrue);

          await player.action.seek(const Duration(seconds: 20));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(player.state.position.inSeconds, inInclusiveRange(19, 23));

          await player.action.stop();
        } finally {
          await player.dispose();
        }
        // Still closed exactly once (never double-closed)
        expect(closedFds, equals([openedFd]));
      },
    );

    test(
      'Escenario B: content:// blocked by Scoped Storage (EACCES on direct path) stays in Level 2 FdByteProvider with O(1) random-access seek and probeTail',
      () async {
        final flacFile = resolveAsset('example/assets/music/salida.flac').absolute;
        expect(flacFile.existsSync(), isTrue);

        int? openedFd;
        final closedFds = <int>[];

        // Simulate Scoped Storage / SELinux: kernel grants open fd, but direct open(realPath) by name is denied
        MiniaudioPlayerGlobalConfig.directFileAccessProbe = (_) => false;
        MiniaudioPlayerGlobalConfig.contentFdOpener = (uri) {
          openedFd = openNativeFd(flacFile.path);
          expect(openedFd, greaterThanOrEqualTo(0));
          return openedFd;
        };
        MiniaudioPlayerGlobalConfig.fdCloser = (fd) {
          closedFds.add(fd);
          closeNativeFdSync(fd);
        };

        final player = MiniaudioPlayer();
        try {
          await player.action.open('content://com.other.app.provider/external_audio/99');

          // 1. Provider must be Level 2 FdByteProvider (NOT copied to MemoryByteProvider or temp file)
          expect(player.loader?.provider, isA<FdByteProvider>());
          final fdProvider = player.loader!.provider as FdByteProvider;
          expect(fdProvider.fd, equals(openedFd));
          expect(fdProvider.isClosed, isFalse);
          expect(closedFds, isEmpty, reason: 'FD must remain open while FdByteProvider is active');

          // 2. Duration and metadata probed accurately via FdByteProvider
          expect(player.state.duration.inSeconds, greaterThan(0));

          // 3. Play, random-access seek, stop, and replay over FdByteProvider
          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 120));
          expect(player.state.playing, isTrue);

          await player.action.seek(const Duration(seconds: 15));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(player.state.position.inSeconds, inInclusiveRange(14, 18));

          await player.action.stop();
          expect(player.state.playing, isFalse);
          expect(fdProvider.isClosed, isFalse, reason: 'stop() must not close the owned FD');

          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(player.state.playing, isTrue);
        } finally {
          await player.dispose();
        }

        // 4. Upon dispose(), FdByteProvider closes the owned fd exactly once!
        expect(closedFds, equals([openedFd]));
      },
    );
  });

  // ===========================================================================
  // 4. Precaución 1: Strict FD Lifecycle & Idempotent Close (No EMFILE / Double-Close)
  // ===========================================================================
  group('4. Precaución 1: Strict FD Lifecycle & Idempotent Close', () {
    test('FdByteProvider.close() is strictly idempotent under sequential and concurrent calls', () async {
      final wavFile = resolveAsset('example/assets/music/salida.wav').absolute;
      final fd = openNativeFd(wavFile.path);
      expect(fd, greaterThanOrEqualTo(0));

      final closedCalls = <int>[];
      final provider = FdByteProvider(
        fd,
        onCloseFd: (closedFd) async {
          closedCalls.add(closedFd);
          closeNativeFdSync(closedFd);
        },
      );

      // Call close() 10 times concurrently and sequentially
      await Future.wait([
        provider.close(),
        provider.close(),
        provider.close(),
        provider.close(),
        provider.close(),
      ]);
      await provider.close();
      await provider.close();

      expect(provider.isClosed, isTrue);
      expect(provider.nativeCloseCount, equals(1));
      expect(closedCalls, equals([fd]));

      // Subsequent open() on closed provider throws MiniaudioPlayerException
      await expectLater(
        provider.open(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
      expect(await provider.probeTail(0, 64), isNull);
    });

    test('Rapid track-switching cancellation during _openGuarded closes every intermediate FD without leaking', () async {
      final mp3File = resolveAsset('example/assets/music/salida.mp3').absolute;
      final allocatedFds = <int>[];
      final closedFds = <int>[];

      // Force Level 2 FdByteProvider so FDs are held by providers until cancelled/disposed
      MiniaudioPlayerGlobalConfig.directFileAccessProbe = (_) => false;
      MiniaudioPlayerGlobalConfig.contentFdOpener = (uri) async {
        // Simulate async delay during ContentResolver IPC
        await Future<void>.delayed(const Duration(milliseconds: 15));
        final fd = openNativeFd(mp3File.path);
        allocatedFds.add(fd);
        return fd;
      };
      MiniaudioPlayerGlobalConfig.fdCloser = (fd) {
        closedFds.add(fd);
        closeNativeFdSync(fd);
      };

      final player = MiniaudioPlayer();
      try {
        final futures = <Future<void>>[];
        for (int i = 0; i < 15; i++) {
          futures.add(
            player.action
                .open('content://media/external/audio/media/$i')
                .catchError((_) {}),
          );
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await Future.wait(futures);
      } finally {
        await player.dispose();
      }

      // Every single FD opened by contentFdOpener must have been closed exactly once!
      expect(allocatedFds, isNotEmpty);
      expect(closedFds.length, equals(allocatedFds.length));
      expect(closedFds.toSet(), equals(allocatedFds.toSet()));
    });
  });

  // ===========================================================================
  // 5. Precaución 2: Concurrency Between open() and probeTail() on FdByteProvider
  // ===========================================================================
  group('5. Precaución 2: Concurrent open() Stream and probeTail() Serialization', () {
    test(
      'Concurrent open(offset: 0) streaming and 20 interleaved probeTail() calls on shared RandomAccessFile never corrupt stream cursor',
      () async {
        final mp3File = resolveAsset('example/assets/music/salida.mp3').absolute;
        final expectedBytes = await mp3File.readAsBytes();
        final raf = await mp3File.open(mode: FileMode.read);

        final provider = FdByteProvider(
          999,
          ownFd: false,
          sharedHandle: raf,
          chunkSize: 8192, // Small 8 KB chunks to force many cursor yields
        );

        try {
          final res = await provider.open(offset: 0);
          expect(res.totalBytes, equals(expectedBytes.length));
          expect(res.isSeekable, isTrue);

          final receivedBuilder = BytesBuilder(copy: false);
          final probeFutures = <Future<void>>[];

          int chunkIndex = 0;
          final streamDone = Completer<void>();

          final sub = res.stream.listen(
            (chunk) {
              receivedBuilder.add(chunk);
              chunkIndex++;
              // Every few chunks, launch concurrent probeTail requests at the end of the file
              if (chunkIndex % 3 == 0) {
                final tailLen = 4096;
                final tailOffset = expectedBytes.length - tailLen;
                probeFutures.add(() async {
                  final tail = await provider.probeTail(tailOffset, tailLen);
                  expect(tail, isNotNull);
                  expect(
                    tail,
                    equals(Uint8List.sublistView(expectedBytes, tailOffset, tailOffset + tailLen)),
                  );
                }());
              }
            },
            onDone: () => streamDone.complete(),
            onError: (Object e, StackTrace st) => streamDone.completeError(e, st),
          );

          await streamDone.future;
          await Future.wait(probeFutures);
          await sub.cancel();

          final actualBytes = receivedBuilder.takeBytes();
          expect(actualBytes.length, equals(expectedBytes.length));
          expect(actualBytes, equals(expectedBytes));
        } finally {
          await provider.close();
        }
      },
    );

    test(
      'Concurrent open(offset: 0) and probeTail() on native kernel FD via pread returns exact bytes',
      () async {
        final mp3File = resolveAsset('example/assets/music/salida.mp3').absolute;
        final expectedBytes = await mp3File.readAsBytes();
        final fd = openNativeFd(mp3File.path);
        expect(fd, greaterThanOrEqualTo(0));

        final provider = FdByteProvider(fd, chunkSize: 16384);
        try {
          final res = await provider.open(offset: 0);
          final receivedBuilder = BytesBuilder(copy: false);
          final probeFutures = <Future<void>>[];

          await for (final chunk in res.stream) {
            receivedBuilder.add(chunk);
            final tailOffset = expectedBytes.length - 2048;
            probeFutures.add(() async {
              final tail = await provider.probeTail(tailOffset, 2048);
              expect(
                tail,
                equals(Uint8List.sublistView(expectedBytes, tailOffset)),
              );
            }());
          }
          await Future.wait(probeFutures);
          expect(receivedBuilder.takeBytes(), equals(expectedBytes));
        } finally {
          await provider.close();
        }
      },
    );
  });

  // ===========================================================================
  // 6. Precaución 3: False Positives in /proc/self/fd (Pipes, Deleted, Android FUSE)
  // ===========================================================================
  group('6. Precaución 3: Pipes, Deleted Files & Android FUSE Mount Rewriting', () {
    test('pipe:, socket:, and anon_inode: targets are rejected from Level 1 promotion and disable seeking', () {
      for (final target in [
        'pipe:[123456]',
        'socket:[987654]',
        'anon_inode:[eventpoll]',
      ]) {
        expect(UriCapabilityResolver.isNonSeekableFdTarget(target), isTrue);
        expect(UriCapabilityResolver.isPromotableFdTarget(target), isFalse);
      }
    });

    test('Real POSIX pipe (pipe:[...]) streams sequentially through MiniaudioPlayer without setPosition or probeTail', () async {
      final pipePair = createNativePipe();
      if (pipePair == null) return; // Skip if platform has no POSIX pipe
      final (readFd, writeFd) = pipePair;

      final wavFile = resolveAsset('example/assets/music/cbr_noxing.mp3').absolute;
      final fullBytes = await wavFile.readAsBytes();
      final wavBytes = Uint8List.sublistView(
        fullBytes,
        0,
        fullBytes.length < 49152 ? fullBytes.length : 49152,
      );

      // Verify kernel symlink on Linux starts with pipe:[...]
      final linkTarget = readFdSymbolicLink(readFd);
      if (linkTarget != null) {
        expect(linkTarget, startsWith('pipe:'));
        expect(UriCapabilityResolver.isNonSeekableFdTarget(linkTarget), isTrue);
      }

      // Feed bytes into writeFd and close writeFd so readFd sees all bytes then EOF
      unawaited(Future<void>(() async {
        const step = 16384;
        for (int off = 0; off < wavBytes.length; off += step) {
          final end = (off + step < wavBytes.length) ? off + step : wavBytes.length;
          writeNativeFd(writeFd, Uint8List.sublistView(wavBytes, off, end));
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        closeNativeFdSync(writeFd);
      }));

      final player = MiniaudioPlayer();
      try {
        await player.action.open('fd://$readFd');
        expect(player.loader?.provider, isA<FdByteProvider>());
        final fdProv = player.loader!.provider as FdByteProvider;
        expect(await fdProv.probeTail(0, 128), isNull);

        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(player.state.playing, isTrue);
        await player.action.stop();
      } finally {
        await player.dispose();
      }
    });

    test('Unlinked file (" (deleted)" suffix in /proc/self/fd) is NOT promoted to Level 1 and plays via Level 2 FdByteProvider', () async {
      final tempDir = await Directory.systemTemp.createTemp('miniaudio_deleted_fd_');
      try {
        final srcMp3 = resolveAsset('example/assets/music/cbr_noxing.mp3');
        final tempMp3 = File('${tempDir.path}/ephemeral.mp3');
        await srcMp3.copy(tempMp3.path);

        final fd = openNativeFd(tempMp3.path);
        expect(fd, greaterThanOrEqualTo(0));

        // Delete the file from the directory tree while fd remains open in the kernel!
        tempMp3.deleteSync();
        expect(tempMp3.existsSync(), isFalse);

        final linkTarget = readFdSymbolicLink(fd);
        if (linkTarget != null) {
          expect(linkTarget, endsWith(' (deleted)'));
          expect(UriCapabilityResolver.isDeletedFdTarget(linkTarget), isTrue);
          expect(UriCapabilityResolver.isPromotableFdTarget(linkTarget), isFalse);
        }

        final player = MiniaudioPlayer();
        try {
          await player.action.openFd(fd);
          expect(player.loader?.provider, isA<FdByteProvider>());
          expect(player.state.duration.inSeconds, inInclusiveRange(9, 11));

          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(player.state.playing, isTrue);
          await player.action.stop();
        } finally {
          await player.dispose();
        }
      } finally {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('Android FUSE / sdcardfs paths (/mnt/user/0/emulated/0/... and /data/media/0/...) rewrite to /storage/emulated/0/...', () {
      const mntUserPath = '/mnt/user/0/emulated/0/Music/album/track.flac';
      expect(
        UriCapabilityResolver.rewriteAndroidMountPath(mntUserPath),
        equals('/storage/emulated/0/Music/album/track.flac'),
      );
      expect(
        UriCapabilityResolver.candidatePathsForTarget(mntUserPath),
        equals([
          '/mnt/user/0/emulated/0/Music/album/track.flac',
          '/storage/emulated/0/Music/album/track.flac',
        ]),
      );

      const dataMediaPath = '/data/media/0/Download/podcast.mp3';
      expect(
        UriCapabilityResolver.rewriteAndroidMountPath(dataMediaPath),
        equals('/storage/emulated/0/Download/podcast.mp3'),
      );

      const mntRuntimePath = '/mnt/runtime/write/emulated/10/Audiobooks/ch1.m4a';
      expect(
        UriCapabilityResolver.rewriteAndroidMountPath(mntRuntimePath),
        equals('/storage/emulated/10/Audiobooks/ch1.m4a'),
      );

      // Simulate FUSE path failing direct access while /storage/emulated/0/... succeeds:
      final probedPaths = <String>[];
      MiniaudioPlayerGlobalConfig.fdLinkResolver = (_) => mntUserPath;
      MiniaudioPlayerGlobalConfig.directFileAccessProbe = (path) {
        probedPaths.add(path);
        // /mnt/user/0/... fails with EACCES, /storage/emulated/0/... succeeds!
        return path == '/storage/emulated/0/Music/album/track.flac';
      };

      final promoted = UriCapabilityResolver.tryResolvePromotablePathFromFd(42);
      expect(promoted, equals('/storage/emulated/0/Music/album/track.flac'));
      expect(
        probedPaths,
        equals([
          '/mnt/user/0/emulated/0/Music/album/track.flac',
          '/storage/emulated/0/Music/album/track.flac',
        ]),
      );
    });
  });

  // ===========================================================================
  // 7. Precaución 5: Canonical Identity (sourceKey) in MiniaudioEngine
  // ===========================================================================
  group('7. Precaución 5: Canonical Identity (sourceKey) in MiniaudioEngine', () {
    test('Equivalent file://, SAF raw:, SAF primary:, and Android mount paths produce identical EngineItem.sourceKey', () {
      const canonicalTarget = '/storage/emulated/0/Music/pista.mp3';

      final itemDirect = EngineItem.file(canonicalTarget);
      final itemFileUri = EngineItem.uri(
        Uri.parse('file:///storage/emulated/0/Music/pista.mp3'),
      );
      final itemSafRaw = EngineItem.uri(
        Uri.parse(
          'content://com.android.providers.downloads.documents/document/raw%3A%2Fstorage%2Femulated%2F0%2FMusic%2Fpista.mp3',
        ),
      );
      final itemSafPrimary = EngineItem.uri(
        Uri.parse(
          'content://com.android.externalstorage.documents/document/primary%3AMusic%2Fpista.mp3',
        ),
      );
      final itemMntUser = EngineItem.file('/mnt/user/0/emulated/0/Music/pista.mp3');
      final itemDataMedia = EngineItem.file('/data/media/0/Music/pista.mp3');

      const expectedKey = 'file:/storage/emulated/0/Music/pista.mp3';
      expect(itemDirect.sourceKey, equals(expectedKey));
      expect(itemFileUri.sourceKey, equals(expectedKey));
      expect(itemSafRaw.sourceKey, equals(expectedKey));
      expect(itemSafPrimary.sourceKey, equals(expectedKey));
      expect(itemMntUser.sourceKey, equals(expectedKey));
      expect(itemDataMedia.sourceKey, equals(expectedKey));
    });

    test('FileProvider URI with registered appDirectories produces identical sourceKey as direct file path', () {
      MiniaudioPlayerGlobalConfig.appDirectories = [
        '/data/user/0/com.miapp/files',
      ];
      MiniaudioPlayerGlobalConfig.fileProviderAliases = {
        'mis_audios': '/data/user/0/com.miapp/files/music',
      };

      final itemFile = EngineItem.file('/data/user/0/com.miapp/files/music/cancion.flac');
      final itemContent = EngineItem.uri(
        Uri.parse('content://com.miapp.fileprovider/mis_audios/cancion.flac'),
      );

      expect(
        itemContent.sourceKey,
        equals('file:/data/user/0/com.miapp/files/music/cancion.flac'),
      );
      expect(itemContent.sourceKey, equals(itemFile.sourceKey));
    });
  });

  // ===========================================================================
  // 8. Precaución 6: RFC 2397 data: URI End-to-End Playback
  // ===========================================================================
  group('8. Precaución 6: RFC 2397 data: URI Playback', () {
    test('plays audio directly from RFC 2397 data:audio/mpeg;base64,... URI', () async {
      final mp3File = resolveAsset('example/assets/music/cbr_noxing.mp3');
      final mp3Bytes = await mp3File.readAsBytes();
      final dataUri = 'data:audio/mpeg;base64,${base64Encode(mp3Bytes)}';

      final player = MiniaudioPlayer();
      try {
        await player.action.open(dataUri);
        expect(player.loader?.provider, isA<MemoryByteProvider>());
        expect(player.state.duration.inSeconds, inInclusiveRange(9, 11));

        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(player.state.playing, isTrue);
        await player.action.stop();
      } finally {
        await player.dispose();
      }
    });
  });

  // ===========================================================================
  // 9. Precaución 7: Path Traversal Sanitization & Rejection
  // ===========================================================================
  group('9. Precaución 7: Path Traversal Security Sanitization', () {
    test('rejects path traversal in SAF primary:, SAF raw:, and FileProvider URIs', () async {
      MiniaudioPlayerGlobalConfig.appDirectories = [
        '/data/user/0/com.miapp/files/music',
      ];

      final maliciousUris = [
        'content://com.miapp.fileprovider/mis_audios/..%2F..%2Fshared_prefs%2Fsecrets.xml',
        'content://com.miapp.fileprovider/..%5C..%5Csecret.mp3',
        'content://com.android.externalstorage.documents/document/primary%3AMusic%2F..%2F..%2Fdata%2Fsecret.mp3',
        'content://com.android.providers.downloads.documents/document/raw%3A%2Fstorage%2Femulated%2F0%2F..%2F..%2Fdata%2Fsecret.mp3',
      ];

      final player = MiniaudioPlayer();
      try {
        for (final rawUri in maliciousUris) {
          final source = AudioSource.uri(rawUri);
          // Must NEVER promote to FileAudioSource
          expect(source, isA<ResolvingAudioSource>(), reason: 'URI: $rawUri');
          final resolving = source as ResolvingAudioSource;
          expect(resolving.rejectedByPathTraversal, isTrue, reason: 'URI: $rawUri');
          expect(resolving.canonicalFilePath, isNull, reason: 'URI: $rawUri');

          final item = EngineItem.fromDynamic(rawUri);
          expect(item.hasValidSource, isFalse, reason: 'URI: $rawUri');

          await expectLater(
            player.action.open(rawUri),
            throwsA(
              isA<MiniaudioPlayerException>().having(
                (e) => e.errorCode,
                'errorCode',
                equals(MapResult.errorAccessDenied),
              ),
            ),
            reason: 'Opening malicious URI must fail with errorAccessDenied: $rawUri',
          );
        }
      } finally {
        await player.dispose();
      }
    });
  });
}
