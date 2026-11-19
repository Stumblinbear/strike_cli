import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:strike_cli/src/process_tree/windows_last_error.dart';
import 'package:win32/win32.dart';

/// A Windows job object holding the processes strike's commands run in.
/// Until [release], Windows ends every process in the job when strike's
/// process ends, however it ends.
///
/// Keep strike's own process out of the job. Under a launcher such as
/// `dart run`, a job strike joined would nest in the launcher's job, and the
/// launcher would end what the commands left running after a [release].
final class WindowsKillOnExitJob {
  WindowsKillOnExitJob._(this._handle);

  /// Creates the job, empty.
  ///
  /// Throws a [WindowsException] when the job cannot be created.
  factory WindowsKillOnExitJob() {
    bindLastWindowsError();

    final handle = CreateJobObject(nullptr, nullptr);

    if (handle == NULL) {
      throw lastWindowsError();
    }

    final job = WindowsKillOnExitJob._(handle);

    try {
      job._setLimitFlags(_jobObjectLimitKillOnJobClose);
    } catch (_) {
      CloseHandle(handle);

      rethrow;
    }

    return job;
  }

  /// Puts the process [pid] in the job. Only the processes it starts
  /// afterwards join the job with it.
  ///
  /// Returns false when [pid] had already exited, and true otherwise.
  ///
  /// Throws a [WindowsException] when [pid] cannot be opened or put in the
  /// job, as when it runs in a job that forbids nesting.
  bool assign(int pid) {
    bindLastWindowsError();

    final process = OpenProcess(
      PROCESS_ACCESS_RIGHTS.PROCESS_SET_QUOTA |
          PROCESS_ACCESS_RIGHTS.PROCESS_TERMINATE |
          PROCESS_ACCESS_RIGHTS.PROCESS_SYNCHRONIZE,
      FALSE,
      pid,
    );

    if (process == NULL) {
      final error = lastWindowsError();

      // OpenProcess's error for an id no process has.
      if (error.hr == HRESULT_FROM_WIN32(WIN32_ERROR.ERROR_INVALID_PARAMETER)) {
        return false;
      }

      throw error;
    }

    try {
      if (AssignProcessToJobObject(_handle, process) != FALSE) {
        return true;
      }

      final error = lastWindowsError();

      // A process that has exited opens while a handle to it is still held,
      // as dart:io holds one for its exit code, but cannot join a job.
      if (WaitForSingleObject(process, 0) == WAIT_EVENT.WAIT_OBJECT_0) {
        return false;
      }

      throw error;
    } finally {
      CloseHandle(process);
    }
  }

  final int _handle;

  /// Lets the processes in the job outlive strike, so that a daemon a command
  /// started on purpose survives a normal exit.
  ///
  /// Throws a [WindowsException] when the job cannot be changed.
  void release() => _setLimitFlags(0);

  void _setLimitFlags(int limitFlags) {
    using((arena) {
      final information = arena<_JobObjectExtendedLimitInformation>();

      information.ref.basicLimitInformation.limitFlags = limitFlags;

      if (SetInformationJobObject(
            _handle,
            JOBOBJECTINFOCLASS.JobObjectExtendedLimitInformation,
            information,
            sizeOf<_JobObjectExtendedLimitInformation>(),
          ) ==
          FALSE) {
        throw lastWindowsError();
      }
    });
  }
}

// The win32 package does not bind the job limit structures, so they are
// bound here as winnt.h declares them.

const _jobObjectLimitKillOnJobClose = 0x00002000;

final class _JobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;

  @Int64()
  external int perJobUserTimeLimit;

  @Uint32()
  external int limitFlags;

  @Size()
  external int minimumWorkingSetSize;

  @Size()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @UintPtr()
  external int affinity;

  @Uint32()
  external int priorityClass;

  @Uint32()
  external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;

  @Uint64()
  external int writeOperationCount;

  @Uint64()
  external int otherOperationCount;

  @Uint64()
  external int readTransferCount;

  @Uint64()
  external int writeTransferCount;

  @Uint64()
  external int otherTransferCount;
}

final class _JobObjectExtendedLimitInformation extends Struct {
  external _JobObjectBasicLimitInformation basicLimitInformation;

  external _IoCounters ioInfo;

  @Size()
  external int processMemoryLimit;

  @Size()
  external int jobMemoryLimit;

  @Size()
  external int peakProcessMemoryUsed;

  @Size()
  external int peakJobMemoryUsed;
}
