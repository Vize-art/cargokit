# Cargokit Version-Based Tagging Implementation Plan

## Executive Summary

### Current Situation
Cargokit currently uses hash-based tags for precompiled binary releases (e.g., `precompiled_b1c02d9257046ad6e1560ff34ea934f5`). This approach is incompatible with Flutter's git dependency model that expects semantic version tags.

### Requirements
Transform cargokit to support version-based tags (`v{{version}}`) for a closed-source Rust library (`rustpowered`) that will be consumed by Flutter developers through git dependencies.

### Key Constraints
1. **Private Repository**: Rustpowered is closed-source, requiring authenticated access
2. **Flutter Compatibility**: Must work with Flutter's `pubspec.yaml` git dependency format:
   ```yaml
   rustpowered:
     git:
       url: git@github.com:Vize-art/rustpowered.git
       path: flutter
       tag_pattern: v{{version}}
   ```
3. **Version Management**: External publish script handles tag creation; cargokit only attaches assets
4. **Developer Experience**: Developers must be able to use the library without compiling Rust

## Detailed Requirements Analysis

### What Was Requested

1. **Version-Based Tags Instead of Hash-Based**
   - Move from `precompiled_<hash>` to `v<version>` format
   - Version determined from `Cargo.toml`'s `package.version` field
   - Compatible with Flutter's `tag_pattern: v{{version}}` convention

2. **External Tag Management**
   - Cargokit should NOT create git tags
   - External publish script creates tags
   - Cargokit only creates/updates GitHub releases for existing tags
   - Upload precompiled binaries as release assets

3. **Private Repository Support**
   - Current implementation assumes public repositories (unauthenticated HTTP downloads)
   - New implementation must support private repositories
   - Use `gh` CLI for authenticated operations
   - Developer's responsibility to be logged in with appropriate access

4. **Version Enforcement**
   - Require version bump when crate content changes
   - Fail the build if content changed but version wasn't incremented
   - No automatic version incrementing

5. **Clean Break**
   - No backward compatibility with hash-based system
   - Complete switch to version-based approach

## Technical Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────┐
│                   Publishing Flow                        │
├─────────────────────────────────────────────────────────┤
│ 1. External Script → Creates git tag (v1.2.3)           │
│ 2. External Script → Creates GitHub release             │
│ 3. Cargokit → Reads version from Cargo.toml             │
│ 4. Cargokit → Finds existing release by tag             │
│ 5. Cargokit → Uploads binary assets + signatures        │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                   Consumption Flow                       │
├─────────────────────────────────────────────────────────┤
│ 1. Developer → flutter pub get (refs rustpowered)       │
│ 2. Cargokit → Reads version from Cargo.toml             │
│ 3. Cargokit → Constructs tag (v1.2.3)                   │
│ 4. Cargokit → Uses gh CLI to download assets            │
│ 5. Cargokit → Verifies signatures                       │
│ 6. Cargokit → Provides binaries to Flutter build        │
└─────────────────────────────────────────────────────────┘
```

### Key Components to Modify

| Component | File | Purpose | Changes Required |
|-----------|------|---------|------------------|
| CrateInfo | `cargo.dart` | Parse Cargo.toml | Add version extraction |
| PrecompileBinaries | `precompile_binaries.dart` | Upload assets | Use version tags, don't create tags |
| ArtifactProvider | `artifacts_provider.dart` | Download binaries | Use gh CLI for private repos |
| Configuration | `options.dart` | Config parsing | Add repository and private flags |
| GhCliDownloader | New file | gh CLI integration | Handle authenticated downloads |

## Implementation Phases

### Phase 1: Core Version Support
**Goal**: Establish version-based tagging foundation

#### 1.1 Extend CrateInfo Class
- **File**: `build_tool/lib/src/cargo.dart`
- **Changes**:
  ```dart
  class CrateInfo {
    final String packageName;
    final String version;  // NEW

    static CrateInfo parseManifest(String manifest) {
      // Extract package.version from TOML
    }
  }
  ```
- **Validation**: Ensure version follows semantic versioning

#### 1.2 Update Tag Generation
- **File**: `build_tool/lib/src/precompile_binaries.dart`
- **Changes**:
  ```dart
  // OLD: final String tagName = 'precompiled_$hash';
  // NEW: final String tagName = 'v${crateInfo.version}';
  ```
- **Keep hash**: Still compute for integrity verification, not for tagging

### Phase 2: Private Repository Support

#### 2.1 Create gh CLI Integration
- **New File**: `build_tool/lib/src/gh_cli.dart`
- **Class Structure**:
  ```dart
  class GhCliDownloader {
    Future<bool> isAuthenticated();
    Future<bool> releaseExists(String repo, String tag);
    Future<void> downloadAsset(String repo, String tag, String pattern, String outputDir);
    Future<List<String>> listAssets(String repo, String tag);
  }
  ```
- **Error Handling**: Clear messages for authentication failures

#### 2.2 Update Download Logic
- **File**: `build_tool/lib/src/artifacts_provider.dart`
- **Changes**:
  - Detect repository type (private/public)
  - Route private repo downloads through gh CLI
  - Maintain signature verification
  - Example flow:
    ```dart
    if (crateOptions.precompiledBinaries.private) {
      await _downloadViaGhCli(version, artifact);
    } else {
      await _downloadViaHttp(version, artifact);  // Optional backward compat
    }
    ```

### Phase 3: Configuration Updates

#### 3.1 Extend Configuration Schema
- **File**: `build_tool/lib/src/options.dart`
- **New Configuration**:
  ```yaml
  precompiled_binaries:
    repository: Vize-art/rustpowered  # Required: owner/name format
    private: true                      # Required: triggers gh CLI usage
    public_key: abc123...             # Required: for signature verification
    # url_prefix: removed for private repos
  ```

#### 3.2 Update Command Line Interface
- **File**: `build_tool/lib/src/build_tool.dart`
- **Changes to PrecompileBinariesCommand**:
  - Remove tag creation logic
  - Validate tag exists before uploading
  - Better error messages:
    ```
    Error: Tag v1.2.3 does not exist. Please create the tag and release first.
    ```

### Phase 4: Validation & Safety

#### 4.1 Version Change Detection
- **Implementation**:
  - Compare current version with crate hash
  - Store version->hash mapping
  - Fail if hash changed but version didn't:
    ```
    Error: Crate content changed but version (1.2.3) was not bumped.
    Please increment the version in Cargo.toml.
    ```

#### 4.2 gh CLI Availability
- **Checks**:
  ```dart
  // Check gh installation
  if (!await GhCliDownloader.isInstalled()) {
    throw "gh CLI not found. Install from: https://cli.github.com";
  }

  // Check authentication
  if (!await GhCliDownloader.isAuthenticated()) {
    throw "Not authenticated. Run: gh auth login";
  }
  ```

## Migration Guide

### For CI/CD Pipeline

**Before (Hash-based)**:
```yaml
- name: Precompile
  run: dart run build_tool precompile-binaries
  # Creates tag and release automatically
```

**After (Version-based)**:
```yaml
- name: Create Release
  run: |
    VERSION=$(grep "^version" rust/Cargo.toml | cut -d'"' -f2)
    git tag "v$VERSION"
    git push origin "v$VERSION"
    gh release create "v$VERSION" --title "Release v$VERSION"

- name: Upload Binaries
  run: dart run build_tool precompile-binaries
  # Only uploads to existing release
```

### For Developers

**Setup**:
```bash
# One-time setup
gh auth login
```

**Usage** (unchanged):
```bash
flutter pub get
flutter run
# Binaries downloaded automatically via gh CLI
```

### For Configuration

**Old cargokit.yaml**:
```yaml
precompiled_binaries:
  url_prefix: https://github.com/owner/repo/releases/download/precompiled_
  public_key: 3a257ef1c7d72d84...
```

**New cargokit.yaml**:
```yaml
precompiled_binaries:
  repository: Vize-art/rustpowered
  private: true
  public_key: 3a257ef1c7d72d84...
```

## Risk Analysis & Mitigation

### Risk 1: Breaking Existing Workflows
- **Impact**: High - All existing hash-based deployments break
- **Mitigation**: Clear migration documentation, version the changes

### Risk 2: Developer Authentication Issues
- **Impact**: Medium - Developers can't download binaries
- **Mitigation**: Clear error messages, authentication guide, fallback to local build

### Risk 3: Version Conflicts
- **Impact**: Medium - Mismatched versions cause build failures
- **Mitigation**: Strong validation, clear error messages, version bump enforcement

### Risk 4: gh CLI Dependency
- **Impact**: Low - Additional tool requirement
- **Mitigation**: Installation instructions, availability checks, consider fallback

## Success Criteria

1. ✅ Flutter developers can use `tag_pattern: v{{version}}` in pubspec.yaml
2. ✅ Private repository binaries download with gh CLI authentication
3. ✅ Version from Cargo.toml drives the entire process
4. ✅ External scripts control tag/release creation
5. ✅ Signature verification maintained for security
6. ✅ Clear error messages for common failure scenarios
7. ✅ No manual token management required

## Timeline Estimate

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Phase 1: Core Version Support | 2-3 hours | None |
| Phase 2: Private Repo Support | 3-4 hours | Phase 1 |
| Phase 3: Configuration Updates | 2-3 hours | Phase 2 |
| Phase 4: Validation & Safety | 2-3 hours | Phase 3 |
| Testing & Documentation | 2-3 hours | All phases |
| **Total** | **11-16 hours** | |

## Next Steps

1. **Review & Approve**: Ensure this plan meets all requirements
2. **Implementation**: Execute phases sequentially
3. **Testing**: Validate with actual rustpowered repository
4. **Documentation**: Update cargokit docs for new workflow
5. **Migration**: Assist with transitioning existing setup

## Appendix: Example Code Changes

### Example 1: Version Extraction
```dart
// In cargo.dart
class CrateInfo {
  CrateInfo({
    required this.packageName,
    required this.version,
  });

  final String packageName;
  final String version;

  static CrateInfo parseManifest(String manifest, {String? fileName}) {
    final toml = TomlDocument.parse(manifest);
    final package = toml.toMap()['package'];
    if (package == null) {
      throw ManifestException('Missing package section', fileName: fileName);
    }
    final name = package['name'];
    if (name == null) {
      throw ManifestException('Missing package name', fileName: fileName);
    }
    final version = package['version'];
    if (version == null) {
      throw ManifestException('Missing package version', fileName: fileName);
    }
    return CrateInfo(
      packageName: name,
      version: version,
    );
  }
}
```

### Example 2: gh CLI Download
```dart
// In gh_cli.dart
class GhCliDownloader {
  Future<void> downloadAsset({
    required String repository,
    required String tag,
    required String pattern,
    required String outputDir,
  }) async {
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
      throw Exception('Failed to download asset: ${result.stderr}');
    }
  }
}
```

### Example 3: Configuration Structure
```dart
// In options.dart
class PrecompiledBinaries {
  final String repository;     // NEW: owner/repo format
  final bool private;          // NEW: triggers gh CLI
  final PublicKey publicKey;   // KEPT: for verification
  final String? uriPrefix;     // OPTIONAL: for public repos only

  PrecompiledBinaries({
    required this.repository,
    required this.private,
    required this.publicKey,
    this.uriPrefix,
  });
}
```