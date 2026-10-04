/// Exception thrown by [MiniaudioPlayer] on native or runtime errors.
class MiniaudioPlayerException implements Exception {
  final String message;
  final int? errorCode;
  final String? details;

  const MiniaudioPlayerException(this.message, {this.errorCode, this.details});

  @override
  String toString() {
    if (errorCode != null) {
      return 'MiniaudioPlayerException(code: $errorCode): $message';
    }
    return 'MiniaudioPlayerException: $message';
  }
}
