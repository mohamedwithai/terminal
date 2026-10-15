/// Fallback stubs for dart:io classes when compiling for Flutter Web.
class SocketException implements Exception {
  const SocketException(this.message, {this.osError});

  final String message;
  final OSError? osError;

  @override
  String toString() => 'SocketException: $message';
}

class OSError {
  const OSError([this.message = '', this.errorCode = 0]);

  final String message;
  final int errorCode;

  @override
  String toString() => 'OS Error: $message (code $errorCode)';
}
