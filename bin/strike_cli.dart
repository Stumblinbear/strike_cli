import 'dart:async';
import 'dart:io';

import 'package:dart_console/dart_console.dart';
import 'package:strike_cli/src/commands/command_runner.dart';
import 'package:strike_cli/src/config.dart';

Future<void> main(List<String> args) async {
  final workspace = await locateWorkspace();

  late StrikeConfig config;

  try {
    config = await loadConfig(workspace);
  } on FormatException catch (e) {
    Console()
      ..setForegroundColor(ConsoleColor.brightRed)
      ..writeLine(e.message)
      ..resetColorAttributes()
      ..writeLine()
      ..writeLine(e.source);

    await _flushThenExit(1);
  } on TimeoutException {
    await _flushThenExit(1);
  } on FileSystemException catch (err) {
    if (err.osError?.errorCode == 2) {
      Console()
        ..setForegroundColor(ConsoleColor.brightRed)
        ..writeLine(
            "Couldn't locate a `strike.yaml` file in the current (nor any higher) directories.")
        ..resetColorAttributes();

      await _flushThenExit(1);
    } else {
      rethrow;
    }
  }

  await _flushThenExit(
      await StrikeCliCommandRunner(workspace, config).run(args));
}

/// Flushes the stdout and stderr streams, then exits the program with the given
/// status code.
Future<void> _flushThenExit(int status) async {
  await Future.wait<void>([stdout.close(), stderr.close()]);

  exit(status);
}
