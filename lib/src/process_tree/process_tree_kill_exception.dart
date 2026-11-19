/// A failure to kill a process tree.
sealed class ProcessTreeKillException implements Exception {
  ProcessTreeKillException(this.pid, {required this.endedRoot});

  /// The process at the root of the tree.
  final int pid;

  /// Whether the kill ended [pid] itself before it failed.
  final bool endedRoot;
}

/// The processes in a tree could not be read. Only processes found by an
/// earlier reading may have been killed.
final class ProcessTreeReadException extends ProcessTreeKillException {
  ProcessTreeReadException(
    super.pid,
    this.cause,
    this.causeStackTrace, {
    required super.endedRoot,
  });

  /// What failed while the processes were read.
  final Exception cause;

  /// Where [cause] was thrown.
  final StackTrace causeStackTrace;

  @override
  String toString() => 'Could not read the processes under $pid: $cause';
}

/// Processes in a tree that could not be ended. Every other process found
/// in the tree was ended.
final class ProcessTreeTerminateException extends ProcessTreeKillException {
  ProcessTreeTerminateException(
    super.pid,
    this.processErrors, {
    required super.endedRoot,
  });

  /// The error for each process that could not be ended, keyed by its id.
  final Map<int, Exception> processErrors;

  @override
  String toString() {
    final errors = [
      for (final MapEntry(key: process, value: error) in processErrors.entries)
        '$process: $error',
    ];

    return 'Could not end every process under $pid: ${errors.join('; ')}';
  }
}
