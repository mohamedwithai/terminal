import 'package:connectivity_plus/connectivity_plus.dart';

/// Reports whether the device has a network connection.
abstract interface class NetworkMonitor {
  Future<bool> isOnline();

  /// Emits the new state whenever it changes.
  Stream<bool> get onlineChanges;
}

/// [NetworkMonitor] backed by connectivity_plus.
class ConnectivityNetworkMonitor implements NetworkMonitor {
  ConnectivityNetworkMonitor({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _isOnline(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);

  @override
  Future<bool> isOnline() async {
    return _isOnline(await _connectivity.checkConnectivity());
  }

  @override
  Stream<bool> get onlineChanges =>
      _connectivity.onConnectivityChanged.map(_isOnline).distinct();
}
