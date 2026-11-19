import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:strike_cli/src/process_tree/process_tree_kill_exception.dart';
import 'package:strike_cli/src/process_tree/windows_last_error.dart';
import 'package:win32/win32.dart';

/// Kills the process [pid] and every process under it on Windows.
///
/// A process under [pid] that cannot be opened is not killed, and neither
/// are the processes under it. It counts as a process the kill could not
/// end, unless it had exited. A process started under the tree while the
/// kill runs may be missed.
///
/// Returns true when the kill ended [pid], and false when [pid] had already
/// exited.
///
/// Throws a [ProcessTreeReadException] when a snapshot or [pid] cannot be
/// read, and a [ProcessTreeTerminateException] when a process in the tree
/// cannot be ended.
bool killWindowsProcessTree(int pid) {
  bindLastWindowsError();

  final List<_OpenedProcess> tree;
  final Map<int, WindowsException> unopenable;

  try {
    (:tree, :unopenable) = _openProcessTree(pid);
  } on WindowsException catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ProcessTreeReadException(pid, error, stackTrace, endedRoot: false),
      stackTrace,
    );
  }

  try {
    final processErrors = {...unopenable};
    var endedRoot = false;

    for (final process in tree) {
      final error = process.terminate();

      if (error == null) {
        endedRoot = endedRoot || process.pid == pid;

        continue;
      }

      // TerminateProcess fails on a process that has already exited, and
      // that process needs nothing more.
      if (!process.hasExited) {
        processErrors[process.pid] = error;
      }
    }

    if (processErrors.isNotEmpty) {
      throw ProcessTreeTerminateException(pid, processErrors,
          endedRoot: endedRoot);
    }

    return endedRoot;
  } finally {
    for (final process in tree) {
      process.close();
    }
  }
}

/// [pid] and every process under it, each opened, or none when [pid] is not
/// running. `unopenable` holds the error for each process under [pid] that
/// could not be opened and had not exited.
///
/// The caller must close each process in `tree`.
({
  List<_OpenedProcess> tree,
  Map<int, WindowsException> unopenable,
}) _openProcessTree(int pid) {
  final _OpenedProcess root;

  try {
    root = _OpenedProcess.open(pid);
  } on WindowsException catch (error) {
    if (error.isProcessNotFound) {
      return (tree: const [], unopenable: const {});
    }

    rethrow;
  }

  // Each process stays open until the kill, which keeps its id from being
  // reused by another process.
  final tree = {pid: root};

  // Processes left out of the tree: unopenable, or created before the
  // process their parent id points at.
  final leftOut = <int>{};
  final unopenable = <int, WindowsException>{};

  try {
    var grew = true;

    while (grew) {
      grew = false;

      final children = <int, List<int>>{};

      for (final MapEntry(key: process, value: parent)
          in _readParentIds().entries) {
        children.putIfAbsent(parent, () => []).add(process);
      }

      final unvisited = [...tree.values];

      while (unvisited.isNotEmpty) {
        final parent = unvisited.removeLast();

        for (final process in children[parent.pid] ?? const <int>[]) {
          if (tree.containsKey(process) || leftOut.contains(process)) {
            continue;
          }

          final _OpenedProcess child;

          try {
            child = _OpenedProcess.open(process);
          } on WindowsException catch (error) {
            leftOut.add(process);

            if (!error.isProcessNotFound) {
              unopenable[process] = error;
            }

            continue;
          }

          // Windows keeps the id of a parent that exited, and an unrelated
          // process can reuse it. A child started at once can carry its
          // parent's creation time, so only an earlier time leaves it out.
          if (child.createdAt < parent.createdAt) {
            child.close();
            leftOut.add(process);

            continue;
          }

          tree[process] = child;
          unvisited.add(child);
          grew = true;
        }
      }
    }
  } catch (_) {
    for (final process in tree.values) {
      process.close();
    }

    rethrow;
  }

  return (tree: tree.values.toList(), unopenable: unopenable);
}

extension on WindowsException {
  /// Whether this is OpenProcess's error for an id no process has, as when
  /// the process exited.
  bool get isProcessNotFound =>
      hr == HRESULT_FROM_WIN32(WIN32_ERROR.ERROR_INVALID_PARAMETER);
}

/// A process held open by a handle.
class _OpenedProcess {
  _OpenedProcess._(this.pid, this._handle, this.createdAt);

  /// Opens the process [pid] and reads when it was created.
  ///
  /// A process strike may not end, such as one running elevated, still
  /// opens. [terminate] then fails on it. The caller must [close] it.
  ///
  /// Throws a [WindowsException] when either fails.
  factory _OpenedProcess.open(int pid) {
    var handle = OpenProcess(
      PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION |
          PROCESS_ACCESS_RIGHTS.PROCESS_TERMINATE |
          PROCESS_ACCESS_RIGHTS.PROCESS_SYNCHRONIZE,
      FALSE,
      pid,
    );

    if (handle == NULL) {
      final error = lastWindowsError();

      if (error.hr != HRESULT_FROM_WIN32(WIN32_ERROR.ERROR_ACCESS_DENIED)) {
        throw error;
      }

      handle = OpenProcess(
        PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION,
        FALSE,
        pid,
      );
    }

    if (handle == NULL) {
      throw lastWindowsError();
    }

    return using((arena) {
      // Creation, exit, kernel and user times, in that order.
      final times = arena<FILETIME>(4);

      if (GetProcessTimes(handle, times, times + 1, times + 2, times + 3) ==
          FALSE) {
        final error = lastWindowsError();

        CloseHandle(handle);

        throw error;
      }

      final creation = times.ref;

      return _OpenedProcess._(
        pid,
        handle,
        creation.dwHighDateTime << 32 | creation.dwLowDateTime,
      );
    });
  }

  final int pid;
  final int _handle;

  /// When the process was created, in 100-nanosecond intervals since 1601.
  final int createdAt;

  /// Ends the process, or returns why it could not.
  WindowsException? terminate() =>
      TerminateProcess(_handle, _terminatedExitCode) != FALSE
          ? null
          : lastWindowsError();

  bool get hasExited =>
      WaitForSingleObject(_handle, 0) == WAIT_EVENT.WAIT_OBJECT_0;

  void close() {
    CloseHandle(_handle);
  }
}

/// The exit code a terminated process ends with, the one `taskkill /F`
/// gives.
const _terminatedExitCode = 1;

/// The parent process id of every running process, keyed by process id.
Map<int, int> _readParentIds() {
  final snapshot = _createToolhelp32Snapshot(_th32csSnapProcess, 0);

  if (snapshot == INVALID_HANDLE_VALUE) {
    throw lastWindowsError();
  }

  try {
    return using((arena) {
      final entry = arena<_ProcessEntry32W>()
        ..ref.dwSize = sizeOf<_ProcessEntry32W>();

      if (_process32FirstW(snapshot, entry) == FALSE) {
        throw lastWindowsError();
      }

      final parentIds = <int, int>{};

      do {
        parentIds[entry.ref.th32ProcessID] = entry.ref.th32ParentProcessID;
      } while (_process32NextW(snapshot, entry) != FALSE);

      return parentIds;
    });
  } finally {
    CloseHandle(snapshot);
  }
}

// The win32 package does not bind the Toolhelp32 process functions, so they
// are bound here as tlhelp32.h declares them.

const _th32csSnapProcess = 0x00000002;

final class _ProcessEntry32W extends Struct {
  @Uint32()
  external int dwSize;

  @Uint32()
  external int cntUsage;

  @Uint32()
  external int th32ProcessID;

  @IntPtr()
  external int th32DefaultHeapID;

  @Uint32()
  external int th32ModuleID;

  @Uint32()
  external int cntThreads;

  @Uint32()
  external int th32ParentProcessID;

  @Int32()
  external int pcPriClassBase;

  @Uint32()
  external int dwFlags;

  @Array(MAX_PATH)
  external Array<Uint16> szExeFile;
}

final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _createToolhelp32Snapshot = _kernel32.lookupFunction<
    IntPtr Function(Uint32 dwFlags, Uint32 th32ProcessID),
    int Function(int dwFlags, int th32ProcessID)>('CreateToolhelp32Snapshot');

final _process32FirstW = _kernel32.lookupFunction<
    Int32 Function(IntPtr hSnapshot, Pointer<_ProcessEntry32W> lppe),
    int Function(
        int hSnapshot, Pointer<_ProcessEntry32W> lppe)>('Process32FirstW');

final _process32NextW = _kernel32.lookupFunction<
    Int32 Function(IntPtr hSnapshot, Pointer<_ProcessEntry32W> lppe),
    int Function(
        int hSnapshot, Pointer<_ProcessEntry32W> lppe)>('Process32NextW');
