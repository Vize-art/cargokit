import 'dart:io';

import 'package:ed25519_edwards/ed25519_edwards.dart';
import 'package:http/http.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'builder.dart';
import 'crate_hash.dart';
import 'gh_cli.dart';
import 'options.dart';
import 'precompile_binaries.dart';
import 'rustup.dart';
import 'target.dart';

class Artifact {
  /// File system location of the artifact.
  final String path;

  /// Actual file name that the artifact should have in destination folder.
  final String finalFileName;

  AritifactType get type {
    if (finalFileName.endsWith('.dll') ||
        finalFileName.endsWith('.dll.lib') ||
        finalFileName.endsWith('.pdb') ||
        finalFileName.endsWith('.so') ||
        finalFileName.endsWith('.dylib')) {
      return AritifactType.dylib;
    } else if (finalFileName.endsWith('.lib') || finalFileName.endsWith('.a')) {
      return AritifactType.staticlib;
    } else {
      throw Exception('Unknown artifact type for $finalFileName');
    }
  }

  Artifact({
    required this.path,
    required this.finalFileName,
  });
}

final _log = Logger('artifacts_provider');

class ArtifactProvider {
  ArtifactProvider({
    required this.environment,
    required this.userOptions,
  });

  final BuildEnvironment environment;
  final CargokitUserOptions userOptions;

  Future<Map<Target, List<Artifact>>> getArtifacts(List<Target> targets) async {
    final result = await _getPrecompiledArtifacts(targets);

    final pendingTargets = List.of(targets);
    pendingTargets.removeWhere((element) => result.containsKey(element));

    if (pendingTargets.isEmpty) {
      return result;
    }

    final rustup = Rustup();
    for (final target in pendingTargets) {  // Only build missing targets
      final builder = RustBuilder(target: target, environment: environment);
      builder.prepare(rustup);
      _log.info('Building ${environment.crateInfo.packageName} for $target');
      final targetDir = await builder.build();
      // For local build accept both static and dynamic libraries.
      final artifactNames = <String>{
        ...getArtifactNames(
          target: target,
          libraryName: environment.crateInfo.packageName,
          aritifactType: AritifactType.dylib,
          remote: false,
        ),
        ...getArtifactNames(
          target: target,
          libraryName: environment.crateInfo.packageName,
          aritifactType: AritifactType.staticlib,
          remote: false,
        )
      };
      final artifacts = artifactNames
          .map((artifactName) => Artifact(
                path: path.join(targetDir, artifactName),
                finalFileName: artifactName,
              ))
          .where((element) => File(element.path).existsSync())
          .toList();
      result[target] = artifacts;
    }
    return result;
  }

  Future<Map<Target, List<Artifact>>> _getPrecompiledArtifacts(
      List<Target> targets) async {
    if (userOptions.usePrecompiledBinaries == false) {
      _log.info('Precompiled binaries are disabled');
      return {};
    }
    if (environment.crateOptions.precompiledBinaries == null) {
      _log.fine('Precompiled binaries not enabled for this crate');
      return {};
    }

    final start = Stopwatch()..start();

    // Get the version from Cargo.toml for version-based tags
    final version = environment.crateInfo.version;
    final tagName = 'v$version';
    _log.info('Looking for precompiled binaries for version $version (tag: $tagName)');

    // Still compute hash for cache directory and verification
    final crateHash = CrateHash.compute(environment.manifestDir,
        tempStorage: environment.targetTempDir);
    _log.fine(
        'Computed crate hash $crateHash in ${start.elapsedMilliseconds}ms');

    // Use version in the cache directory path for better organization
    final downloadedArtifactsDir =
        path.join(environment.targetTempDir, 'precompiled', version, crateHash);
    Directory(downloadedArtifactsDir).createSync(recursive: true);

    final res = <Target, List<Artifact>>{};

    for (final target in targets) {
      final requiredArtifacts = getArtifactNames(
        target: target,
        libraryName: environment.crateInfo.packageName,
        remote: true,
      );
      final artifactsForTarget = <Artifact>[];

      bool allFound = true;
      for (final artifact in requiredArtifacts) {
        final fileName = PrecompileBinaries.fileName(target, artifact);
        final downloadedPath = path.join(downloadedArtifactsDir, fileName);
        if (!File(downloadedPath).existsSync()) {
          final signatureFileName =
              PrecompileBinaries.signatureFileName(target, artifact);

          // Try downloading uncompressed artifact first
          await _tryDownloadArtifacts(
            version: version,
            fileName: fileName,
            signatureFileName: signatureFileName,
            finalPath: downloadedPath,
            compressed: false,
          );

          // If uncompressed not found, try compressed variant
          if (!File(downloadedPath).existsSync()) {
            final compressedFileName = PrecompileBinaries.fileName(target, artifact, compressed: true);
            final compressedSignatureFileName =
                PrecompileBinaries.signatureFileName(target, artifact, compressed: true);
            await _tryDownloadArtifacts(
              version: version,
              fileName: compressedFileName,
              signatureFileName: compressedSignatureFileName,
              finalPath: downloadedPath,
              compressed: true,
            );
          }
        }
        if (File(downloadedPath).existsSync()) {
          artifactsForTarget.add(Artifact(
            path: downloadedPath,
            finalFileName: artifact,
          ));
        } else {
          allFound = false;
          _log.warning('Missing precompiled artifact for $target: $artifact');
          break;
        }
      }

      // Only provide complete set of artifacts.
      if (allFound && artifactsForTarget.length == requiredArtifacts.length) {
        _log.fine('Found precompiled artifacts for $target');
        res[target] = artifactsForTarget;
      } else if (!allFound) {
        _log.info('Incomplete precompiled artifacts for $target - will build from source');
      }
    }

    return res;
  }

  /// Decompress a zstd-compressed file
  Future<void> _decompressFile(String compressedPath, String outputPath) async {
    final result = await Process.run('zstd', [
      '-d', // Decompress
      '-f', // Force overwrite
      compressedPath,
      '-o', // Output to specific path
      outputPath,
    ]);

    if (result.exitCode != 0) {
      throw Exception('zstd decompression failed: ${result.stderr}');
    }
  }

  static Future<Response> _get(Uri url, {Map<String, String>? headers}) async {
    int attempt = 0;
    const maxAttempts = 10;
    while (true) {
      try {
        return await get(url, headers: headers);
      } on SocketException catch (e) {
        // Try to detect reset by peer error and retry.
        if (attempt++ < maxAttempts &&
            (e.osError?.errorCode == 54 || e.osError?.errorCode == 10054)) {
          _log.severe(
              'Failed to download $url: $e, attempt $attempt of $maxAttempts, will retry...');
          await Future.delayed(Duration(seconds: 1));
          continue;
        } else {
          rethrow;
        }
      }
    }
  }

  Future<void> _tryDownloadArtifacts({
    required String version,
    required String fileName,
    required String signatureFileName,
    required String finalPath,
    required bool compressed,
  }) async {
    final precompiledBinaries = environment.crateOptions.precompiledBinaries!;

    if (precompiledBinaries.private) {
      // Use gh CLI for private repositories
      await _downloadViaGhCli(
        version: version,
        fileName: fileName,
        signatureFileName: signatureFileName,
        finalPath: finalPath,
        compressed: compressed,
      );
    } else {
      // Use HTTP for public repositories (backward compatibility)
      await _downloadViaHttp(
        version: version,
        fileName: fileName,
        signatureFileName: signatureFileName,
        finalPath: finalPath,
        compressed: compressed,
      );
    }
  }

  Future<void> _downloadViaGhCli({
    required String version,
    required String fileName,
    required String signatureFileName,
    required String finalPath,
    required bool compressed,
  }) async {
    final precompiledBinaries = environment.crateOptions.precompiledBinaries!;
    final repository = precompiledBinaries.repository!;
    final tagName = 'v$version';

    try {
      // Validate gh CLI setup
      await GhCliDownloader.validateSetup(repository: repository);

      // Create temporary directory for downloads
      final tempDir = Directory.systemTemp.createTempSync('cargokit_download_');

      try {
        // Download both the binary and signature files
        _log.fine('Downloading $fileName and $signatureFileName from $repository@$tagName via gh CLI');

        // Download the binary
        await GhCliDownloader.downloadAsset(
          repository: repository,
          tag: tagName,
          pattern: fileName,
          outputDir: tempDir.path,
        );

        // Download the signature
        await GhCliDownloader.downloadAsset(
          repository: repository,
          tag: tagName,
          pattern: signatureFileName,
          outputDir: tempDir.path,
        );

        // Read the downloaded files
        final binaryPath = path.join(tempDir.path, fileName);
        final signaturePath = path.join(tempDir.path, signatureFileName);

        if (!File(binaryPath).existsSync()) {
          _log.warning('Binary file not found after download: $binaryPath');
          return;
        }

        if (!File(signaturePath).existsSync()) {
          _log.warning('Signature file not found after download: $signaturePath');
          return;
        }

        final binaryBytes = File(binaryPath).readAsBytesSync();
        final signatureBytes = File(signaturePath).readAsBytesSync();

        // Verify signature (signature is of the compressed file if compressed)
        if (verify(precompiledBinaries.publicKey, binaryBytes, signatureBytes)) {
          if (compressed) {
            // Decompress the file
            _log.fine('Decompressing $fileName');
            await _decompressFile(binaryPath, finalPath);
          } else {
            File(finalPath).writeAsBytesSync(binaryBytes);
          }
          _log.fine('Successfully downloaded and verified $fileName');
        } else {
          _log.shout('Signature verification failed for $fileName! Ignoring binary.');
        }
      } finally {
        // Clean up temporary directory
        tempDir.deleteSync(recursive: true);
      }
    } catch (e) {
      if (e is AssetNotFoundException) {
        _log.warning('Precompiled binaries not available for version $version: ${e.message}');
      } else if (e is SetupException || e is AuthenticationException) {
        _log.severe('gh CLI setup issue: ${e.toString()}');
        _log.severe('Please ensure gh is installed and authenticated. Run: gh auth status');
      } else {
        _log.severe('Failed to download via gh CLI: $e');
      }
    }
  }

  Future<void> _downloadViaHttp({
    required String version,
    required String fileName,
    required String signatureFileName,
    required String finalPath,
    required bool compressed,
  }) async {
    final precompiledBinaries = environment.crateOptions.precompiledBinaries!;
    final prefix = precompiledBinaries.uriPrefix!;

    // Use version tag instead of hash in URL
    final tagName = 'v$version';
    final url = Uri.parse('$prefix$tagName/$fileName');
    final signatureUrl = Uri.parse('$prefix$tagName/$signatureFileName');

    _log.fine('Downloading signature from $signatureUrl');
    final signature = await _get(signatureUrl);
    if (signature.statusCode == 404) {
      _log.warning(
          'Precompiled binaries not available for version $version ($fileName)');
      return;
    }
    if (signature.statusCode != 200) {
      _log.severe(
          'Failed to download signature $signatureUrl: status ${signature.statusCode}');
      return;
    }
    _log.fine('Downloading binary from $url');
    final res = await _get(url);
    if (res.statusCode != 200) {
      _log.severe('Failed to download binary $url: status ${res.statusCode}');
      return;
    }
    if (verify(
        precompiledBinaries.publicKey, res.bodyBytes, signature.bodyBytes)) {
      if (compressed) {
        // Write compressed data to temporary file and decompress
        final tempDir = Directory.systemTemp.createTempSync('cargokit_decompress_');
        try {
          final compressedPath = path.join(tempDir.path, fileName);
          File(compressedPath).writeAsBytesSync(res.bodyBytes);
          _log.fine('Decompressing $fileName');
          await _decompressFile(compressedPath, finalPath);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      } else {
        File(finalPath).writeAsBytesSync(res.bodyBytes);
      }
      _log.fine('Successfully downloaded and verified $fileName');
    } else {
      _log.shout('Signature verification failed for $fileName! Ignoring binary.');
    }
  }
}

enum AritifactType {
  staticlib,
  dylib,
}

AritifactType artifactTypeForTarget(Target target) {
  if (target.darwinPlatform != null) {
    return AritifactType.staticlib;
  } else {
    return AritifactType.dylib;
  }
}

List<String> getArtifactNames({
  required Target target,
  required String libraryName,
  required bool remote,
  AritifactType? aritifactType,
}) {
  aritifactType ??= artifactTypeForTarget(target);
  if (target.darwinArch != null) {
    if (aritifactType == AritifactType.staticlib) {
      return ['lib$libraryName.a'];
    } else {
      return ['lib$libraryName.dylib'];
    }
  } else if (target.rust.contains('-windows-')) {
    if (aritifactType == AritifactType.staticlib) {
      return ['$libraryName.lib'];
    } else {
      return [
        '$libraryName.dll',
        '$libraryName.dll.lib',
        if (!remote) '$libraryName.pdb'
      ];
    }
  } else if (target.rust.contains('-linux-')) {
    if (aritifactType == AritifactType.staticlib) {
      return ['lib$libraryName.a'];
    } else {
      return ['lib$libraryName.so'];
    }
  } else {
    throw Exception("Unsupported target: ${target.rust}");
  }
}
