import 'dart:io';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart';
import 'package:github/github.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'artifacts_provider.dart';
import 'builder.dart';
import 'cargo.dart';
import 'crate_hash.dart';
import 'options.dart';
import 'rustup.dart';
import 'target.dart';
import 'version_validator.dart';

final _log = Logger('precompile_binaries');

class PrecompileBinaries {
  PrecompileBinaries({
    required this.privateKey,
    this.githubToken,
    this.repositorySlug,
    this.outputDir,
    required this.manifestDir,
    required this.targets,
    this.androidSdkLocation,
    this.androidNdkVersion,
    this.androidMinSdkVersion,
    this.tempDir,
    this.glibcVersion,
    this.compress = false,
  }) : assert(
          (repositorySlug != null && githubToken != null) || outputDir != null,
          'Either repositorySlug and githubToken must be provided for upload, '
          'or outputDir must be provided for local output',
        );

  final PrivateKey privateKey;
  final String? githubToken;
  final RepositorySlug? repositorySlug;
  final String? outputDir;
  final String manifestDir;
  final List<Target> targets;
  final String? androidSdkLocation;
  final String? androidNdkVersion;
  final int? androidMinSdkVersion;
  final String? tempDir;
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

    // Create temp directory for build and validation
    final tempDir = this.tempDir != null
        ? Directory(this.tempDir!)
        : Directory.systemTemp.createTempSync('precompiled_');

    tempDir.createSync(recursive: true);

    // Validate version hasn't been used with different content (only when uploading)
    if (repositorySlug != null) {
      final isValid = await VersionValidator.validate(
        manifestDir: manifestDir,
        tempDir: tempDir.path,
      );

      if (!isValid) {
        throw Exception(
          'Version validation failed. The version ${crateInfo.version} has been '
          'used before with different crate content. Please bump the version in '
          'Cargo.toml before publishing new binaries.',
        );
      }
    }

    // Still compute hash for integrity verification
    final hash = CrateHash.compute(manifestDir);
    _log.info('Computed crate hash: $hash');

    // Use version-based tag instead of hash-based
    final String tagName = 'v${crateInfo.version}';
    _log.info('Using version tag: $tagName');

    // Only fetch release if we're uploading to GitHub
    Release? release;
    RepositoriesService? repo;
    if (repositorySlug != null) {
      final github = GitHub(auth: Authentication.withToken(githubToken!));
      repo = github.repositories;
      release = await _getExistingRelease(
        repo: repo,
        repositorySlug: repositorySlug!,
        tagName: tagName,
        packageName: crateInfo.packageName,
        hash: hash,
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
      targetTempDir: tempDir.path,
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
        if (artifactNames.every((name) {
          final fileName = PrecompileBinaries.fileName(target, name, compressed: compress);
          return (release!.assets ?? []).any((e) => e.name == fileName);
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
        // Upload mode
        final assets = <CreateReleaseAsset>[];
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

          final create = CreateReleaseAsset(
            name: PrecompileBinaries.fileName(target, name, compressed: compress),
            contentType: "application/octet-stream",
            assetData: data,
          );
          final signature = sign(privateKey, data);
          final signatureCreate = CreateReleaseAsset(
            name: signatureFileName(target, name, compressed: compress),
            contentType: "application/octet-stream",
            assetData: signature,
          );
          bool verified = verify(public(privateKey), data, signature);
          if (!verified) {
            throw Exception('Signature verification failed');
          }
          assets.add(create);
          assets.add(signatureCreate);
        }
        _log.info('Uploading assets: ${assets.map((e) => e.name)}');
        for (final asset in assets) {
          // This seems to be failing on CI so do it one by one
          int retryCount = 0;
          while (true) {
            try {
              await repo!.uploadReleaseAssets(release!, [asset]);
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
    tempDir.deleteSync(recursive: true);
  }

  Future<Release> _getExistingRelease({
    required RepositoriesService repo,
    required RepositorySlug repositorySlug,
    required String tagName,
    required String packageName,
    required String hash,
  }) async {
    try {
      _log.info('Fetching release for tag $tagName');
      final release = await repo.getReleaseByTagName(repositorySlug, tagName);
      _log.info('Found existing release for tag $tagName');
      return release;
    } on ReleaseNotFound {
      throw Exception(
        'Release not found for tag $tagName. Please ensure the tag and release '
        'have been created by your publish script before running precompile-binaries. '
        'The tag should match the version in Cargo.toml (v${tagName.substring(1)}).'
      );
    }
  }
}
