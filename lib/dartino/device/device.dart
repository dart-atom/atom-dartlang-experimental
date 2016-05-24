import 'dart:async';

import 'package:atom/atom.dart';
import 'package:atom/node/notification.dart';
import 'package:atom/node/process.dart';
import 'package:atom_dartlang/dartino/sdk/sdk.dart';

import '../dartino.dart';
import '../launch_dartino.dart';
import '../sdk/dartino_sdk.dart';
import '../sdk/sod_repo.dart';
import 'dartuino_board.dart';
import 'stm32f746disco.dart';

/// The connected device on which the application is executed.
abstract class Device {
  /// Return a target device for the given launch.
  /// If there is a problem or a compatible device cannot be found
  /// then notify the user and return `null`.
  static Future<Device> forLaunch(Sdk sdk, DartinoLaunch launch) async {
    Device device = await Stm32f746Disco.forLaunch(sdk, launch);
    if (device == null) device = await DartuinoBoard.forLaunch(sdk, launch);
    if (device == null) {
      if (dartino.devicePath.isEmpty) {
        atom.notifications.addError('No connected devices found.',
            detail: 'Please connect the device and try again.\n'
                ' \n'
                'If the device is already connected, please set the device\n'
                'path in Settings > Packages > dartino > Device Path,\n'
                'and/or disconnect and reconnect the device.',
            buttons: [
              new NotificationButton('Open settings', dartino.openSettings)
            ]);
      } else {
        atom.notifications.addError('Device not found',
            detail: 'Could not find specified device:\n'
                '${dartino.devicePath}\n'
                ' \n'
                'Please connect the device and try again\n'
                'or change/remove the device path in\n'
                'Settings > Packages > dartino > Device Path',
            buttons: [
              new NotificationButton('Open settings', dartino.openSettings)
            ]);
      }
    }
    return device;
  }

  /// Launch the specified application on the device and return `true`.
  /// If there is a problem, notify the user and return `false`.
  Future<bool> launchDartino(DartinoSdk sdk, DartinoLaunch launch);

  /// Launch the specified application on the device and return `true`.
  /// If there is a problem, notify the user and return `false`.
  Future<bool> launchSOD(SodRepo sdk, DartinoLaunch launch);

  /// Launch the specified application on the device and return `true`.
  /// If there is a problem, notify the user and return `false`.
  Future<bool> launchSOD_device(
      SodRepo sdk, DartinoLaunch launch, String ttyPath) async {
    //TODO(danrubel) add windows and mac support and move this into cmdline util
    if (isWindows || isMac) {
      atom.notifications.addError('Platform not supported');
      return false;
    }

    // Compile
    String binPath = await sdk.compile(launch);
    if (binPath == null) return false;

    // Deploy and run
    List<String> args = [sdk.sodUtil, 'run', binPath];
    if (ttyPath != null) args.addAll(['on', ttyPath]);
    var exitCode = await launch.run('dart',
        args: args, message: 'Deploy and run on connected device ...');
    if (exitCode != 0) {
      atom.notifications.addError('Failed to deploy application',
          detail: 'Failed to deploy to device.\n'
              '${launch.primaryResource}\n'
              ' \n'
              'Try disconnecting and reconnecting device.\n'
              'See console for more.');
      return false;
    }
    return true;
  }
}
