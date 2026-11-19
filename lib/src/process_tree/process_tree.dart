import 'dart:io';

import 'package:strike_cli/src/process_tree/posix_process_tree.dart';
import 'package:strike_cli/src/process_tree/windows_process_tree.dart';

export 'package:strike_cli/src/process_tree/process_tree_kill_exception.dart';
export 'package:strike_cli/src/process_tree/windows_kill_on_exit_job.dart';

/// Kills the process [pid] and every process under it.
///
/// A process whose parent exited before the kill is not reached.
///
/// Windows ends the tree at once. Elsewhere the tree is sent SIGTERM, and
/// SIGKILL if any of it is still running 5 seconds later, so the kill can
/// take that long.
///
/// Returns true when the kill ended [pid], and false when [pid] had already
/// exited.
///
/// Throws a [ProcessTreeKillException] when the processes cannot be read or
/// a process in the tree cannot be ended.
Future<bool> killProcessTree(int pid) async {
  if (Platform.isWindows) {
    return killWindowsProcessTree(pid);
  }

  return killPosixProcessTree(pid);
}
