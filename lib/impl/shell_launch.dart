library atom.shell_launch;

import 'dart:async';

import '../atom.dart';
import '../atom_utils.dart';
import '../launch.dart';
import '../process.dart';
import '../projects.dart';

// TODO: .bat files

class ShellLaunchType extends LaunchType {
  static void register(LaunchManager manager) =>
      manager.registerLaunchType(new ShellLaunchType());

  ShellLaunchType() : super('shell');

  bool canLaunch(String path) => path.endsWith('.sh');

  List<String> getLaunchablesFor(DartProject project) => [];

  Future<Launch> performLaunch(LaunchManager manager, LaunchConfiguration configuration) {
    String script = configuration.primaryResource;
    String cwd = configuration.cwd;
    List<String> args = configuration.argsAsList;

    String launchName = script;

    // Determine the best cwd.
    if (cwd == null) {
      List<String> paths = atom.project.relativizePath(script);
      if (paths[0] != null) {
        cwd = paths[0];
        launchName = paths[1];
      }
    } else {
      launchName = relativize(cwd, launchName);
    }

    ProcessRunner runner = new ProcessRunner(script, args: args, cwd: cwd);

    Launch launch = new Launch(this, launchName, manager,
        killHandler: () => runner.kill());
    manager.addLaunch(launch);

    runner.execStreaming();
    runner.onStdout.listen((str) => launch.pipeStdout(str));
    runner.onStderr.listen((str) => launch.pipeStderr(str));

    String desc = args == null ? launchName : '${launchName} ${args.join(' ')}';
    launch.pipeStdout(runner.cwd == null ? '${desc}\n' : '[${runner.cwd}] ${desc}\n');

    runner.onExit.then((code) => launch.launchTerminated(code));

    return new Future.value(launch);
  }
}