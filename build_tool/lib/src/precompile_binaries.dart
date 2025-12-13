import 'dart:io';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart';
import 'package:github/github.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'artifacts_provider.dart';
import 'builder.dart';
import 'cargo.dart';
import 'cleanup.dart';
import 'options.dart';
import 'rustup.dart';
import 'target.dart';

final _log = Logger('precompile_binaries');

class PrecompileBinaries {
  PrecompileBinaries({
    required this.privateKey,
    this.repositorySlug,
    this.outputDir,
    required this.manifestDir,
    required this.targets,
    this.androidSdkLocation,
    this.androidNdkVersion,
    this.androidMinSdkVersion,
    this.tempDir,
    this.cacheDir,
    this.glibcVersion,
    this.compress = false,
  }) : assert(
          repositorySlug != null || outputDir != null,
          'Either repositorySlug must be provided for upload, '
          'or outputDir must be provided for local output',
        );

  final PrivateKey privateKey;
  final RepositorySlug? repositorySlug;
  final String? outputDir;
  final String manifestDir;
  final List<Target> targets;
  final String? androidSdkLocation;
  final String? androidNdkVersion;
  final int? androidMinSdkVersion;
  final String? tempDir;
  final String? cacheDir;
  final String? glibcVersion;
  final bool compress;

  static String fileName(Target target, String name, {bool compressed = false}) {
    final base = '${target.rust}_$name';
    return compressed ? '$base.zst' : base;
  }

  static String signatureFileName(Target target, String name, {bool compressed = false}) {
    return '${fileName(target, name, compressed: compressed)}.sig';
  }

  /// Compress a file using zstd
  Future<Uint8List> _compressFile(String filePath) async {
    final outputPath = '$filePath.zst';

    // Run zstd to compress the file
    final result = await Process.run('zstd', [
      '-f', // Force overwrite
      '--rm', // Remove source file after compression
      filePath,
    ]);

    if (result.exitCode != 0) {
      throw Exception('zstd compression failed: ${result.stderr}');
    }

    final compressedFile = File(outputPath);
    if (!compressedFile.existsSync()) {
      throw Exception('Compressed file not found: $outputPath');
    }

    return Uint8List.fromList(compressedFile.readAsBytesSync());
  }

  Future<void> run() async {
    // Check if zstd is available when compression is enabled
    if (compress) {
      try {
        final result = await Process.run('zstd', ['--version']);
        if (result.exitCode != 0) {
          throw Exception('zstd binary is not available');
        }
        _log.info('Using zstd for compression');
      } catch (e) {
        throw Exception(
          'Compression enabled but zstd is not available in PATH. '
          'Please install zstd: https://github.com/facebook/zstd'
        );
      }
    }

    final crateInfo = CrateInfo.load(manifestDir);

    final targets = List.of(this.targets);
    if (targets.isEmpty) {
      targets.addAll([
        ...Target.buildableTargets(),
        if (androidSdkLocation != null) ...Target.androidTargets(),
      ]);
    }

    _log.info('Precompiling binaries for $targets${compress ? ' (compressed)' : ''}');

    // Determine build directory
    final Directory buildDir;
    final bool useCache = cacheDir != null;

    if (useCache) {
      buildDir = Directory(cacheDir!);
    } else if (tempDir != null) {
      buildDir = Directory(tempDir!);
    } else {
      buildDir = Directory.systemTemp.createTempSync('precompiled_');
    }

    buildDir.createSync(recursive: true);

    // Use version-based tag
    final String tagName = 'v${crateInfo.version}';
    _log.info('Using version tag: $tagName');

    // Validate gh CLI is available when uploading
    if (repositorySlug != null) {
      try {
        final result = await Process.run('gh', ['--version']);
        if (result.exitCode != 0) {
          throw Exception('gh CLI is not available');
        }
      } catch (e) {
        throw Exception(
          'gh CLI is required for uploading to GitHub releases but is not available in PATH. '
          'Please install gh: https://cli.github.com'
        );
      }

      // Validate release exists
      await _validateReleaseExists(
        repositorySlug: repositorySlug!,
        tagName: tagName,
      );
    } else {
      // Create output directory if it doesn't exist
      final outputDirectory = Directory(outputDir!);
      if (!outputDirectory.existsSync()) {
        _log.info('Creating output directory: $outputDir');
        outputDirectory.createSync(recursive: true);
      }
    }

    final crateOptions = CargokitCrateOptions.load(
      manifestDir: manifestDir,
    );

    final buildEnvironment = BuildEnvironment(
      configuration: BuildConfiguration.release,
      crateOptions: crateOptions,
      targetTempDir: buildDir.path,
      manifestDir: manifestDir,
      crateInfo: crateInfo,
      isAndroid: androidSdkLocation != null,
      androidSdkPath: androidSdkLocation,
      androidNdkVersion: androidNdkVersion,
      androidMinSdkVersion: androidMinSdkVersion,
      glibcVersion: glibcVersion,
    );

    final rustup = Rustup();

    for (final target in targets) {
      final artifactNames = getArtifactNames(
        target: target,
        libraryName: crateInfo.packageName,
        remote: true,
      );

      // Only check for existing artifacts if we're uploading
      if (repositorySlug != null) {
        final existingAssets = await _listReleaseAssets(
          repositorySlug: repositorySlug!,
          tagName: tagName,
        );

        if (artifactNames.every((name) {
          final fileName = PrecompileBinaries.fileName(target, name, compressed: compress);
          return existingAssets.contains(fileName);
        })) {
          _log.info("All artifacts for $target already exist - skipping");
          continue;
        }
      }

      _log.info('Building for $target');

      final builder =
          RustBuilder(target: target, environment: buildEnvironment);
      builder.prepare(rustup);
      final res = await builder.build();

      if (repositorySlug != null) {
        // Upload mode using gh CLI
        // Create temporary directory for assets to upload
        final uploadTempDir = Directory.systemTemp.createTempSync('cargokit_upload_');
        try {
          final filesToUpload = <String>[];

          for (final name in artifactNames) {
            final file = File(path.join(res, name));
            if (!file.existsSync()) {
              throw Exception('Missing artifact: ${file.path}');
            }

            // Read and optionally compress the data
            Uint8List data;
            if (compress) {
              _log.info('Compressing ${file.path}');
              data = await _compressFile(file.path);
            } else {
              data = Uint8List.fromList(file.readAsBytesSync());
            }

            final signature = sign(privateKey, data);

            bool verified = verify(public(privateKey), data, signature);
            if (!verified) {
              throw Exception('Signature verification failed');
            }

            // Write artifact to temp directory
            final artifactFileName = PrecompileBinaries.fileName(target, name, compressed: compress);
            final artifactPath = path.join(uploadTempDir.path, artifactFileName);
            File(artifactPath).writeAsBytesSync(data);
            filesToUpload.add(artifactPath);

            // Write signature to temp directory
            final signatureFileName = PrecompileBinaries.signatureFileName(target, name, compressed: compress);
            final signaturePath = path.join(uploadTempDir.path, signatureFileName);
            File(signaturePath).writeAsBytesSync(signature);
            filesToUpload.add(signaturePath);
          }

          // Upload all files using gh CLI
          _log.info('Uploading ${filesToUpload.length} assets via gh CLI: ${filesToUpload.map((f) => path.basename(f)).join(', ')}');

          int retryCount = 0;
          while (true) {
            try {
              final result = await Process.run('gh', [
                'release',
                'upload',
                tagName,
                '--repo',
                repositorySlug!.fullName,
                '--clobber', // Overwrite existing assets if they exist
                ...filesToUpload,
              ]);

              if (result.exitCode != 0) {
                throw Exception('gh release upload failed: ${result.stderr}');
              }

              _log.info('Successfully uploaded assets');
              break;
            } on Exception catch (e) {
              if (retryCount == 10) {
                rethrow;
              }
              ++retryCount;
              _log.shout(
                  'Upload failed (attempt $retryCount, will retry): ${e.toString()}');
              await Future.delayed(Duration(seconds: 2));
            }
          }
        } finally {
          // Clean up temporary upload directory
          uploadTempDir.deleteSync(recursive: true);
        }
      } else {
        // Output directory mode
        _log.info('Copying artifacts to output directory: $outputDir');
        for (final name in artifactNames) {
          final file = File(path.join(res, name));
          if (!file.existsSync()) {
            throw Exception('Missing artifact: ${file.path}');
          }

          // Read and optionally compress the data
          Uint8List data;
          if (compress) {
            _log.info('Compressing ${file.path}');
            data = await _compressFile(file.path);
          } else {
            data = Uint8List.fromList(file.readAsBytesSync());
          }

          final signature = sign(privateKey, data);

          bool verified = verify(public(privateKey), data, signature);
          if (!verified) {
            throw Exception('Signature verification failed');
          }

          // Copy artifact to output directory
          final outputFileName = PrecompileBinaries.fileName(target, name, compressed: compress);
          final outputFile = File(path.join(outputDir!, outputFileName));
          outputFile.writeAsBytesSync(data);
          _log.info('Copied: $outputFileName');

          // Copy signature to output directory
          final signatureOutputFileName = signatureFileName(target, name, compressed: compress);
          final signatureOutputFile = File(path.join(outputDir!, signatureOutputFileName));
          signatureOutputFile.writeAsBytesSync(signature);
          _log.info('Copied: $signatureOutputFileName');
        }
      }
    }

    _log.info('Cleaning up');
    if (useCache) {
      await cleanupTargetDir(buildDir.path, crateInfo.packageName);
    } else {
      buildDir.deleteSync(recursive: true);
    }
  }

  Future<void> _validateReleaseExists({
    required RepositorySlug repositorySlug,
    required String tagName,
  }) async {
    _log.info('Validating release exists for tag $tagName');

    final result = await Process.run('gh', [
      'release',
      'view',
      tagName,
      '--repo',
      repositorySlug.fullName,
    ]);

    if (result.exitCode != 0) {
      throw Exception(
        'Release not found for tag $tagName. Please ensure the tag and release '
        'have been created by your publish script before running precompile-binaries. '
        'The tag should match the version in Cargo.toml (v${tagName.substring(1)}).\n'
        'Error: ${result.stderr}'
      );
    }

    _log.info('Found existing release for tag $tagName');
  }

  Future<List<String>> _listReleaseAssets({
    required RepositorySlug repositorySlug,
    required String tagName,
  }) async {
    final result = await Process.run('gh', [
      'release',
      'view',
      tagName,
      '--repo',
      repositorySlug.fullName,
      '--json',
      'assets',
      '--jq',
      '.assets[].name',
    ]);

    if (result.exitCode != 0) {
      _log.warning('Failed to list release assets: ${result.stderr}');
      return [];
    }

    final output = (result.stdout as String).trim();
    if (output.isEmpty) {
      return [];
    }

    return output.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }
}
