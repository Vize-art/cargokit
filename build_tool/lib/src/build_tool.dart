import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart';
import 'package:github/github.dart';
import 'package:hex/hex.dart';
import 'package:logging/logging.dart';

import 'build_cmake.dart';
import 'build_gradle.dart';
import 'build_pod.dart';
import 'logging.dart';
import 'options.dart';
import 'precompile_binaries.dart';
import 'target.dart';
import 'util.dart';
import 'verify_binaries.dart';

final log = Logger('build_tool');

abstract class BuildCommand extends Command {
  Future<void> runBuildCommand(CargokitUserOptions options);

  @override
  Future<void> run() async {
    final options = CargokitUserOptions.load();

    if (options.verboseLogging ||
        Platform.environment['CARGOKIT_VERBOSE'] == '1') {
      enableVerboseLogging();
    }

    await runBuildCommand(options);
  }
}

class BuildPodCommand extends BuildCommand {
  @override
  final name = 'build-pod';

  @override
  final description = 'Build cocoa pod library';

  @override
  Future<void> runBuildCommand(CargokitUserOptions options) async {
    final build = BuildPod(userOptions: options);
    await build.build();
  }
}

class BuildGradleCommand extends BuildCommand {
  @override
  final name = 'build-gradle';

  @override
  final description = 'Build android library';

  @override
  Future<void> runBuildCommand(CargokitUserOptions options) async {
    final build = BuildGradle(userOptions: options);
    await build.build();
  }
}

class BuildCMakeCommand extends BuildCommand {
  @override
  final name = 'build-cmake';

  @override
  final description = 'Build CMake library';

  @override
  Future<void> runBuildCommand(CargokitUserOptions options) async {
    final build = BuildCMake(userOptions: options);
    await build.build();
  }
}

class GenKeyCommand extends Command {
  @override
  final name = 'gen-key';

  @override
  final description = 'Generate key pair for signing precompiled binaries';

  @override
  void run() {
    final kp = generateKey();
    final private = HEX.encode(kp.privateKey.bytes);
    final public = HEX.encode(kp.publicKey.bytes);
    print("Private Key: $private");
    print("Public Key: $public");
  }
}

class PrecompileBinariesCommand extends Command {
  PrecompileBinariesCommand() {
    argParser
      ..addOption(
        'repository',
        help: 'Github repository slug in format owner/name.\n'
            'Used for uploading binaries to GitHub releases.\n'
            'Mutually exclusive with --output.',
      )
      ..addOption(
        'output',
        help: 'Directory to move built artifacts to.\n'
            'If directory does not exist, it will be created.\n'
            'Mutually exclusive with --repository.',
      )
      ..addOption(
        'manifest-dir',
        mandatory: true,
        help: 'Directory containing Cargo.toml',
      )
      ..addMultiOption('target',
          help: 'Rust target triple of artifact to build.\n'
              'Can be specified multiple times or omitted in which case\n'
              'all targets for current platform will be built.')
      ..addOption(
        'android-sdk-location',
        help: 'Location of Android SDK (if available)',
      )
      ..addOption(
        'android-ndk-version',
        help: 'Android NDK version (if available)',
      )
      ..addOption(
        'android-min-sdk-version',
        help: 'Android minimum rquired version (if available)',
      )
      ..addOption(
        'temp-dir',
        help: 'Directory to store temporary build artifacts',
      )
      ..addOption(
        'glibc-version',
        help: 'GLIBC version to use for linux builds',
      )
      ..addFlag(
        'compress',
        defaultsTo: false,
        help: 'Compress binaries using zstd before signing.\n'
            'Requires zstd binary to be available in PATH.',
      )
      ..addFlag(
        "verbose",
        abbr: "v",
        defaultsTo: false,
        help: "Enable verbose logging",
      );
  }

  @override
  final name = 'precompile-binaries';

  @override
  final description = 'Prebuild binaries and either upload them or save to output directory.\n'
      'Private key must be passed through PRIVATE_KEY environment variable for signing. '
      'Use gen-key to generate a private key.\n'
      'When using --repository: gh CLI must be installed and authenticated for upload.\n'
      'Either --repository or --output must be specified, but not both.\n';

  @override
  Future<void> run() async {
    final verbose = argResults!['verbose'] as bool;
    if (verbose) {
      enableVerboseLogging();
    }

    // Validate mutually exclusive options
    final repository = argResults!['repository'] as String?;
    final output = argResults!['output'] as String?;

    if (repository == null && output == null) {
      throw ArgumentError(
        'Either --repository or --output must be specified.\n'
        'Use --repository to upload binaries to GitHub releases.\n'
        'Use --output to save binaries to a local directory.'
      );
    }

    if (repository != null && output != null) {
      throw ArgumentError(
        'Cannot specify both --repository and --output.\n'
        'Use --repository to upload binaries to GitHub releases.\n'
        'Use --output to save binaries to a local directory.'
      );
    }

    final privateKeyString = Platform.environment['PRIVATE_KEY'];
    if (privateKeyString == null) {
      throw ArgumentError('Missing PRIVATE_KEY environment variable');
    }

    final privateKey = HEX.decode(privateKeyString);
    if (privateKey.length != 64) {
      throw ArgumentError('Private key must be 64 bytes long');
    }
    final manifestDir = argResults!['manifest-dir'] as String;
    if (!Directory(manifestDir).existsSync()) {
      throw ArgumentError('Manifest directory does not exist: $manifestDir');
    }
    String? androidMinSdkVersionString =
        argResults!['android-min-sdk-version'] as String?;
    int? androidMinSdkVersion;
    if (androidMinSdkVersionString != null) {
      androidMinSdkVersion = int.tryParse(androidMinSdkVersionString);
      if (androidMinSdkVersion == null) {
        throw ArgumentError(
            'Invalid android-min-sdk-version: $androidMinSdkVersionString');
      }
    }
    final targetStrigns = argResults!['target'] as List<String>;
    final targets = targetStrigns.map((target) {
      final res = Target.forRustTriple(target);
      if (res == null) {
        throw ArgumentError('Invalid target: $target');
      }
      return res;
    }).toList(growable: false);
    final compress = argResults!['compress'] as bool;

    final precompileBinaries = PrecompileBinaries(
      privateKey: PrivateKey(privateKey),
      manifestDir: manifestDir,
      repositorySlug: repository != null ? RepositorySlug.full(repository) : null,
      outputDir: output,
      targets: targets,
      androidSdkLocation: argResults!['android-sdk-location'] as String?,
      androidNdkVersion: argResults!['android-ndk-version'] as String?,
      androidMinSdkVersion: androidMinSdkVersion,
      tempDir: argResults!['temp-dir'] as String?,
      glibcVersion: argResults!['glibc-version'] as String?,
      compress: compress,
    );

    await precompileBinaries.run();
  }
}

class VerifyBinariesCommand extends Command {
  VerifyBinariesCommand() {
    argParser.addOption(
      'manifest-dir',
      mandatory: true,
      help: 'Directory containing Cargo.toml',
    );
  }

  @override
  final name = "verify-binaries";

  @override
  final description = 'Verifies published binaries\n'
      'Checks whether there is a binary published for each targets\n'
      'and checks the signature.';

  @override
  Future<void> run() async {
    final manifestDir = argResults!['manifest-dir'] as String;
    final verifyBinaries = VerifyBinaries(
      manifestDir: manifestDir,
    );
    await verifyBinaries.run();
  }
}

Future<void> runMain(List<String> args) async {
  try {
    // Init logging before options are loaded
    initLogging();

    // Removed linker wrapper logic - cargo-ndk handles this now

    final runner = CommandRunner('build_tool', 'Cargokit built_tool')
      ..addCommand(BuildPodCommand())
      ..addCommand(BuildGradleCommand())
      ..addCommand(BuildCMakeCommand())
      ..addCommand(GenKeyCommand())
      ..addCommand(PrecompileBinariesCommand())
      ..addCommand(VerifyBinariesCommand());

    await runner.run(args);
  } on ArgumentError catch (e) {
    stderr.writeln(e.toString());
    exit(1);
  } catch (e, s) {
    log.severe(kDoubleSeparator);
    log.severe('Cargokit BuildTool failed with error:');
    log.severe(kSeparator);
    log.severe(e);
    // This tells user to install Rust, there's no need to pollute the log with
    // stack trace.
    if (e is! RustupNotFoundException) {
      log.severe(kSeparator);
      log.severe(s);
      log.severe(kSeparator);
      log.severe('BuildTool arguments: $args');
    }
    log.severe(kDoubleSeparator);
    exit(1);
  }
}
