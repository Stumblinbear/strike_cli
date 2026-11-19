import 'package:win32/win32.dart';

/// Prepares [lastWindowsError] to read the error of the Win32 call before it.
///
/// Call it before the first Win32 call that may fail, or the first
/// [lastWindowsError] reads that failure as success.
void bindLastWindowsError() => GetLastError();

/// The error the last failed Win32 call on this thread set.
WindowsException lastWindowsError() =>
    WindowsException(HRESULT_FROM_WIN32(GetLastError()));
