import 'dart:io';

import 'package:glob/glob.dart';
import 'package:strike_cli/src/config.dart';
import 'package:strike_cli/src/task.dart';
import 'package:path/path.dart' as path;

class CommandContext {
  const CommandContext({
    required this.workspace,
    required this.config,
    required this.task,
    required this.args,
    required this.targetFilter,
  });

  final Directory workspace;
  final StrikeConfig config;
  final Task task;

  final Map<String, dynamic> args;

  final Glob? targetFilter;

  bool shouldRunFor(String targetPath) {
    var targetDir = path.relative(targetPath, from: workspace.path);

    if (targetFilter == null) {
      if (workspace.path == Directory.current.path) {
        return true;
      } else if (targetPath == workspace.path) {
        return false;
      }

      var currentDir =
          path.relative(Directory.current.path, from: workspace.path);

      // `isWithin` doesn't work if the directories are the same
      if (targetDir == currentDir) {
        return true;
      }

      // If we are in a subdirectory of the target, or the target is in a
      // subdirectory of the current directory, then we should run the task.
      if (path.isWithin(currentDir, targetDir) ||
          path.isWithin(targetDir, currentDir)) {
        return true;
      }
    }

    return targetFilter?.matches(targetDir) ?? false;
  }
}
