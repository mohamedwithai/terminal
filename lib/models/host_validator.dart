/// Validates hostname, IPv4, or IPv6 address according to standards.
bool isValidHost(String raw) {
  final host = raw.trim();
  if (host.isEmpty || host.length > 253 || host.contains(RegExp(r'\s'))) {
    return false;
  }
  return _isValidIpv4(host) || _isValidIpv6(host) || _isValidHostname(host);
}

bool _isValidIpv4(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return false;
    if (part.length > 1 && part.startsWith('0')) return false;
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255) return false;
  }
  return true;
}

bool _isValidIpv6(String s) {
  var clean = s;
  if (clean.startsWith('[') && clean.endsWith(']')) {
    clean = clean.substring(1, clean.length - 1);
  }
  if (!clean.contains(':')) return false;

  final doubleColonParts = clean.split('::');
  if (doubleColonParts.length > 2) return false;

  final hasDoubleColon = doubleColonParts.length == 2;
  final parts = clean.split(':');

  int nonEmptyBlocks = 0;
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    if (p.isEmpty) continue;
    nonEmptyBlocks++;
    if (!RegExp(r'^[0-9a-fA-F]{1,4}$').hasMatch(p)) {
      if (i == parts.length - 1 && _isValidIpv4(p)) {
        continue;
      }
      return false;
    }
  }

  if (hasDoubleColon) {
    return nonEmptyBlocks <= 7;
  } else {
    return parts.length == 8;
  }
}

bool _isValidHostname(String s) {
  if (s.isEmpty || s.length > 253) return false;
  if (s.startsWith('.') || s.endsWith('.')) return false;
  if (s.contains('..')) return false;

  final labels = s.split('.');
  final tld = labels.last;
  // All-numeric TLDs (and single numeric labels like "0" or "123") are invalid.
  if (RegExp(r'^\d+$').hasMatch(tld)) {
    return false;
  }

  final labelPattern = RegExp(r'^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$');
  for (final label in labels) {
    if (label.isEmpty || label.length > 63) return false;
    if (!labelPattern.hasMatch(label)) return false;
  }
  return true;
}

class ParsedHostInput {
  const ParsedHostInput({
    this.username,
    required this.host,
    this.port,
  });

  final String? username;
  final String host;
  final int? port;
}

/// Splits composite paste inputs like `user@host`, `host:port`, or `user@host:port`.
ParsedHostInput? parseHostInput(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;

  String? username;
  if (text.contains('@')) {
    final atIdx = text.indexOf('@');
    final u = text.substring(0, atIdx).trim();
    if (u.isNotEmpty) {
      username = u;
    }
    text = text.substring(atIdx + 1).trim();
  }

  String host = text;
  int? port;

  if (text.startsWith('[')) {
    final closeIdx = text.indexOf(']');
    if (closeIdx != -1) {
      host = text.substring(1, closeIdx).trim();
      final remainder = text.substring(closeIdx + 1).trim();
      if (remainder.startsWith(':')) {
        final p = int.tryParse(remainder.substring(1).trim());
        if (p != null && p >= 1 && p <= 65535) {
          port = p;
        }
      }
    }
  } else {
    final firstColon = text.indexOf(':');
    final lastColon = text.lastIndexOf(':');
    if (firstColon != -1 && firstColon == lastColon) {
      final h = text.substring(0, firstColon).trim();
      final p = int.tryParse(text.substring(firstColon + 1).trim());
      if (p != null && p >= 1 && p <= 65535) {
        host = h;
        port = p;
      }
    }
  }

  if (username != null || port != null) {
    return ParsedHostInput(
      username: username,
      host: host,
      port: port,
    );
  }
  return null;
}
