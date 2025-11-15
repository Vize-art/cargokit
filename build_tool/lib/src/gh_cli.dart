import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

final _log = Logger('gh_cli');

/// Handles authenticated operations with GitHub using the gh CLI tool.
/// This is required for private repositories where simple HTTP downloads won't work.
class GhCliDownloader {
  /// Check if gh CLI is installed and available in PATH
  static Future<bool> isInstalled() async {
    try {
      final result = await Process.run('which', ['gh']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Check if gh CLI is authenticated with GitHub
  static Future<bool> isAuthenticated() async {
    try {
      final result = await Process.run('gh', ['auth', 'status']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Get the current authenticated user
  static Future<String?> getCurrentUser() async {
    try {
      final result = await Process.run('gh', ['api', 'user', '--jq', '.login']);
      if (result.exitCode == 0) {
        return result.stdout.toString().trim();
      }
    } catch (e) {
      _log.warning('Failed to get current user: $e');
    }
    return null;
  }

  /// Check if a release exists for the given repository and tag
  static Future<bool> releaseExists({
    required String repository,
    required String tag,
  }) async {
    try {
      final result = await Process.run('gh', [
        'release',
        'view',
        tag,
        '--repo',
        repository,
      ]);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Download a release asset matching the pattern to the output directory
  static Future<void> downloadAsset({
    required String repository,
    required String tag,
    required String pattern,
    required String outputDir,
  }) async {
    _log.fine('Downloading asset from $repository@$tag: $pattern');

    // Ensure output directory exists
    Directory(outputDir).createSync(recursive: true);

    final result = await Process.run('gh', [
      'release',
      'download',
      tag,
      '--repo',
      repository,
      '--pattern',
      pattern,
      '--dir',
      outputDir,
    ]);

    if (result.exitCode != 0) {
      final stderr = result.stderr.toString();
      if (stderr.contains('could not find any assets matching')) {
        throw AssetNotFoundException(
          'No assets matching pattern "$pattern" found in release $tag of $repository',
        );
      } else if (stderr.contains('release not found')) {
        throw ReleaseNotFoundException(
          'Release $tag not found in repository $repository',
        );
      } else if (stderr.contains('HTTP 404') || stderr.contains('Not Found')) {
        throw RepositoryNotFoundException(
          'Repository $repository not found or not accessible. '
          'Ensure you have access and are authenticated with: gh auth status',
        );
      } else if (stderr.contains('authentication') || stderr.contains('unauthorized')) {
        throw AuthenticationException(
          'Authentication failed. Please run: gh auth login',
        );
      }
      throw Exception('Failed to download asset: $stderr');
    }

    _log.fine('Successfully downloaded asset: $pattern');
  }

  /// Download multiple assets at once
  static Future<void> downloadAssets({
    required String repository,
    required String tag,
    required List<String> patterns,
    required String outputDir,
  }) async {
    for (final pattern in patterns) {
      await downloadAsset(
        repository: repository,
        tag: tag,
        pattern: pattern,
        outputDir: outputDir,
      );
    }
  }

  /// List all assets in a release
  static Future<List<String>> listAssets({
    required String repository,
    required String tag,
  }) async {
    final result = await Process.run('gh', [
      'release',
      'view',
      tag,
      '--repo',
      repository,
      '--json',
      'assets',
      '--jq',
      '.assets[].name',
    ]);

    if (result.exitCode != 0) {
      final stderr = result.stderr.toString();
      if (stderr.contains('release not found')) {
        throw ReleaseNotFoundException(
          'Release $tag not found in repository $repository',
        );
      }
      throw Exception('Failed to list assets: $stderr');
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      return [];
    }

    return output.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
  }

  /// Check if specific assets exist in a release
  static Future<bool> assetExists({
    required String repository,
    required String tag,
    required String assetName,
  }) async {
    try {
      final assets = await listAssets(repository: repository, tag: tag);
      return assets.contains(assetName);
    } catch (e) {
      return false;
    }
  }

  /// Get release information
  static Future<Map<String, dynamic>?> getReleaseInfo({
    required String repository,
    required String tag,
  }) async {
    try {
      final result = await Process.run('gh', [
        'release',
        'view',
        tag,
        '--repo',
        repository,
        '--json',
        'tagName,name,body,createdAt,publishedAt,isDraft,isPrerelease',
      ]);

      if (result.exitCode == 0) {
        return json.decode(result.stdout.toString());
      }
    } catch (e) {
      _log.warning('Failed to get release info: $e');
    }
    return null;
  }

  /// Validate that gh CLI is properly set up for use
  static Future<void> validateSetup({required String repository}) async {
    // Check if gh is installed
    if (!await isInstalled()) {
      throw SetupException(
        'gh CLI is not installed. Please install it from: https://cli.github.com\n'
        'Or install via package manager:\n'
        '  - macOS: brew install gh\n'
        '  - Linux: See https://github.com/cli/cli/blob/trunk/docs/install_linux.md\n'
        '  - Windows: winget install --id GitHub.cli',
      );
    }

    // Check if gh is authenticated
    if (!await isAuthenticated()) {
      throw SetupException(
        'gh CLI is not authenticated. Please run: gh auth login\n'
        'and follow the prompts to authenticate with GitHub.',
      );
    }

    // Optionally check if we can access the repository
    final user = await getCurrentUser();
    if (user != null) {
      _log.fine('Authenticated as: $user');
    }

    // Try to check if repository is accessible
    try {
      final result = await Process.run('gh', [
        'api',
        'repos/$repository',
        '--silent',
      ]);
      if (result.exitCode != 0) {
        final stderr = result.stderr.toString();
        if (stderr.contains('HTTP 404')) {
          throw SetupException(
            'Repository $repository not found or not accessible. '
            'Ensure you have read access to this repository.',
          );
        }
      }
    } catch (e) {
      if (e is SetupException) rethrow;
      // Ignore other errors as the repository check is optional
      _log.fine('Could not verify repository access: $e');
    }
  }
}

// Custom exception classes for better error handling
class GhCliException implements Exception {
  final String message;
  GhCliException(this.message);

  @override
  String toString() => message;
}

class SetupException extends GhCliException {
  SetupException(String message) : super(message);
}

class AuthenticationException extends GhCliException {
  AuthenticationException(String message) : super(message);
}

class RepositoryNotFoundException extends GhCliException {
  RepositoryNotFoundException(String message) : super(message);
}

class ReleaseNotFoundException extends GhCliException {
  ReleaseNotFoundException(String message) : super(message);
}

class AssetNotFoundException extends GhCliException {
  AssetNotFoundException(String message) : super(message);
}