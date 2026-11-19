import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_console/dart_console.dart';
import 'package:strike_cli/src/posix_signal_disposition.dart';
import 'package:strike_cli/src/process_tree/process_tree.dart';
import 'package:strike_cli/src/task.dart';
import 'package:strike_cli/src/context.dart';
import 'package:path/path.dart' as path;
import 'package:pool/pool.dart';
import 'package:win32/win32.dart' show WindowsException;

final _ansiRegex = RegExp(r'\x1B\[\??\d?\d?[A-Za-z]');

const _ansiReturnToStartOfLine = '\x1B[0G';
const _ansiEraseInLineAll = '\x1b[2K';

String ansiUp(int lines) => '\x1B[${lines}A';
String ansiDown(int lines) => '\x1B[${lines}B';

const _indicatorLength = 2;

const _kSuccessIndicator = '✓';
const _kFailureIndicator = '✗';
const _kInfoIndicator = '▪';

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

/// Runs [task] and returns strike's exit code, 1 when a command failed or the
/// run was stopped and 0 otherwise.
///
/// Completes with the first error nothing in the run catches, once the kills
/// it starts have finished.
Future<int> executeTask(
  CommandContext ctx,
  Task task, {
  required bool showProgress,
}) async {
  final console = Console();

  final exec = await task.execute(ctx);

  // Created before any command starts, so that each command's process is put
  // in it as it starts, along with every process it starts afterwards.
  final job = Platform.isWindows ? _createKillOnExitJob() : null;

  // Made first thing in run, inside the zone below, so that the kills it
  // schedules after a failure report their errors there too.
  late final _RunningCommandsKiller killer;

  var forceQuit = false;

  bool mayStartCommand() => !forceQuit && !exec.hasError;

  // Each call kills again, in case a process survived the last.
  void stopRun() {
    forceQuit = true;

    killer.stopAll();
  }

  Future<int> run() async {
    // Progress mode draws the kill lines below the commands, and --no-progress
    // prints each one as it comes.
    killer = _RunningCommandsKiller(
      exec,
      printLine: showProgress
          ? null
          : (line) => console
            ..writeLine(line.toString())
            ..resetColorAttributes(),
    );

    // Raw mode reads Ctrl+C from a terminal as a byte, so no signal reaches
    // strike or its commands. With --no-progress, or stdin a pipe or a file,
    // Ctrl+C arrives as SIGINT instead. Windows counts NUL as a terminal,
    // and raw mode then fails without effect, so SIGINT is watched in every
    // mode. A watched signal does not end strike, so strike keeps running
    // until every command's tree is killed and the run drains.
    final readsCtrlCAsByte = showProgress && stdin.hasTerminal;

    if (readsCtrlCAsByte) {
      console.rawMode = true;
    }

    final stopRequests = <StreamSubscription<Object>>[
      for (final signal in _stopSignals)
        signal.watch().listen((_) => stopRun()),
      if (readsCtrlCAsByte)
        stdin.listen((bytes) {
          if (bytes[0] == 3) {
            stopRun();
          }
        }),
    ];

    if (!showProgress) {
      // Each block is yielded after its command completes, so breaking on
      // exec.isComplete would cut the last block short.
      await for (final entry in exec.run(
        ctx,
        mayStartCommand: mayStartCommand,
        killOnExitJob: job,
      )) {
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

      console.hideCursor();

      while (true) {
        // update is the only place progress mode starts a command, and no exit
        // is seen while it runs, so checking once before it is enough.
        if (mayStartCommand()) {
          exec.update(ctx, timer: timer, killOnExitJob: job);
        }

        var currentI = 0;

        await for (final entry
            in _progressLines(ctx, exec, killer, timer: timer)) {
          var line = entry.toString();

          final lineLength = line.replaceAll(_ansiRegex, '').length;

          if (lineLength > console.windowWidth) {
            // This is too naieve (will cut off more if more colors are present), but it works for now
            line = line.substring(0, (console.windowWidth - 3));
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

            if (cursorAt < console.windowHeight - 1) {
              console.writeLine();

              cursorAt += 1;
            }
          }

          currentI += 1;
        }

        printFullScreen = false;

        // After a failure or a stop, the commands still running are waited
        // for, so none outlives strike.
        if (!exec.isRunning && (exec.isComplete || forceQuit)) {
          break;
        }

        await Future<void>.delayed(const Duration(milliseconds: 100));

        timer += 1;
      }

      if (cursorAt < currentLines.length) {
        console.write('${ansiDown(currentLines.length - cursorAt - 1)}\n');
      }

      console.showCursor();
    }

    await killer.settle();

    // Every command that started has ended, so its ending is final.
    final errors = await exec.getErrors().toList();

    final killedLabels = [
      for (final error in errors)
        if (error.ending is CommandKilled) error.label,
    ];

    // What is left in the job is what the commands left running: processes
    // a command started to outlive it, and after a kill, any a tree walk
    // missed because its parent had exited. A run that was stopped or killed
    // a command keeps the job, so that all of them end with strike.
    if (!forceQuit && killedLabels.isEmpty) {
      try {
        job?.release();
      } on WindowsException catch (error) {
        stderr.writeln(
          'strike could not release its job object, so the processes its '
          'commands left running end with it: $error',
        );
      }
    }

    for (final request in stopRequests) {
      await request.cancel();
    }

    if (readsCtrlCAsByte) {
      console.rawMode = false;
    }

    if (errors.isNotEmpty) {
      console.writeLine('');

      for (final error in errors) {
        final ending = switch (error.ending) {
          CommandExited(:final exitCode) => 'exit code $exitCode',
          CommandStartFailed() => 'could not start',
          // Its output shows no failure of its own, so it is only named in
          // the list below.
          CommandKilled() => null,
        };

        if (ending == null) {
          continue;
        }

        var label = error.label.substring(
            0, min(error.label.length, (console.windowWidth / 2).floor()));

        if (label.length != error.label.length) {
          label += '...';
        }

        console
          ..writeLine()
          ..setForegroundColor(ConsoleColor.brightBlack)
          ..writeLine(_labelledRule('$label ($ending)', console.windowWidth))
          ..resetColorAttributes()
          ..writeLine('');

        for (final line in error.lines) {
          console
            ..writeLine(line)
            ..resetColorAttributes();
        }

        if (error.ending case CommandStartFailed(error: final startError)) {
          console.writeLine('$startError');
        }

        console.writeLine();
      }

      if (killedLabels.isNotEmpty) {
        console
          ..writeLine()
          ..setForegroundColor(ConsoleColor.brightBlack)
          ..writeLine(_labelledRule('killed', console.windowWidth))
          ..resetColorAttributes()
          ..writeLine('');

        for (final label in killedLabels) {
          console.writeLine(label);
        }

        console.writeLine();
      }

      console
        ..setForegroundColor(ConsoleColor.brightBlack)
        ..writeLine('-' * console.windowWidth)
        ..resetColorAttributes()
        ..writeLine();

      return 1;
    }

    return forceQuit ? 1 : 0;
  }

  final exitCode = Completer<int>();
  var hasUncaughtError = false;

  // Every command, listener, timer and kill of the run starts in this zone,
  // so an error nothing catches lands here instead of ending strike while
  // commands run. The first one stops the run and propagates once the kills
  // have finished. Any later one is dropped, since the first is already on
  // its way out.
  runZonedGuarded(
    () => unawaited(run().then((code) {
      if (!hasUncaughtError) {
        exitCode.complete(code);
      }
    })),
    (error, stackTrace) async {
      if (hasUncaughtError) {
        return;
      }

      // The run has ended and nothing is left to kill.
      if (exitCode.isCompleted) {
        Error.throwWithStackTrace(error, stackTrace);
      }

      hasUncaughtError = true;

      stopRun();

      try {
        await killer.settle();
      } catch (_) {
        // Every kill has finished either way, and a kill that failed too
        // would only hide the error that stopped the run.
      }

      exitCode.completeError(error, stackTrace);
    },
  );

  return exitCode.future;
}

/// A rule of dashes [width] wide with [text] in its middle.
String _labelledRule(String text, int width) {
  final rule = '-' * width;
  final label = ' $text ';

  final start = (rule.length - label.length) ~/ 2;

  return rule.replaceRange(start, start + label.length, label);
}

/// Creates a [WindowsKillOnExitJob] for the run's commands.
///
/// Returns null when strike cannot create one, after writing why to stderr.
WindowsKillOnExitJob? _createKillOnExitJob() {
  try {
    return WindowsKillOnExitJob();
  } on WindowsException catch (error) {
    stderr.writeln(
      'strike could not create a job object, so its commands may outlive it '
      'if it is closed: $error',
    );

    return null;
  }
}

/// The signals that stop a run as Ctrl+C does: SIGINT, and off Windows
/// SIGTERM, which CI sends to cancel a job, and SIGHUP, sent when the
/// terminal closes.
///
/// Windows has no SIGTERM. dart:io maps SIGHUP there to the console closing,
/// but its handler returns at once, and Windows ends the process when the
/// handler returns, before strike can act on the signal. The
/// [WindowsKillOnExitJob] ends the commands then instead.
///
/// On Linux and macOS, a signal strike started with ignored, as `nohup`
/// leaves SIGHUP, is not watched, so it stays ignored for strike and every
/// command it starts. The list is first read when a run starts, before any
/// signal is watched, so each disposition is the one strike inherited.
final _stopSignals = [
  ProcessSignal.sigint,
  if (!Platform.isWindows) ...[ProcessSignal.sigterm, ProcessSignal.sighup],
]
    .where((signal) =>
        !((Platform.isLinux || Platform.isMacOS) && isSignalIgnored(signal)))
    .toList();

/// Kills the commands still running in a run, all of them on request, and
/// those under each group with a `killAfterFailure` delay once that delay
/// has passed since the group's first failure.
class _RunningCommandsKiller {
  _RunningCommandsKiller(this._exec, {this.printLine}) {
    for (final (:scope, :delay) in _exec.killAfterFailureScopes) {
      unawaited(scope.firstFailure.then((_) {
        if (!_isSettling) {
          _failureTimers.add(Timer(delay, () => _kill(scope)));
        }
      }));
    }
  }

  final Execution _exec;

  /// Prints a line when a kill first fails to end a command, and when a later
  /// kill ends it.
  final void Function(Line line)? printLine;

  final _failureTimers = <Timer>[];
  var _isSettling = false;

  final _kills = <Future<void>>[];

  /// The latest kill of each command that a kill has failed to end at least
  /// once.
  final _latestKills = <ExecutionCommand, CommandKillOutcome>{};

  /// A line for each command a kill has failed to end: why the latest kill
  /// failed, or that a later kill ended it.
  List<Line> get killLines => [
        for (final outcome in _latestKills.values) outcome.toLine(),
      ];

  /// Stops every command still running.
  void stopAll() {
    _kills.add(_exec.stop().then(_recordOutcomes));
  }

  void _kill(Execution scope) {
    _kills.add(scope.kill().then(_recordOutcomes));
  }

  void _recordOutcomes(List<CommandKillOutcome> outcomes) {
    for (final outcome in outcomes) {
      final previous = _latestKills[outcome.command];

      if (previous == null && outcome is CommandKillSuccess) {
        continue;
      }

      // A success replaces a failure's line rather than removing it, so
      // progress mode draws the same number of lines and none goes stale.
      _latestKills[outcome.command] = outcome;

      // A repeated failure updates the line without printing it again.
      if ((previous is CommandKillFailure) != (outcome is CommandKillFailure)) {
        printLine?.call(outcome.toLine());
      }
    }
  }

  /// Cancels the kills scheduled by a failure that have not run yet, then
  /// waits for every kill already started to finish.
  Future<void> settle() async {
    _isSettling = true;

    for (final timer in _failureTimers) {
      timer.cancel();
    }

    while (_kills.isNotEmpty) {
      final kills = List.of(_kills);

      _kills.clear();

      await Future.wait(kills);
    }
  }
}

/// The lines progress mode draws: each command's status, then the kill line
/// of each command a kill could not end.
Stream<Line> _progressLines(
  CommandContext ctx,
  Execution exec,
  _RunningCommandsKiller killer, {
  required int timer,
}) async* {
  yield* exec.getDisplayOutput(ctx, timer: timer);
  yield* Stream.fromIterable(killer.killLines);
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
    Duration? killAfterFailure,
    required List<Execution> exec,
  }) = ExecutionGroup;

  factory Execution.cmd({
    required String command,
    required String target,
    required String workingDirectory,
    required Map<String, String>? env,
    required SucceedOn succeed,
  }) = ExecutionCommand;

  /// Whether a command under this execution has a process starting or
  /// running.
  bool get isRunning;
  bool get isComplete;
  bool get hasError;

  /// Starts the commands under this execution that may start now.
  ///
  /// Each command's process is put in [killOnExitJob] as it starts.
  void update(
    CommandContext ctx, {
    required int timer,
    required WindowsKillOnExitJob? killOnExitJob,
  });

  /// Completes when a command under this execution first fails, and never if
  /// none does.
  Future<void> get firstFailure;

  /// This execution and each under it with an
  /// [ExecutionGroup.killAfterFailure] delay, paired with that delay.
  Iterable<({Execution scope, Duration delay})> get killAfterFailureScopes;

  /// Kills the process tree of every command under this execution that is
  /// starting or running. A command fails if the kill ends its process.
  /// Commands not yet started can still start afterwards.
  Future<List<CommandKillOutcome>> kill();

  /// Kills as [kill] does, after marking every command under this execution
  /// that is starting or running as stopped. A stopped command whose process
  /// started ends as killed, however that process ends.
  Future<List<CommandKillOutcome>> stop();

  /// Runs this execution and yields its display output.
  ///
  /// A command's lines are yielded together once the command finishes.
  /// [mayStartCommand] is asked before each command starts, and once it
  /// answers false no further command starts anywhere in the run. Each
  /// command's process is put in [killOnExitJob] as it starts.
  Stream<Line> run(
    CommandContext ctx, {
    required bool Function() mayStartCommand,
    required WindowsKillOnExitJob? killOnExitJob,
  });

  Stream<Line> getDisplayOutput(CommandContext ctx, {required int timer});

  Stream<Line> getOutput();

  Stream<ExecutionError> getErrors();
}

class ExecutionGroup extends Execution {
  static const _kGroupPrefix = '| ';

  ExecutionGroup({
    this.name,
    int? concurrency,
    this.killAfterFailure,
    required this.exec,
  }) : concurrency = concurrency ?? 0;

  final String? name;
  final int concurrency;

  /// How long after the first failure under this group its commands still
  /// running are killed, or null to wait for them however long they take.
  final Duration? killAfterFailure;

  List<Execution> exec;

  @override
  Iterable<({Execution scope, Duration delay})> get killAfterFailureScopes => [
        if (killAfterFailure case final delay?) (scope: this, delay: delay),
        for (final entry in exec) ...entry.killAfterFailureScopes,
      ];

  @override
  bool get isRunning => exec.any((entry) => entry.isRunning);

  @override
  bool get isComplete =>
      exec.every((entry) => entry.isComplete) ||
      exec.any((entry) => entry.hasError);

  @override
  bool get hasError => exec.any((entry) => entry.hasError);

  /// How many entries run at once.
  int get _slotCount => concurrency <= 0 ? exec.length : concurrency;

  @override
  void update(
    CommandContext ctx, {
    required int timer,
    required WindowsKillOnExitJob? killOnExitJob,
  }) {
    exec.where((entry) => !entry.isComplete).take(_slotCount).forEach((entry) {
      entry.update(ctx, timer: timer, killOnExitJob: killOnExitJob);
    });
  }

  @override
  late final Future<void> firstFailure =
      Future.any([for (final entry in exec) entry.firstFailure]);

  @override
  Future<List<CommandKillOutcome>> kill() async {
    final outcomes = await Future.wait(exec.map((entry) => entry.kill()));

    return outcomes.expand((entryOutcomes) => entryOutcomes).toList();
  }

  @override
  Future<List<CommandKillOutcome>> stop() async {
    final outcomes = await Future.wait(exec.map((entry) => entry.stop()));

    return outcomes.expand((entryOutcomes) => entryOutcomes).toList();
  }

  @override
  Stream<Line> run(
    CommandContext ctx, {
    required bool Function() mayStartCommand,
    required WindowsKillOnExitJob? killOnExitJob,
  }) async* {
    if (name != null) {
      yield* _createHeader(includeCounter: false);
    }

    if (exec.isEmpty) {
      yield Line()
        ..color(ConsoleColor.brightBlack)
        ..add(name != null ? _kGroupPrefix : '')
        ..add(' ' * (_indicatorLength - 1))
        ..add('$_kInfoIndicator No commands to run');

      return;
    }

    if (concurrency == 1) {
      for (final entry in exec) {
        if (!mayStartCommand()) {
          return;
        }

        yield* entry
            .run(
              ctx,
              mayStartCommand: mayStartCommand,
              killOnExitJob: killOnExitJob,
            )
            .map(_prefixed);
      }
    } else {
      // Collecting each entry's output lets it run to completion before
      // anything reads it, so blocks arrive whole and in finish order. A
      // failed command's ending is set before its block ends, so the next
      // entry the pool starts already finds mayStartCommand false.
      Future<List<Line>?> collect(Execution entry) async {
        if (!mayStartCommand()) {
          return null;
        }

        return entry
            .run(
              ctx,
              mayStartCommand: mayStartCommand,
              killOnExitJob: killOnExitJob,
            )
            .toList();
      }

      await for (final block
          in Pool(_slotCount).forEach<Execution, List<Line>?>(exec, collect)) {
        for (final line in block ?? const <Line>[]) {
          yield _prefixed(line);
        }
      }
    }
  }

  /// [line] as it appears inside this group's output.
  Line _prefixed(Line line) => Line()
    ..color(ConsoleColor.brightBlack)
    ..add(name != null ? _kGroupPrefix : '')
    ..add(line);

  Stream<Line> _createHeader({required bool includeCounter}) async* {
    final color = exec.length > 0 && isComplete
        ? hasError
            ? ConsoleColor.brightRed
            : ConsoleColor.brightGreen
        : exec.any((entry) => entry.isRunning || entry.isComplete)
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
  Stream<Line> getDisplayOutput(
    CommandContext ctx, {
    required int timer,
  }) async* {
    if (name != null) {
      yield* _createHeader(includeCounter: true);
    }

    if (exec.length == 0) {
      yield Line()
        ..color(ConsoleColor.brightBlack)
        ..add(name != null ? _kGroupPrefix : '')
        ..add(' ' * (_indicatorLength - 1))
        ..add('$_kInfoIndicator No commands to run');

      return;
    }

    for (final entry in exec) {
      yield* entry.getDisplayOutput(ctx, timer: timer).map(
            (line) => Line()
              ..color(ConsoleColor.brightBlack)
              ..add(name != null ? _kGroupPrefix : '')
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
    required this.env,
    required this.succeed,
  }) : command = command.trim();

  /// The command line as written, which [_parseArguments] splits into the
  /// program and its arguments.
  final String command;

  /// [command] with each run of whitespace shown as one space, for the
  /// status line.
  String get label => command.replaceAll(RegExp(r'\s+'), ' ');
  final String workingDirectory;
  final Map<String, String>? env;

  final SucceedOn succeed;

  final output = <String>[];

  int startedAt = 0;

  bool isRunning = false;

  /// The process running [command], null until [update] starts it, and
  /// completing with null if it could not start.
  Future<Process?>? _process;

  /// Whether [kill] ended the process, even if it failed to end others under
  /// it.
  bool _wasKilled = false;

  /// Whether [stop] reached the command while it was starting or running.
  bool _wasStopped = false;

  /// Each kill started on the process.
  final _killsInFlight = <Future<void>>[];

  CommandEnding? _ending;

  final _ended = Completer<void>();
  final _failed = Completer<void>();

  bool get isComplete => _ending != null;
  bool get hasError => switch (_ending) {
        null => false,
        CommandExited(:final exitCode) => succeed != SucceedOn.always &&
            (succeed == SucceedOn.onPass ? exitCode != 0 : exitCode == 0),
        CommandKilled() || CommandStartFailed() => true,
      };

  void _end(CommandEnding ending) {
    _ending = ending;
    isRunning = false;

    _ended.complete();

    if (hasError) {
      _failed.complete();
    }
  }

  @override
  Stream<Line> run(
    CommandContext ctx, {
    required bool Function() mayStartCommand,
    required WindowsKillOnExitJob? killOnExitJob,
  }) async* {
    await update(ctx, timer: 0, killOnExitJob: killOnExitJob);

    await _ended.future;

    yield* getDisplayOutput(ctx, timer: 0);
  }

  /// Splits [commandLine] into arguments. Whitespace outside double quotes
  /// separates arguments, and quoted text joins the text around it.
  /// Backslashes are literal except before a double quote, as in Windows
  /// command lines: each pair yields one backslash, and an odd one left over
  /// makes the quote literal, so `C:\dir\file` needs no escaping. `quote` in
  /// the evaluation prelude (eval.dart) writes this form.
  List<String> _parseArguments(String commandLine) {
    final args = <String>[];
    final buffer = StringBuffer();

    var inArgument = false;
    var isQuoted = false;
    var backslashes = 0;

    for (final c in commandLine.split('')) {
      if (c == r'\') {
        backslashes++;
        inArgument = true;

        continue;
      }

      if (c == '"') {
        buffer.write(r'\' * (backslashes ~/ 2));

        if (backslashes.isOdd) {
          buffer.write('"');
        } else {
          isQuoted = !isQuoted;
        }

        backslashes = 0;
        inArgument = true;

        continue;
      }

      buffer.write(r'\' * backslashes);
      backslashes = 0;

      if (!isQuoted && c.trim().isEmpty) {
        if (inArgument) {
          args.add(buffer.toString());
          buffer.clear();

          inArgument = false;
        }

        continue;
      }

      buffer.write(c);
      inArgument = true;
    }

    buffer.write(r'\' * backslashes);

    if (inArgument) {
      args.add(buffer.toString());
    }

    return args;
  }

  @override
  Future<void> update(
    CommandContext ctx, {
    required int timer,
    required WindowsKillOnExitJob? killOnExitJob,
  }) async {
    if (isRunning || isComplete) return;

    startedAt = timer;

    // Running from before the start completes, so a second update cannot
    // start the command again and the run waits for a start in progress.
    isRunning = true;

    final started = Completer<Process?>();

    _process = started.future;

    // A command line with no program, a missing working directory, or a
    // missing program outside Windows fails the start. The command then ends
    // as a failure like any other, so the run stops starting commands and
    // waits for the rest. Not every caller awaits update, so whatever the
    // start throws is caught here rather than left unhandled.
    final Process process;

    try {
      final cmdSegments = _parseArguments(command);

      if (cmdSegments.isEmpty) {
        throw FormatException('The command line names no program', command);
      }

      process = await Process.start(
        cmdSegments[0].replaceAll('/', path.separator),
        cmdSegments.sublist(1),
        workingDirectory: workingDirectory,
        runInShell: Platform.isWindows,
        environment: env,
      );
    } catch (error, stackTrace) {
      started.complete(null);

      _end(CommandStartFailed(error, stackTrace));

      return;
    }

    // A process the command starts before this stays out of the job, and the
    // job does not end it.
    try {
      killOnExitJob?.assign(process.pid);
    } on WindowsException catch (error) {
      stderr.writeln(
        'strike could not put $label in its job object, so its processes may '
        'outlive strike if it is closed: $error',
      );
    }

    started.complete(process);

    for (final stream in [process.stdout, process.stderr]) {
      stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(output.add);
    }

    unawaited(
      process.exitCode.then((value) async {
        // A kill still in flight may have caused this exit, and it sets
        // _wasKilled only when it finishes.
        await Future.wait(_killsInFlight);

        _end(
          _wasKilled || _wasStopped ? CommandKilled() : CommandExited(value),
        );
      }),
    );
  }

  @override
  Future<void> get firstFailure => _failed.future;

  @override
  Iterable<({Execution scope, Duration delay})> get killAfterFailureScopes =>
      const [];

  @override
  Future<List<CommandKillOutcome>> kill() async {
    final start = _process;

    if (start == null) {
      return const [];
    }

    final process = await start;

    if (process == null || isComplete) {
      return const [];
    }

    final killing = _killTree(process.pid);

    _killsInFlight.add(killing);

    return [await killing];
  }

  @override
  Future<List<CommandKillOutcome>> stop() {
    if (isRunning) {
      _wasStopped = true;
    }

    return kill();
  }

  Future<CommandKillOutcome> _killTree(int pid) async {
    try {
      if (await killProcessTree(pid)) {
        _wasKilled = true;
      }
    } on ProcessTreeKillException catch (error) {
      if (error.endedRoot) {
        _wasKilled = true;
      }

      return CommandKillFailure(command: this, error: error);
    }

    return CommandKillSuccess(command: this);
  }

  @override
  Stream<Line> getDisplayOutput(
    CommandContext ctx, {
    required int timer,
  }) async* {
    final color = isComplete
        ? hasError
            ? ConsoleColor.brightRed
            : ConsoleColor.brightGreen
        : isRunning
            ? ConsoleColor.brightYellow
            : ConsoleColor.brightBlack;

    final status = isComplete
        ? this.hasError
            ? ' ' * (_indicatorLength - 1) + _kFailureIndicator
            : ' ' * (_indicatorLength - 1) + _kSuccessIndicator
        : isRunning
            ? _asciiProgressLoop[
                (timer - startedAt) % _asciiProgressLoop.length]
            : ' ' * (_indicatorLength - 1) + _kInfoIndicator;

    yield Line()
      ..color(color)
      ..add('$status $label')
      ..color(ConsoleColor.brightBlack)
      ..style(italic: true)
      ..add(workingDirectory != ctx.workspace.path
          ? ' (in ${path.relative(workingDirectory, from: ctx.workspace.path)})'
          : '');
  }

  @override
  Stream<Line> getOutput() {
    return Stream.fromIterable(output.map((e) => Line()..add(e)));
  }

  @override
  Stream<ExecutionError> getErrors() async* {
    if (hasError) {
      yield ExecutionError(
        label: label,
        ending: _ending!,
        lines: output,
      );
    }
  }
}

/// What [Execution.kill] did to one command it tried to kill.
sealed class CommandKillOutcome {
  CommandKillOutcome({required this.command});

  final ExecutionCommand command;

  /// The outcome on one line, for the run's output.
  Line toLine();
}

/// A command whose whole process tree [Execution.kill] killed, or found had
/// already exited.
final class CommandKillSuccess extends CommandKillOutcome {
  CommandKillSuccess({required super.command});

  @override
  Line toLine() => Line()..add('Killed ${command.label}');
}

/// A command whose process tree [Execution.kill] could not kill.
final class CommandKillFailure extends CommandKillOutcome {
  CommandKillFailure({required super.command, required this.error});

  final ProcessTreeKillException error;

  @override
  Line toLine() {
    final reason = switch (error) {
      ProcessTreeReadException(:final cause) => '$cause',
      ProcessTreeTerminateException(:final processErrors) => [
          for (final MapEntry(key: process, value: processError)
              in processErrors.entries)
            '$process: $processError',
        ].join('; '),
    };

    return Line()
      ..color(ConsoleColor.brightRed)
      ..add('Could not kill ${command.label}: ')
      ..add(reason.replaceAll(RegExp(r'\s+'), ' ').trim());
  }
}

class ExecutionError {
  ExecutionError(
      {required this.label, required this.ending, required this.lines});

  final String label;
  final CommandEnding ending;
  final List<String> lines;
}

/// How a command ended.
sealed class CommandEnding {}

/// The command exited on its own.
final class CommandExited extends CommandEnding {
  CommandExited(this.exitCode);

  final int exitCode;
}

/// Strike killed the command.
final class CommandKilled extends CommandEnding {}

/// The command's process could not be started.
final class CommandStartFailed extends CommandEnding {
  CommandStartFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
