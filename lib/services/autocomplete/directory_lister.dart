import 'dart:async';

/// Runs a command on the server and returns its output. The command runs on
/// a separate channel, so nothing shows in the terminal.
typedef RemoteExec = Future<String> Function(String command);

/// `ls` of a remote directory for path completion.
///
/// Results are kept for [ttl] (30 seconds), several callers asking at once
/// share one request, and a failure is remembered briefly so a broken
/// directory is not asked about on every keystroke.
class RemoteDirectoryLister {
  RemoteDirectoryLister({
    required this.exec,
    DateTime Function()? clock,
    this.ttl = const Duration(seconds: 30),
    this.failureTtl = const Duration(seconds: 5),
    this.timeout = const Duration(seconds: 4),
    this.maxEntries = 500,
  }) : _clock = clock ?? DateTime.now;

  final RemoteExec exec;
  final DateTime Function() _clock;
  final Duration ttl;
  final Duration failureTtl;
  final Duration timeout;
  final int maxEntries;

  final _cache = <String, ({DateTime at, Duration ttl, List<String> names})>{};
  final _pending = <String, Future<List<String>>>{};

  /// Names in [directory] (`/abs/`, `~/rel/`); directories end in `/`.
  Future<List<String>> list(String directory) {
    final cached = _cache[directory];
    if (cached != null && _clock().difference(cached.at) < cached.ttl) {
      return Future.value(cached.names);
    }
    // The callback must not return the future it is removing: whenComplete
    // waits for a returned future, which would wait for itself.
    return _pending[directory] ??= _fetch(directory).whenComplete(() {
      _pending.remove(directory);
    });
  }

  /// Forget everything, for example after a command that changed files.
  void invalidate() => _cache.clear();

  Future<List<String>> _fetch(String directory) async {
    try {
      final output = await exec(listCommand(directory, maxEntries))
          .timeout(timeout);
      final names = [
        for (final line in output.split('\n'))
          if (line.trim().isNotEmpty) line.replaceAll('\r', ''),
      ];
      _cache[directory] = (at: _clock(), ttl: ttl, names: names);
      return names;
    } catch (_) {
      _cache[directory] = (at: _clock(), ttl: failureTtl, names: const []);
      return const [];
    }
  }

  /// The command that lists [directory]. `~` is left to the shell as
  /// `$HOME`, and everything else is single-quoted so a name with spaces or
  /// `$` is taken literally.
  static String listCommand(String directory, int limit) {
    String quote(String text) => "'${text.replaceAll("'", r"'\''")}'";
    final String target;
    if (directory == '~' || directory == '~/') {
      target = r'"$HOME"/';
    } else if (directory.startsWith('~/')) {
      target = '"\$HOME"/${quote(directory.substring(2))}';
    } else {
      target = quote(directory);
    }
    return 'ls -1Ap -- $target 2>/dev/null | head -n $limit';
  }
}
