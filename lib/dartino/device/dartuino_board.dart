import 'dart:async';
import 'dart:convert';

import 'package:atom/atom.dart';
import 'package:atom/node/process.dart';
import 'package:atom_dartlang/dartino/sdk/sod_repo.dart';

import '../launch_dartino.dart';
import '../sdk/dartino_sdk.dart';
import '../sdk/sdk.dart';
import 'device.dart';

/// An Dartuino board
class DartuinoBoard extends Device {
  /// Return a target device for the given launch or `null` if none.
  static Future<DartuinoBoard> forLaunch(Sdk sdk, DartinoLaunch launch) async {
    //TODO(danrubel) move this into the command line utility
    //TODO(danrubel) add Windows support
    String ttyPath;

    if (isMac || isLinux) {
      // Old style interaction with device via TTY
      var stdout = await exec('ls', ['-1', '/dev']);
      if (stdout == null) return null;
      for (String line in LineSplitter.split(stdout)) {
        // TODO(danrubel) move this out of dartlang into the dartino
        // and SOD command line utilities - dartino show usb devices
        if (line.startsWith('tty.usb') || line.startsWith('ttyUSB')) {
          ttyPath = '/dev/$line';
          // This board surfaces 2 tty ports... and only the 2nd one works
          // so continue looping to pick up the 2nd tty port
        }
      }
    }

    if (ttyPath == null) {
      // New interaction with device via debug daemon
      if (sdk is SodRepo) {
        //TODO(danrubel) need better way to list connected devices
        if (await sdk.startDebugDaemon(launch) != null) {
          return new DartuinoBoard(null);
        }
      }
      return null;
    }
    return new DartuinoBoard(ttyPath);
  }

  final String ttyPath;

  DartuinoBoard(this.ttyPath);

  @override
  Future<bool> launchDartino(DartinoSdk sdk, DartinoLaunch launch) async {
    atom.notifications.addError('Dartino not yet supported on this board');
    return false;
  }

  @override
  Future<bool> launchSOD(SodRepo sdk, DartinoLaunch launch) {
    if (ttyPath == null) {
      return super.launchSOD(sdk, launch);
    } else {
      return launchSOD_old(sdk, launch, ttyPath);
    }
  }
}
