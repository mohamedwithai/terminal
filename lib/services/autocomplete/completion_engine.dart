import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/services/autocomplete/history.dart';

enum SuggestionSource { path, history, snippet, common }

/// One completion: what to type, and where it came from.
class Suggestion {
  const Suggestion({
    required this.source,
    required this.label,
    required this.insert,
    this.deleteCount = 0,
    this.meta,
    this.score = 0,
  });

  final SuggestionSource source;

  /// What the panel shows.
  final String label;

  /// Text to type at the cursor.
  final String insert;

  /// Characters to delete before typing [insert], to replace what was typed.
  final int deleteCount;

  /// "14x, last 2h ago" for history.
  final String? meta;
  final double score;

  /// The line after accepting this, given the [line] it completes.
  String applyTo(String line) =>
      line.substring(0, line.length - deleteCount) + insert;
}

/// Which sources are on.
class CompletionSources {
  const CompletionSources({
    this.paths = true,
    this.history = true,
    this.snippets = true,
    this.common = true,
  });

  final bool paths;
  final bool history;
  final bool snippets;
  final bool common;

  bool get any => paths || history || snippets || common;
}

/// Entries of a remote directory: names, directories ending in `/`.
typedef DirectoryLister = Future<List<String>> Function(String directory);

/// Commands whose arguments are paths.
const pathCommands = {
  'cd',
  'ls',
  'cat',
  'nano',
  'vim',
  'vi',
  'less',
  'more',
  'head',
  'tail',
  'tree',
  'du',
  'source',
};

/// Commands that only take directories.
const _directoryCommands = {'cd', 'tree', 'du'};

const commonCommands = [
  'ls -la',
  'ls -lh',
  'cd ..',
  'cd ~',
  'pwd',
  'clear',
  'exit',
  'history',
  'df -h',
  'du -sh *',
  'free -h',
  'top',
  'htop',
  'ps aux',
  'whoami',
  'uname -a',
  'uptime',
  'date',
  'systemctl status ',
  'systemctl restart ',
  'journalctl -u ',
  'journalctl -f',
  'tail -f ',
  'grep -rn ',
  'find . -name ',
  'cat ',
  'less ',
  'nano ',
  'vim ',
  'mkdir -p ',
  'rm -rf ',
  'cp -r ',
  'mv ',
  'chmod +x ',
  'chown -R ',
  'ssh ',
  'scp ',
  'rsync -avz ',
  'curl -I ',
  'wget ',
  'ping -c 4 ',
  'ip a',
  'ss -tulpn',
  'netstat -tulpn',
  'sudo ',
  'sudo apt update',
  'sudo apt upgrade',
  'sudo apt install ',
  'docker ps',
  'docker ps -a',
  'docker logs -f ',
  'docker compose up -d',
  'docker compose down',
  'git status',
  'git pull',
  'git push',
  'git log --oneline',
  'git diff',
  'git add .',
  'git commit -m ',
  'git checkout ',
  'tmux new -A -s main',
  'tmux attach',
  'tmux ls',
];

/// Chooses what to suggest for what is being typed.
///
/// Sources are ranked: paths (when the command takes one) first, then this
/// host's history by how often and how recently it was used, then snippets,
/// then common commands. Only completions that extend what was typed are
/// offered, and nothing is ever run.
class CompletionEngine {
  CompletionEngine({
    required this.history,
    required this.snippets,
    required this.listDirectory,
    DateTime Function()? clock,
    this.maxResults = 8,
  }) : _clock = clock ?? DateTime.now;

  final List<HistoryEntry> Function() history;
  final List<Snippet> Function() snippets;
  final DirectoryLister listDirectory;
  final DateTime Function() _clock;
  final int maxResults;

  Future<List<Suggestion>> suggest(
    String line, {
    String? cwd,
    CompletionSources sources = const CompletionSources(),
  }) async {
    if (line.trim().isEmpty || !sources.any) return const [];
    final results = <Suggestion>[];
    if (sources.paths) results.addAll(await _paths(line, cwd));
    if (sources.history) results.addAll(_history(line));
    if (sources.snippets) results.addAll(_snippets(line));
    if (sources.common) results.addAll(_common(line));

    final seen = <String>{};
    final unique = <Suggestion>[];
    for (final s in results) {
      if (s.applyTo(line) == line) continue;
      if (seen.add(
        '${s.applyTo(line)}\u0000${s.source == SuggestionSource.path}',
      )) {
        unique.add(s);
      }
    }
    unique.sort((a, b) {
      final bySource = a.source.index.compareTo(b.source.index);
      return bySource != 0 ? bySource : b.score.compareTo(a.score);
    });
    return unique.take(maxResults).toList();
  }

  /// The word being typed: from the last space that is not escaped.
  static ({String before, String token}) splitToken(String line) {
    var cut = -1;
    for (var i = 0; i < line.length; i++) {
      if (line[i] == ' ' && (i == 0 || line[i - 1] != r'\')) cut = i;
    }
    return (before: line.substring(0, cut + 1), token: line.substring(cut + 1));
  }

  Future<List<Suggestion>> _paths(String line, String? cwd) async {
    final (:before, :token) = splitToken(line);
    final words = before.trim().split(RegExp(r'\s+'));
    final command = words.first;
    if (before.isEmpty || !pathCommands.contains(command)) return const [];
    // Options such as `ls -l` are not paths.
    if (token.startsWith('-')) return const [];

    final slash = token.lastIndexOf('/');
    final dirPart = slash < 0 ? '' : token.substring(0, slash + 1);
    final prefix = slash < 0 ? token : token.substring(slash + 1);
    final String directory;
    if (dirPart.startsWith('/')) {
      directory = dirPart;
    } else if (dirPart.startsWith('~')) {
      directory = dirPart;
    } else if (cwd != null) {
      directory = '${cwd.endsWith('/') ? cwd : '$cwd/'}$dirPart';
    } else {
      // The directory is not known and the shell's cannot be guessed.
      return const [];
    }

    final unescapedPrefix = prefix.replaceAll(r'\ ', ' ');
    final names = await listDirectory(directory);
    final onlyDirectories = _directoryCommands.contains(command);
    final matches = <Suggestion>[];
    for (final name in names) {
      final isDirectory = name.endsWith('/');
      if (onlyDirectories && !isDirectory) continue;
      if (!name.startsWith(unescapedPrefix)) continue;
      if (name.startsWith('.') && !unescapedPrefix.startsWith('.')) continue;
      final rest = name
          .substring(unescapedPrefix.length)
          .replaceAll(' ', r'\ ');
      matches.add(
        Suggestion(
          source: SuggestionSource.path,
          label: name,
          insert: rest,
          meta: isDirectory ? 'folder' : null,
          score: isDirectory ? 1 : 0,
        ),
      );
    }
    // Folders first, then alphabetical regardless of case.
    matches.sort((a, b) {
      final byKind = b.score.compareTo(a.score);
      return byKind != 0
          ? byKind
          : a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return matches;
  }

  List<Suggestion> _history(String line) {
    final now = _clock();
    final results = <Suggestion>[];
    for (final entry in history()) {
      if (!entry.command.startsWith(line) || entry.command == line) continue;
      final age = now.difference(entry.lastUsed);
      final recency = 1 / (1 + age.inHours / 24);
      results.add(
        Suggestion(
          source: SuggestionSource.history,
          label: entry.command,
          insert: entry.command.substring(line.length),
          meta: '${entry.count}x, last ${_ago(age)}',
          score: entry.count + recency * 5,
        ),
      );
    }
    return results;
  }

  List<Suggestion> _snippets(String line) {
    final lower = line.toLowerCase();
    final results = <Suggestion>[];
    for (final snippet in snippets()) {
      if (snippet.steps.isEmpty) continue;
      final command = snippet.steps.first.command;
      if (command.startsWith(line) && snippet.allVariables.isEmpty) {
        results.add(
          Suggestion(
            source: SuggestionSource.snippet,
            label: snippet.name,
            insert: command.substring(line.length),
            meta: command,
          ),
        );
      } else if (snippet.name.toLowerCase().startsWith(lower) &&
          snippet.steps.length == 1 &&
          snippet.allVariables.isEmpty) {
        // Typed the snippet's name: replace it with the command.
        results.add(
          Suggestion(
            source: SuggestionSource.snippet,
            label: snippet.name,
            insert: command,
            deleteCount: line.length,
            meta: command,
          ),
        );
      }
    }
    return results;
  }

  List<Suggestion> _common(String line) {
    return [
      for (final command in commonCommands)
        if (command.startsWith(line) && command != line)
          Suggestion(
            source: SuggestionSource.common,
            label: command.trimRight(),
            insert: command.substring(line.length),
          ),
    ];
  }

  static String _ago(Duration age) {
    if (age.inMinutes < 1) return 'just now';
    if (age.inHours < 1) return '${age.inMinutes}m ago';
    if (age.inDays < 1) return '${age.inHours}h ago';
    return '${age.inDays}d ago';
  }
}
