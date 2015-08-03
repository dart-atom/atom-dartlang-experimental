// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library atom.sdk;

import 'dart:async';

import 'package:pub_semver/pub_semver.dart';

import 'atom.dart';
import 'atom_utils.dart';
import 'jobs.dart';
import 'process.dart';
import 'state.dart';
import 'utils.dart';

export 'process.dart' show ProcessResult;

final String _prefPath = '${pluginId}.sdkLocation';

final Version _minSdkVersion = new Version.parse('1.11.0');

// TODO: We should not try and auto-locate the sdk when the value’s bad, only
// when it’s empty.

class SdkManager implements Disposable {
  StreamController<Sdk> _controller = new StreamController.broadcast(sync: true);

  Sdk _sdk;
  Disposable _prefObserve;

  SdkManager() {
    // Load the existing setting and initiate auto-discovery if necessary.
    _setSdkPath(atom.config.getValue(_prefPath));
    if (!hasSdk) tryToAutoConfigure(complainOnFailure: false);

    _prefObserve = atom.config.observe(_prefPath, null, (value) {
      _setSdkPath(value, verbose: true);
    });
  }

  bool get hasSdk => _sdk != null;

  Sdk get sdk => _sdk;

  void showNoSdkMessage() {
    atom.notifications.addInfo(
        'No Dart SDK found.',
        detail: 'You can configure your SDK location in Settings > Packages > dart-lang > Settings.',
        dismissable: true);
  }

  void tryToAutoConfigure({bool complainOnFailure: true}) {
    new SdkDiscovery().discoverSdk().then((String sdkPath) {
      if (sdkPath != null) {
        atom.config.setValue(_prefPath, sdkPath);
      } else {
        if (complainOnFailure) {
          atom.notifications.addWarning('Unable to auto-locate a Dart SDK.');
        }
      }
    });
  }

  Stream<Sdk> get onSdkChange => _controller.stream;

  void _setSdkPath(String path, {bool verbose: false}) {
    Directory dir = (path == null || path.isEmpty) ? null : new Directory.fromPath(path);

    if (dir != null) {
      if (!dir.existsSync()) {
        dir = null;
      } else {
        if (new Sdk(dir).isNotValidSdk) dir = null;
      }
    }

    if (dir == null) {
      if (_sdk != null) {
        _sdk = null;
        _controller.add(null);

        if (verbose) {
          if (path == null || path.isEmpty) {
            atom.notifications.addInfo('No Dart SDK configured.');
          } else {
            atom.notifications.addInfo(
                'No Dart SDK configured.',
                detail: 'SDK not found at ${path}.');
          }
        }
      }
    } else if (_sdk == null || dir != _sdk.directory) {
      _sdk = new Sdk(dir);
      _controller.add(_sdk);

      if (verbose) {
        atom.notifications.addSuccess('Dart SDK found at ${path}.');
      }

      _verifyMinVersion(_sdk, verbose);
    }
  }

  void dispose() => _prefObserve.dispose();

  bool _alreadyWarned = false;

  void _verifyMinVersion(Sdk sdk, bool verbose) {
    sdk.getVersion().then((String version) {
      if (version == null) return;
      try {
        Version ver = new Version.parse(version);
        Version compare = ver.isPreRelease ? ver.nextPatch : ver;
        if (compare < _minSdkVersion) {
          if (!_alreadyWarned || verbose) {
            _alreadyWarned = true;
            atom.notifications.addWarning(
              'SDK version ${ver} is older than the required verison of ${_minSdkVersion}. '
              'Please visit www.dartlang.org to download a recent SDK.',
              dismissable: true);
          }
        }
      } catch (e) { }
    });
  }
}

class Sdk {
  final Directory directory;

  Sdk(this.directory);

  bool get isValidSdk =>
      directory.getFile('version').existsSync() &&
      directory.getSubdirectory('bin').existsSync();

  bool get isNotValidSdk => !isValidSdk;

  String get path => directory.path;

  Future<String> getVersion() {
    File file = directory.getFile('version');
    if (file.existsSync()) {
      return file.read().then((data) => data.trim());
    } else {
      return new Future.value(null);
    }
  }

  File get dartVm {
    if (isWindows) {
      return new File.fromPath(join(directory, 'bin', 'dart.exe'));
    } else {
      return new File.fromPath(join(directory, 'bin', 'dart'));
    }
  }

  String getSnapshotPath(String snapshotName) {
    File file = new File.fromPath(
        join(directory, 'bin', 'snapshots', snapshotName));
    return file.path;
  }

  /// Execute the given SDK binary (a command in the `bin/` folder). [cwd] can
  /// be either a [String] or a [Directory].
  Future<ProcessResult> execBinSimple(String binName, List<String> args, {cwd}) {
    if (cwd is Directory) cwd = cwd.path;
    String command = join(directory, 'bin', isWindows ? '${binName}.bat' : binName);

    // Run process under bash on the mac, to capture the user's env variables.
    if (isMac) {
      //exec('/bin/bash', ['-l', '-c', 'which dart'])
      String arg = args.join(' ');
      arg = command + ' ' + arg;
      return new ProcessRunner('/bin/bash', args: ['-l', '-c', arg], cwd: cwd).execSimple();
    } else {
      return new ProcessRunner(command, args: args, cwd: cwd).execSimple();
    }
  }

  String toString() => directory.getPath();
}

class SdkDiscovery {
  // TODO: fallback to $DART_SDK
  // static Future<String> getDartSdkEnvVar() {
  //
  // }

  /// Try and auto-discover an SDK based on platform specific heuristics. This
  /// will return `null` if no SDK is found.
  Future<String> discoverSdk() {
    if (isMac) {
      // /bin/bash -c "which dart", /bin/bash -c "echo $PATH"
      return exec('/bin/bash', ['-l', '-c', 'which dart']).then((result) {
        result = _resolveSdkFromVm(result);
        if (result != null) {
          // On mac, special case for homebrew. Replace the version specific
          // path with the version independent one.
          int index = result.indexOf('/Cellar/dart/');
          if (index != -1 && result.endsWith('/libexec')) {
            result = result.substring(0, index) + '/opt/dart/libexec';
          }
        }
        return result;
      }).catchError((e) {
        return null;
      });
    } else if (isWindows) {
      // TODO: Also use the PATH var?
      return exec('where', ['dart.exe']).then((result) {
        if (result != null && !result.isEmpty) {
          if (result.contains('\n')) result = result.split('\n').first.trim();
          return _resolveSdkFromVm(result);
        }
      }).catchError((e) {
        return null;
      });
    } else {
      return exec('which', ['dart']).then((String result) {
        return _resolveSdkFromVm(result);
      }).catchError((e) {
        return null;
      });
    }
  }

  String _resolveSdkFromVm(String vmPath) {
    if (vmPath == null) return null;
    File vmFile = new File.fromPath(vmPath.trim());
    // Resolve symlinks.
    vmFile = new File.fromPath(vmFile.getRealPathSync());
    return vmFile.getParent().getParent().path;
  }
}

class SdkLocationJob extends Job {
  final SdkManager sdkManager;

  SdkLocationJob(this.sdkManager) : super('Auto locate SDK');

  Future run() {
    sdkManager.tryToAutoConfigure(complainOnFailure: true);
    return new Future.delayed(new Duration(seconds: 1));
  }
}
