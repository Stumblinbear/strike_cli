import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_console/dart_console.dart';
import 'package:strike_cli/src/task.dart';
import 'package:strike_cli/src/context.dart';

final _ansiRegex = RegExp(r'\x1B\[\??\d?\d?[A-Za-z]');

const _ansiReturnToStartOfLine = '\x1B[0G';
const _ansiEraseInLineAll = '\x1b[2K';

String ansiUp(int lines) => '\x1B[${lines}A';
String ansiDown(int lines) => '\x1B[${lines}B';

const _asciiProgressLoop = [
  '⢀⠀',
  '⡀⠀',
  '⠄⠀',
  '⢂⠀',
  '⡂⠀',
  '⠅⠀',
  '⢃⠀',
  '⡃⠀',
  '⠍⠀',
  '⢋⠀',
  '⡋⠀',
  '⠍⠁',
  '⢋⠁',
  '⡋⠁',
  '⠍⠉',
  '⠋⠉',
  '⠋⠉',
  '⠉⠙',
  '⠉⠙',
  '⠉⠩',
  '⠈⢙',
  '⠈⡙',
  '⢈⠩',
  '⡀⢙',
  '⠄⡙',
  '⢂⠩',
  '⡂⢘',
  '⠅⡘',
  '⢃⠨',
  '⡃⢐',
  '⠍⡐',
  '⢋⠠',
  '⡋⢀',
  '⠍⡁',
  '⢋⠁',
  '⡋⠁',
  '⠍⠉',
  '⠋⠉',
  '⠋⠉',
  '⠉⠙',
  '⠉⠙',
  '⠉⠩',
  '⠈⢙',
  '⠈⡙',
  '⠈⠩',
  '⠀⢙',
  '⠀⡙',
  '⠀⠩',
  '⠀⢘',
  '⠀⡘',
  '⠀⠨',
  '⠀⢐',
  '⠀⡐',
  '⠀⠠',
  '⠀⢀',
  '⠀⡀'
];

Future<void> executeTask(
  CommandContext ctx,
  Task task, {
  required bool showProgress,
}) async {
  final console = Console();

  if (!await task.step.shouldRun(ctx)) {
    console
      ..setForegroundColor(ConsoleColor.brightBlack)
      ..writeErrorLine('No commands to run')
      ..resetColorAttributes();

    return;
  }

  final exec = await task.step.execute(ctx);

  if (!showProgress) {
    await for (final entry in exec.run()) {
      console
        ..writeLine(entry.toString())
        ..resetColorAttributes();
    }
  } else {
    var timer = 0;

    var printFullScreen = true;
    final currentLines = <String>[];

    var windowOffset = 0;
    var cursorAt = 0;

    // Hide the cursor
    console
      ..hideCursor()
      ..rawMode = true;

    var forceQuit = false;
    var isComplete = false;

    // Listen for CTRL+C
    stdin.listen(
      (bytes) {
        if (bytes[0] == 3) {
          forceQuit = true;
        }
      },
    );

    while (!forceQuit && !isComplete) {
      exec.update(timer: timer);

      var currentI = 0;

      await for (final entry in exec.getDisplayOutput(timer: timer)) {
        var line = entry.toString();

        final lineLength = line.replaceAll(_ansiRegex, '').length;

        if (lineLength > console.windowWidth) {
          line = line.substring(
              0, (console.windowWidth - 3) + (line.length - lineLength));
          line += '...';
        }

        var shouldUpdateLine = printFullScreen;

        if (currentLines.length <= currentI) {
          currentLines.add('$line');
          shouldUpdateLine = true;
        } else if (currentLines[currentI] != line) {
          currentLines[currentI] = line;
          shouldUpdateLine = true;
        }

        if (printFullScreen) {
          if (currentI - windowOffset >= console.windowHeight) {
            shouldUpdateLine = false;
          }
        }

        if (shouldUpdateLine && currentI >= windowOffset) {
          if (!printFullScreen) {
            final newWindowOffset =
                currentI - (console.windowHeight / 2).floor() + 1;
            final maxWindowOffset =
                currentLines.length - console.windowHeight + 1;

            if (newWindowOffset > windowOffset &&
                newWindowOffset < maxWindowOffset) {
              final newLines = newWindowOffset - windowOffset;

              windowOffset = newWindowOffset;

              printFullScreen = true;

              // Move to the bottom of the screen and add a line
              console.write(
                  '${ansiDown(console.windowHeight - cursorAt - 1)}${'\n' * newLines}');

              cursorAt = console.windowHeight - 1;
            }
          }

          final cursorTarget = currentI - windowOffset;

          if (cursorAt > cursorTarget) {
            console.write(ansiUp(cursorAt - cursorTarget));
          } else if (cursorAt < cursorTarget) {
            console.write('\n' * (cursorTarget - cursorAt));
          }

          console
            ..write(_ansiReturnToStartOfLine)
            ..write('$_ansiEraseInLineAll$line')
            ..resetColorAttributes();

          cursorAt = cursorTarget;

          // Only add a new line if we're not at the bottom of the screen
          if (cursorAt < console.windowHeight - 1) {
            console.writeLine();

            cursorAt += 1;
          }
        }

        currentI += 1;
      }

      printFullScreen = false;

      if (exec.isComplete) {
        isComplete = true;
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));

      timer += 1;
    }

    if (cursorAt < currentLines.length) {
      console.write('${ansiDown(currentLines.length - cursorAt - 1)}\n');
    }

    console
      ..showCursor()
      ..rawMode = false;

    if (forceQuit) {
      exit(1);
    }
  }

  if (exec.hasError) {
    console.writeLine('');

    await for (final error in exec.getErrors()) {
      // Ensures that the label is not too long
      var label = error.label.substring(
          0, min(error.label.length, (console.windowWidth / 2).floor()));

      if (label.length != error.label.length) {
        label += '...';
      }

      var separator = '-' * console.windowWidth;
      final separatorLabel = ' ${label} (exit code ${error.exitCode}) ';

      final replaceStart = (separator.length - separatorLabel.length) ~/ 2;

      separator = separator.replaceRange(
        replaceStart,
        replaceStart + separatorLabel.length,
        separatorLabel,
      );

      console
        ..writeLine()
        ..setForegroundColor(ConsoleColor.brightBlack)
        ..writeLine(separator)
        ..resetColorAttributes()
        ..writeLine('');

      for (final line in error.lines) {
        console
          ..writeLine(line)
          ..resetColorAttributes();
      }

      console.writeLine();
    }

    console
      ..setForegroundColor(ConsoleColor.brightBlack)
      ..writeLine('-' * console.windowWidth)
      ..resetColorAttributes()
      ..writeLine();

    exit(1);
  }
}

class Line {
  Line();

  final line = StringBuffer();

  void color(ConsoleColor color) {
    line.write(color.ansiSetForegroundColorSequence);
  }

  void style({
    bool bold = false,
    bool faint = false,
    bool italic = false,
    bool underscore = false,
    bool blink = false,
    bool inverted = false,
    bool invisible = false,
    bool strikethru = false,
  }) {
    final styles = <int>[];

    if (bold) styles.add(1);
    if (faint) styles.add(2);
    if (italic) styles.add(3);
    if (underscore) styles.add(4);
    if (blink) styles.add(5);
    if (inverted) styles.add(7);
    if (invisible) styles.add(8);
    if (strikethru) styles.add(9);

    line.write('\x1b[${styles.join(";")}m');
  }

  void prefix(String? text) {
    if (text == null) return;
  }

  void add(Object? text) {
    if (text == null) return;

    line.write(text.toString());
  }

  @override
  String toString() => line.toString();
}

abstract class Execution {
  Execution();

  factory Execution.group({
    String? name,
    int? concurrency,
    required List<Execution> exec,
  }) = ExecutionGroup;

  factory Execution.cmd({
    required String command,
    required String target,
    required String workingDirectory,
  }) = ExecutionCommand;

  bool get isRunning;
  bool get isComplete;
  bool get hasError;

  void update({required int timer});

  Stream<Line> run();

  Stream<Line> getDisplayOutput({required int timer});

  Stream<Line> getOutput();

  Stream<ExecutionError> getErrors();
}

class ExecutionGroup extends Execution {
  ExecutionGroup({
    this.name,
    int? concurrency,
    required this.exec,
  }) : concurrency = concurrency ?? 0;

  final String? name;
  final int concurrency;
  List<Execution> exec;

  @override
  bool get isRunning =>
      exec.any((entry) => entry.isRunning) ||
      exec.any((entry) => entry.isComplete);

  @override
  bool get isComplete =>
      exec.every((entry) => entry.isComplete) ||
      exec.any((entry) => entry.hasError);

  @override
  bool get hasError => exec.any((entry) => entry.hasError);

  @override
  void update({required int timer}) {
    exec
        .where((entry) => !entry.isComplete)
        .take(concurrency <= 0 ? exec.length : concurrency)
        .forEach((entry) {
      entry.update(timer: timer);
    });
  }

  @override
  Stream<Line> run() async* {
    if (name != null) {
      yield* _createHeader(includeCounter: false);
    }

    if (exec.isEmpty) {
      yield Line()
        ..color(ConsoleColor.brightBlack)
        ..add(name != null ? '|  ' : '')
        ..add('No commands to run');

      return;
    }

    if (concurrency == 1) {
      for (final entry in exec) {
        yield* entry.run().map(
              (line) => Line()
                ..color(ConsoleColor.brightBlack)
                ..add(name != null ? '|  ' : '')
                ..add(line),
            );
      }
    } else {
      final futures = <Future<List<Line>>>[];

      for (final entry in exec) {
        // We have to convert this to a list so that the streams will complete without `await`ing it
        futures.add(entry.run().toList());

        if (futures.length == concurrency) {
          yield* Stream.fromIterable(await futures.removeAt(0)).map(
            (line) => Line()
              ..color(ConsoleColor.brightBlack)
              ..add(name != null ? '|  ' : '')
              ..add(line),
          );
        }
      }

      while (futures.length > 0) {
        yield* Stream.fromIterable(await futures.removeAt(0)).map(
          (line) => Line()
            ..color(ConsoleColor.brightBlack)
            ..add(name != null ? '|  ' : '')
            ..add(line),
        );
      }
    }
  }

  Stream<Line> _createHeader({required bool includeCounter}) async* {
    final color = exec.length > 0 && isComplete
        ? hasError
            ? ConsoleColor.brightRed
            : ConsoleColor.brightGreen
        : isRunning
            ? ConsoleColor.brightWhite
            : ConsoleColor.brightBlack;

    var suffix = '';

    if (includeCounter && exec.length > 1) {
      final complete =
          exec.where((entry) => entry.isComplete && !entry.hasError).length;
      final total = exec.length;

      suffix = ' ($complete/$total)';
    }

    if (name != null) {
      yield Line()
        ..color(color)
        ..style(bold: true)
        ..add(name)
        ..add(suffix);
    }
  }

  @override
  Stream<Line> getDisplayOutput({required int timer}) async* {
    if (name != null) {
      yield* _createHeader(includeCounter: true);
    }

    if (exec.length == 0) {
      yield Line()
        ..color(ConsoleColor.brightBlack)
        ..add(name != null ? '|  ' : '')
        ..add('No commands to run');

      return;
    }

    for (final entry in exec) {
      yield* entry.getDisplayOutput(timer: timer).map(
            (line) => Line()
              ..color(ConsoleColor.brightBlack)
              ..add(name != null ? '|  ' : '')
              ..add(line),
          );
    }
  }

  @override
  Stream<Line> getOutput() async* {
    for (final entry in exec) {
      yield* entry.getOutput();
    }
  }

  @override
  Stream<ExecutionError> getErrors() async* {
    for (final entry in exec) {
      if (entry.hasError) {
        yield* entry.getErrors();
      }
    }
  }
}

class ExecutionCommand extends Execution {
  ExecutionCommand({
    required String command,
    required String target,
    required this.workingDirectory,
  }) : command = command.replaceAll(RegExp(r'\s+\s'), ' ').trim();

  final String command;
  final String workingDirectory;

  final output = <String>[];
  int? exitCode = null;

  int startedAt = 0;

  bool isRunning = false;

  late Process _process;

  bool get isComplete => exitCode != null;
  bool get hasError => exitCode != null && exitCode != 0;

  @override
  Stream<Line> run() async* {
    await update(timer: 0);

    await _process.exitCode;

    yield* getDisplayOutput(timer: 0);
  }

  @override
  Future<void> update({required int timer}) async {
    if (isRunning || isComplete) return;

    startedAt = timer;

    final cmdSegments = command.split(' ');

    final process = await Process.start(
      cmdSegments[0],
      cmdSegments.sublist(1),
      workingDirectory: workingDirectory,
      runInShell: Platform.isWindows,
    );

    isRunning = true;

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(output.add);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(output.add);

    _process = process;

    unawaited(
      process.exitCode.then((value) {
        exitCode = value;
        isRunning = false;
      }),
    );
  }

  @override
  Stream<Line> getDisplayOutput({required int timer}) async* {
    final color = isComplete
        ? hasError
            ? ConsoleColor.brightRed
            : ConsoleColor.brightGreen
        : isRunning
            ? ConsoleColor.brightYellow
            : ConsoleColor.brightBlack;

    final progressLength = _asciiProgressLoop.first.length;

    final status = isComplete
        ? this.exitCode != 0
            ? ' ' * (progressLength - 1) + '✗'
            : ' ' * (progressLength - 1) + '✓'
        : isRunning
            ? _asciiProgressLoop[
                (timer - startedAt) % _asciiProgressLoop.length]
            : ' ' * progressLength;

    yield Line()
      ..color(color)
      ..add('$status ${command}')
      ..color(ConsoleColor.brightBlack)
      ..style(italic: true)
      ..add(workingDirectory != '.' ? ' (in $workingDirectory)' : '');
  }

  @override
  Stream<Line> getOutput() {
    return Stream.fromIterable(output.map((e) => Line()..add(e)));
  }

  @override
  Stream<ExecutionError> getErrors() async* {
    if (hasError) {
      yield ExecutionError(
          label: command, exitCode: this.exitCode!, lines: output);
    }
  }
}

class ExecutionError {
  ExecutionError(
      {required this.label, required this.exitCode, required this.lines});

  final String label;
  final int exitCode;
  final List<String> lines;
}
