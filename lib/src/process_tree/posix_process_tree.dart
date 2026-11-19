import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:strike_cli/src/process_tree/process_tree_kill_exception.dart';

/// How long a kill gives the tree to exit after SIGTERM before it sends
/// SIGKILL to what is left of it.
const _sigtermGrace = Duration(seconds: 5);

/// How often the processes are read while the tree is given to exit.
const _exitPollInterval = Duration(milliseconds: 100);

/// Kills the process [pid] and every process under it on Linux, macOS and
/// other systems with POSIX signals.
///
/// Every process in the tree is sent SIGTERM first. Whatever of the tree is
/// still running after [_sigtermGrace], including a process started under it
/// meanwhile, is sent SIGKILL. If a reading of the processes fails while
/// either signal is being sent, every process found by an earlier reading
/// is still sent it. A reading that fails during the grace sends nothing
/// more.
///
/// Returns true when the kill ended [pid], and false when [pid] had already
/// exited.
///
/// Throws a [ProcessTreeReadException] when the processes cannot be read, and
/// a [ProcessTreeTerminateException] when a process in the tree could not be
/// sent SIGKILL.
Future<bool> killPosixProcessTree(int pid) async {
  // Whether SIGTERM reached pid while it ran, whether SIGKILL did, and
  // whether a reading after SIGTERM no longer found pid.
  var terminatedRoot = false;
  var killedRoot = false;
  var rootGone = false;

  bool endedRoot() => killedRoot || (terminatedRoot && rootGone);

  try {
    final rootStartTime = (await _readProcesses())[pid]?.startTime;

    if (rootStartTime == null) {
      return false;
    }

    var tree = <int, String>{};

    // A stopped process holds SIGTERM until SIGCONT resumes it, so the whole
    // tree is found before any of it acts on the signal.
    try {
      await _stopTrees({pid: rootStartTime}, tree);
    } finally {
      for (final process in tree.keys) {
        final sent = Process.killPid(process, ProcessSignal.sigterm);

        if (process == pid) {
          terminatedRoot = sent;
        }
      }

      for (final process in tree.keys) {
        Process.killPid(process, ProcessSignal.sigcont);
      }
    }

    final grace = Stopwatch()..start();

    while (tree.isNotEmpty && grace.elapsed < _sigtermGrace) {
      await Future<void>.delayed(_exitPollInterval);

      tree = _processTrees(tree, await _readProcesses());
      rootGone = !tree.containsKey(pid);
    }

    if (tree.isEmpty) {
      return endedRoot();
    }

    final stopped = <int, String>{};
    final unsignalled = <int>{};

    // A process killed now would have its children reparented out of the
    // tree, so the whole tree is stopped first, as above.
    try {
      await _stopTrees(tree, stopped);
    } finally {
      for (final process in stopped.keys) {
        final sent = Process.killPid(process, ProcessSignal.sigkill);

        if (!sent) {
          unsignalled.add(process);
        }

        if (process == pid) {
          killedRoot = sent;
        }
      }
    }

    // pid, while it runs, is among the roots the walk starts from, so the
    // walk leaves it out only once it has exited.
    if (!stopped.containsKey(pid)) {
      rootGone = true;
    }

    if (unsignalled.isEmpty) {
      return endedRoot();
    }

    // killPid returns false both for a process that exited after the
    // reading and for one strike may not signal. Only the second is still
    // listed.
    final processes = await _readProcesses();

    final stillRunning = {
      for (final process in unsignalled)
        if (processes[process]?.startTime == stopped[process]) process,
    };

    if (!stillRunning.contains(pid)) {
      rootGone = true;
    }

    if (stillRunning.isNotEmpty) {
      throw ProcessTreeTerminateException(
        pid,
        {
          for (final process in stillRunning)
            process: SignalException('Could not send SIGKILL'),
        },
        endedRoot: endedRoot(),
      );
    }

    return endedRoot();
  } on ProcessException catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ProcessTreeReadException(pid, error, stackTrace, endedRoot: endedRoot()),
      stackTrace,
    );
  } on FileSystemException catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ProcessTreeReadException(pid, error, stackTrace, endedRoot: endedRoot()),
      stackTrace,
    );
  }
}

/// Sends SIGSTOP to each of [roots] still running and every process under
/// it, including a child started while the walk ran.
///
/// [roots] and [stopped] map a process id to its start time. Each process is
/// added to [stopped] as it is stopped, so that a caller can still signal it
/// if a later reading fails.
Future<void> _stopTrees(
  Map<int, String> roots,
  Map<int, String> stopped,
) async {
  while (true) {
    final tree = _processTrees(roots, await _readProcesses());

    final notStopped = {
      for (final MapEntry(key: process, value: startTime) in tree.entries)
        if (!stopped.containsKey(process)) process: startTime,
    };

    if (notStopped.isEmpty) {
      return;
    }

    for (final process in notStopped.keys) {
      Process.killPid(process, ProcessSignal.sigstop);
    }

    stopped.addAll(notStopped);
  }
}

/// Each of [roots] still running in [processes], and every process under
/// it, mapping each process id to its start time.
///
/// A root counts as running only while a process with its id has its start
/// time, since the id of a process that exited can be reused.
Map<int, String> _processTrees(
  Map<int, String> roots,
  Map<int, _ListedProcess> processes,
) {
  // The start time of each process, keyed by its parent's id and then its
  // own.
  final children = <int, Map<int, String>>{};

  for (final MapEntry(key: process, value: (:parent, :startTime))
      in processes.entries) {
    children.putIfAbsent(parent, () => {})[process] = startTime;
  }

  final tree = {
    for (final MapEntry(key: process, value: startTime) in roots.entries)
      if (processes[process]?.startTime == startTime) process: startTime,
  };

  final unvisited = [...tree.keys];

  while (unvisited.isNotEmpty) {
    final parent = unvisited.removeLast();

    for (final MapEntry(key: child, value: startTime)
        in (children[parent] ?? const <int, String>{}).entries) {
      if (!tree.containsKey(child)) {
        tree[child] = startTime;
        unvisited.add(child);
      }
    }
  }

  return tree;
}

/// A process as one reading of the processes listed it.
///
/// [startTime] tells apart processes that had the same id at different
/// times. It is only compared, never parsed.
typedef _ListedProcess = ({int parent, String startTime});

/// Every running process, keyed by process id.
Future<Map<int, _ListedProcess>> _readProcesses() {
  // Every Linux has /proc, whatever options its ps accepts. macOS has no
  // /proc.
  if (Platform.isLinux || Platform.isAndroid) {
    return _readProcessesFromProc();
  }

  return _readProcessesFromPs();
}

Future<Map<int, _ListedProcess>> _readProcessesFromProc() async {
  final processes = <int, _ListedProcess>{};

  // Following links would stat each entry, which fails for a process that
  // exits during the listing.
  await for (final entry in Directory('/proc').list(followLinks: false)) {
    final process = int.tryParse(path.basename(entry.path));

    if (process == null) {
      continue;
    }

    final String stat;

    try {
      // comm is the executable's name in whatever bytes it has, which may
      // not be UTF-8. latin1 decodes any bytes, and only the ASCII digits
      // after it are read.
      stat = await File('/proc/$process/stat').readAsString(encoding: latin1);
    } on FileSystemException {
      // The process exited after the listing.
      continue;
    }

    // The stat line is `pid (comm) state ppid ...`, and comm, the
    // executable's name, may itself hold spaces and parentheses, so the
    // fields are counted from the last `)`. The 22nd, starttime, is in clock
    // ticks since boot, so one id reused within a tick would take pid_max
    // processes started in that tick.
    final fields = stat.substring(stat.lastIndexOf(')') + 1).trim().split(' ');

    if (fields.length < 20) {
      continue;
    }

    final parent = int.tryParse(fields[1]);

    if (parent != null) {
      processes[process] = (parent: parent, startTime: fields[19]);
    }
  }

  return processes;
}

Future<Map<int, _ListedProcess>> _readProcessesFromPs() async {
  // lstart is the start time to the second. macOS hands out ids in order up
  // to 99999 before it reuses one, so one id reused within a second would
  // take that many processes started in that second.
  const arguments = ['-A', '-o', 'pid=', '-o', 'ppid=', '-o', 'lstart='];

  final result = await Process.run('ps', arguments);

  if (result.exitCode != 0) {
    throw ProcessException(
        'ps', arguments, result.stderr as String, result.exitCode);
  }

  final processes = <int, _ListedProcess>{};

  for (final line in LineSplitter.split(result.stdout as String)) {
    final fields = line.trim().split(RegExp(r'\s+'));

    if (fields.length < 3) {
      continue;
    }

    final process = int.tryParse(fields[0]);
    final parent = int.tryParse(fields[1]);

    if (process != null && parent != null) {
      processes[process] =
          (parent: parent, startTime: fields.skip(2).join(' '));
    }
  }

  return processes;
}
