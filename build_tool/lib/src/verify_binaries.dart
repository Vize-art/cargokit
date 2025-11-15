import 'dart:io';

import 'package:ed25519_edwards/ed25519_edwards.dart';
import 'package:http/http.dart';

import 'artifacts_provider.dart';
import 'cargo.dart';
import 'crate_hash.dart';
import 'gh_cli.dart';
import 'options.dart';
import 'precompile_binaries.dart';
import 'target.dart';

class VerifyBinaries {
  VerifyBinaries({
    required this.manifestDir,
  });

  final String manifestDir;

  Future<void> run() async {
    final crateInfo = CrateInfo.load(manifestDir);

    final config = CargokitCrateOptions.load(manifestDir: manifestDir);
    final precompiledBinaries = config.precompiledBinaries;
    if (precompiledBinaries == null) {
      stdout.writeln('Crate does not support precompiled binaries.');
    } else {
      // Use version-based tags
      final version = crateInfo.version;
      final tagName = 'v$version';
      stdout.writeln('Version: $version (tag: $tagName)');

      // Still compute hash for informational purposes
      final crateHash = CrateHash.compute(manifestDir);
      stdout.writeln('Crate hash: $crateHash');

      if (precompiledBinaries.private) {
        // For private repositories, use gh CLI to verify
        await _verifyPrivateRepo(
          precompiledBinaries: precompiledBinaries,
          crateInfo: crateInfo,
          tagName: tagName,
        );
      } else {
        // For public repositories, use HTTP
        await _verifyPublicRepo(
          precompiledBinaries: precompiledBinaries,
          crateInfo: crateInfo,
          tagName: tagName,
        );
      }
    }
  }

  Future<void> _verifyPrivateRepo({
    required PrecompiledBinaries precompiledBinaries,
    required CrateInfo crateInfo,
    required String tagName,
  }) async {
    final repository = precompiledBinaries.repository!;

    stdout.writeln('Verifying private repository: $repository');

    // Check gh CLI setup
    try {
      await GhCliDownloader.validateSetup(repository: repository);
    } catch (e) {
      stdout.writeln('Error: $e');
      return;
    }

    // Check if release exists
    if (!await GhCliDownloader.releaseExists(repository: repository, tag: tagName)) {
      stdout.writeln('Release $tagName not found in $repository');
      return;
    }

    // Get list of assets
    final assets = await GhCliDownloader.listAssets(repository: repository, tag: tagName);
    stdout.writeln('Found ${assets.length} assets in release');

    for (final target in Target.all) {
      final message = 'Checking ${target.rust}...';
      stdout.write(message.padRight(40));
      stdout.flush();

      final requiredArtifacts = getArtifactNames(
        target: target,
        libraryName: crateInfo.packageName,
        remote: true,
      );

      bool ok = true;

      for (final artifact in requiredArtifacts) {
        final fileName = PrecompileBinaries.fileName(target, artifact);
        final signatureFileName = PrecompileBinaries.signatureFileName(target, artifact);

        if (!assets.contains(fileName)) {
          stdout.writeln('MISSING BINARY: $fileName');
          ok = false;
          break;
        }

        if (!assets.contains(signatureFileName)) {
          stdout.writeln('MISSING SIGNATURE: $signatureFileName');
          ok = false;
          break;
        }
      }

      if (ok) {
        stdout.writeln('OK');
      }
    }
  }

  Future<void> _verifyPublicRepo({
    required PrecompiledBinaries precompiledBinaries,
    required CrateInfo crateInfo,
    required String tagName,
  }) async {
    final prefix = precompiledBinaries.uriPrefix!;

    for (final target in Target.all) {
      final message = 'Checking ${target.rust}...';
      stdout.write(message.padRight(40));
      stdout.flush();

      final artifacts = getArtifactNames(
        target: target,
        libraryName: crateInfo.packageName,
        remote: true,
      );

      bool ok = true;

      for (final artifact in artifacts) {
        final fileName = PrecompileBinaries.fileName(target, artifact);
        final signatureFileName =
            PrecompileBinaries.signatureFileName(target, artifact);

        // Use version tag in URL instead of hash
        final url = Uri.parse('$prefix$tagName/$fileName');
        final signatureUrl =
            Uri.parse('$prefix$tagName/$signatureFileName');

        final signature = await get(signatureUrl);
        if (signature.statusCode != 200) {
          stdout.writeln('MISSING');
          ok = false;
          break;
        }
        final asset = await get(url);
        if (asset.statusCode != 200) {
          stdout.writeln('MISSING');
          ok = false;
          break;
        }

        if (!verify(precompiledBinaries.publicKey, asset.bodyBytes,
            signature.bodyBytes)) {
          stdout.writeln('INVALID SIGNATURE');
          ok = false;
        }
      }

      if (ok) {
        stdout.writeln('OK');
      }
    }
  }
}
