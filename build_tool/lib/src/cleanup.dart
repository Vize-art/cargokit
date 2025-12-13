import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

final _log = Logger('cleanup');

/// Cleans up a cargo target directory, removing workspace artifacts while
/// keeping cached dependencies.
///
/// This implements the same logic as Swatinem/rust-cache to make the cache
/// suitable for reuse across CI runs.
Future<void> cleanupTargetDir(String targetDir, String packageName) async {
  _log.info('Cleaning up target directory: $targetDir');

  final dir = Directory(targetDir);
  if (!dir.existsSync()) {
    _log.fine('Target directory does not exist, nothing to clean');
    return;
  }

  // Walk through target dir - expect structure like:
  // targetDir/<triple>/<profile>/
  for (final tripleEntry in dir.listSync()) {
    if (tripleEntry is! Directory) continue;

    // Check if this is a nested target dir (has CACHEDIR.TAG or .rustc_info.json)
    final isNestedTarget = File(path.join(tripleEntry.path, 'CACHEDIR.TAG')).existsSync() ||
        File(path.join(tripleEntry.path, '.rustc_info.json')).existsSync();

    if (isNestedTarget) {
      await cleanupTargetDir(tripleEntry.path, packageName);
    } else {
      // This is a profile directory (debug/release)
      await _cleanProfileDir(tripleEntry.path, packageName);
    }
  }
}

/// Clean a profile directory (e.g., target/x86_64-unknown-linux-gnu/release/)
Future<void> _cleanProfileDir(String profileDir, String packageName) async {
  _log.fine('Cleaning profile directory: $profileDir');

  final dir = Directory(profileDir);
  if (!dir.existsSync()) return;

  final keepDirs = {'build', '.fingerprint', 'deps'};

  for (final entry in dir.listSync()) {
    final name = path.basename(entry.path);

    if (entry is Directory) {
      if (keepDirs.contains(name)) {
        // Clean inside these directories
        await _cleanSubDir(entry.path, packageName, name);
      } else {
        // Delete other directories (like incremental/)
        _log.fine('Deleting directory: ${entry.path}');
        await entry.delete(recursive: true);
      }
    } else if (entry is File) {
      // Delete files at profile level
      _log.fine('Deleting file: ${entry.path}');
      await entry.delete();
    }
  }
}

/// Clean a subdirectory (build/, .fingerprint/, or deps/)
Future<void> _cleanSubDir(
    String dirPath, String packageName, String dirType) async {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return;

  // Convert package name for matching (- becomes _)
  final normalizedName = packageName.replaceAll('-', '_');

  for (final entry in dir.listSync()) {
    final name = path.basename(entry.path);

    // Strip trailing hash (e.g., "mypackage-a1b2c3d4" -> "mypackage")
    String baseName = name;
    final hashIdx = name.lastIndexOf('-');
    if (hashIdx != -1) {
      baseName = name.substring(0, hashIdx);
    }

    // Check if this entry belongs to the workspace package
    bool isWorkspaceArtifact = false;

    if (dirType == 'deps') {
      // For deps/, check against package name and lib{package}
      final normalizedBaseName = baseName.replaceAll('-', '_');
      isWorkspaceArtifact = normalizedBaseName == normalizedName ||
          normalizedBaseName == 'lib$normalizedName';
    } else {
      // For build/ and .fingerprint/, match package name directly
      isWorkspaceArtifact = baseName == packageName ||
          baseName.replaceAll('-', '_') == normalizedName;
    }

    if (isWorkspaceArtifact) {
      _log.fine('Deleting workspace artifact: ${entry.path}');
      if (entry is Directory) {
        await entry.delete(recursive: true);
      } else if (entry is File) {
        await entry.delete();
      }
    }
  }
}
