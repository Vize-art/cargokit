import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'cargo.dart';
import 'crate_hash.dart';

final _log = Logger('version_validator');

/// Validates that version is properly bumped when crate content changes.
/// This helps ensure that different binary content isn't published under the same version.
class VersionValidator {
  static const String _versionCacheFile = '.cargokit_version_cache.json';

  /// Check if the version needs to be bumped based on content changes.
  /// Returns true if validation passes (version is OK), false if version needs bumping.
  static Future<bool> validate({
    required String manifestDir,
    required String tempDir,
  }) async {
    final crateInfo = CrateInfo.load(manifestDir);
    final currentVersion = crateInfo.version;
    final currentHash = CrateHash.compute(manifestDir, tempStorage: tempDir);

    _log.fine('Validating version $currentVersion with hash $currentHash');

    // Load the version cache
    final cacheFile = File(path.join(tempDir, _versionCacheFile));
    Map<String, dynamic> cache = {};

    if (cacheFile.existsSync()) {
      try {
        final content = cacheFile.readAsStringSync();
        cache = json.decode(content) as Map<String, dynamic>;
      } catch (e) {
        _log.warning('Failed to load version cache: $e');
        // Continue with empty cache
      }
    }

    // Check if this version was seen before
    if (cache.containsKey(currentVersion)) {
      final storedHash = cache[currentVersion];
      if (storedHash != currentHash) {
        _log.severe(
          'Version $currentVersion was previously built with different content!\n'
          'Previous hash: $storedHash\n'
          'Current hash: $currentHash\n'
          'Please bump the version in Cargo.toml to publish new content.',
        );
        return false;
      }
      _log.fine('Version $currentVersion matches stored hash');
      return true;
    }

    // Check if this hash was seen with a different version
    for (final entry in cache.entries) {
      if (entry.value == currentHash) {
        _log.warning(
          'Current crate content (hash: $currentHash) was previously '
          'published as version ${entry.key}, now trying to publish as $currentVersion.\n'
          'This might indicate an accidental version change or rollback.',
        );
        // This is a warning but not a hard failure - allow republishing same content
        // under different version (might be intentional for patches/fixes)
        break;
      }
    }

    // Store the new version-hash mapping
    cache[currentVersion] = currentHash;

    // Save the updated cache
    try {
      cacheFile.createSync(recursive: true);
      cacheFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(cache),
      );
      _log.fine('Updated version cache with $currentVersion -> $currentHash');
    } catch (e) {
      _log.warning('Failed to save version cache: $e');
      // Continue anyway - cache is just for validation
    }

    return true;
  }

  /// Clear the version cache (useful for CI/CD or when starting fresh)
  static void clearCache({required String tempDir}) {
    final cacheFile = File(path.join(tempDir, _versionCacheFile));
    if (cacheFile.existsSync()) {
      cacheFile.deleteSync();
      _log.info('Cleared version cache');
    }
  }

  /// Get information about cached versions
  static Map<String, String> getCachedVersions({required String tempDir}) {
    final cacheFile = File(path.join(tempDir, _versionCacheFile));
    if (!cacheFile.existsSync()) {
      return {};
    }

    try {
      final content = cacheFile.readAsStringSync();
      final cache = json.decode(content) as Map<String, dynamic>;
      return cache.map((key, value) => MapEntry(key, value.toString()));
    } catch (e) {
      _log.warning('Failed to load version cache: $e');
      return {};
    }
  }
}