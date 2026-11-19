import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Whether [signal] is ignored in strike's process, as `nohup` leaves SIGHUP
/// for the program it runs.
///
/// Throws an [UnsupportedError] on systems other than Linux and macOS.
bool isSignalIgnored(ProcessSignal signal) {
  final Pointer<Void> handler = using((arena) {
    if (Platform.isLinux) {
      final action = arena<_LinuxSigaction>();

      _readSigaction(signal, action.cast());

      return action.ref.handler;
    }

    if (Platform.isMacOS) {
      final action = arena<_DarwinSigaction>();

      _readSigaction(signal, action.cast());

      return action.ref.handler;
    }

    throw UnsupportedError(
      'Reading a signal disposition is supported on Linux and macOS only',
    );
  });

  return handler.address == _sigIgn;
}

/// Writes [signal]'s current `struct sigaction` to [action].
void _readSigaction(ProcessSignal signal, Pointer<Void> action) {
  // sigaction fails only on an invalid signal number or a bad address,
  // neither of which a ProcessSignal and a fresh allocation can be.
  if (_sigaction(signal.signalNumber, nullptr, action) != 0) {
    throw StateError('sigaction could not read the disposition of $signal');
  }
}

/// `SIG_IGN`, which both Linux and macOS define as the handler address 1.
const _sigIgn = 1;

/// `struct sigaction` as glibc and musl declare it on every architecture
/// Dart runs Linux on.
final class _LinuxSigaction extends Struct {
  /// The union of `sa_handler` and `sa_sigaction`.
  external Pointer<Void> handler;

  @Array(128)
  external Array<Uint8> mask;

  @Int()
  external int flags;

  external Pointer<Void> restorer;
}

/// `struct sigaction` as macOS's `<sys/signal.h>` declares it for
/// `sigaction`.
final class _DarwinSigaction extends Struct {
  /// `__sigaction_u`, the union of `sa_handler` and `sa_sigaction`.
  external Pointer<Void> handler;

  @Uint32()
  external int mask;

  @Int()
  external int flags;
}

final _sigaction = DynamicLibrary.process().lookupFunction<
    Int Function(Int signal, Pointer<Void> action, Pointer<Void> oldAction),
    int Function(int signal, Pointer<Void> action,
        Pointer<Void> oldAction)>('sigaction');
