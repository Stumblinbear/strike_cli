import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_console/dart_console.dart';
import 'package:strike_cli/src/commands/commands.dart';
import 'package:strike_cli/src/config.dart';

const executableName = 'strike';
const packageName = 'strike_cli';
const description = 'A dart CLI task runner.';

class StrikeCliCommandRunner extends CommandRunner<int> {
  StrikeCliCommandRunner(
    this.workspace,
    this.config,
  ) : super(executableName, description) {
    argParser
      ..addFlag(
        'progress',
        help: 'Update the console with the status of ongoing processes.',
        defaultsTo: true,
      )
      ..addOption(
        'target',
        help: 'Only run tasks that match the given target.',
      );

    for (final entry in config.tasks.entries) {
      addCommand(
        TaskCommand(
          workspace: workspace,
          config: config,
          name: entry.key,
          task: entry.value,
        ),
      );
    }
  }

  final Directory workspace;
  final StrikeConfig config;

  @override
  void printUsage() => print(usage);

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final topLevelResults = parse(args);

      return await runCommand(topLevelResults) ?? 0;
    } on FormatException catch (e, stackTrace) {
      Console()
        ..setForegroundColor(ConsoleColor.brightRed)
        ..writeLine(e.message)
        ..resetColorAttributes()
        ..writeLine(stackTrace);

      return 64;
    } on UsageException catch (e) {
      Console()
        ..setForegroundColor(ConsoleColor.brightRed)
        ..writeLine(e.message)
        ..resetColorAttributes()
        ..writeLine()
        ..writeLine(usage);

      return 64;
    }
  }
}
