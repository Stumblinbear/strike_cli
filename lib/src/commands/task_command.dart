import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:glob/glob.dart';
import 'package:strike_cli/src/config.dart';
import 'package:strike_cli/src/task.dart';
import 'package:strike_cli/src/context.dart';
import 'package:strike_cli/src/execute.dart';

class TaskCommand extends Command<int> {
  TaskCommand({
    required this.workspace,
    required this.config,
    required this.name,
    required this.task,
  }) {
    for (final arg in task.args) {
      final argType = arg.type;

      if (argType is ArgType<bool>) {
        argParser.addFlag(
          arg.name,
          help: arg.info,
          defaultsTo: argType.defaultVal,
        );

        continue;
      }

      argParser.addOption(
        arg.name,
        help: arg.info,
        defaultsTo: argType.defaultVal as String?,
        allowed: argType.allowedValues,
        mandatory: argType.defaultVal == null,
      );
    }
  }

  final Directory workspace;
  final StrikeConfig config;

  final String name;
  final Task task;

  @override
  String get description => task.info;

  @override
  Future<int> run() async {
    final args = <String, dynamic>{};

    final argResults = this.argResults!;

    for (final arg in task.args) {
      final argType = arg.type;

      if (argType is ArgType<bool>) {
        args[arg.name] = argResults.wasParsed(arg.name)
            ? argResults[arg.name] as bool
            : argType.defaultVal;

        continue;
      }

      args[arg.name] = argResults.wasParsed(arg.name)
          ? argResults[arg.name] as String
          : argType.defaultVal;
    }

    return await executeTask(
      CommandContext(
        workspace: workspace,
        config: config,
        task: task,
        args: args,
        targetFilter: globalResults!['target'] != null
            ? Glob(globalResults!['target'], recursive: true)
            : null,
      ),
      task,
      showProgress: globalResults!['progress']! as bool,
    );
  }
}
