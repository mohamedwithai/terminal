import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/host_validator.dart';

void main() {
  group('Host Validator', () {
    test('accepts valid hostnames, IPv4, and IPv6', () {
      // Hostnames
      expect(isValidHost('localhost'), isTrue);
      expect(isValidHost('example.com'), isTrue);
      expect(isValidHost('sub.domain.example.co.uk'), isTrue);
      expect(isValidHost('my-server-1'), isTrue);
      expect(isValidHost('build-box.internal.net'), isTrue);

      // IPv4
      expect(isValidHost('127.0.0.1'), isTrue);
      expect(isValidHost('192.168.1.1'), isTrue);
      expect(isValidHost('10.0.0.254'), isTrue);
      expect(isValidHost('0.0.0.0'), isTrue);

      // IPv6
      expect(isValidHost('::1'), isTrue);
      expect(isValidHost('[::1]'), isTrue);
      expect(isValidHost('2001:db8::1'), isTrue);
      expect(isValidHost('[2001:db8::1]'), isTrue);
      expect(isValidHost('fe80::1ff:fe23:4567:890a'), isTrue);
    });

    test('rejects invalid hosts ("0", "abc..", spaces, invalid octets)', () {
      // Specifically required by Phase 1 fix:
      expect(isValidHost('0'), isFalse);
      expect(isValidHost('abc..'), isFalse);

      // Malformed / invalid
      expect(isValidHost(''), isFalse);
      expect(isValidHost('   '), isFalse);
      expect(isValidHost('host name with space'), isFalse);
      expect(isValidHost('abc..com'), isFalse);
      expect(isValidHost('.example.com'), isFalse);
      expect(isValidHost('example.com.'), isFalse);
      expect(isValidHost('-badhost'), isFalse);
      expect(isValidHost('badhost-'), isFalse);
      expect(isValidHost('123'), isFalse);
      expect(isValidHost('192.168.1.999'), isFalse);
      expect(isValidHost('192.168.1'), isFalse);
      expect(isValidHost('256.0.0.1'), isFalse);
    });

    test('parseHostInput splits user@host, host:port, user@host:port', () {
      // user@host
      final uAtH = parseHostInput('root@192.168.1.1');
      expect(uAtH, isNotNull);
      expect(uAtH!.username, 'root');
      expect(uAtH.host, '192.168.1.1');
      expect(uAtH.port, isNull);

      // host:port
      final hPort = parseHostInput('example.com:2222');
      expect(hPort, isNotNull);
      expect(hPort!.username, isNull);
      expect(hPort.host, 'example.com');
      expect(hPort.port, 2222);

      // user@host:port
      final full = parseHostInput('deploy@myserver.org:2200');
      expect(full, isNotNull);
      expect(full!.username, 'deploy');
      expect(full.host, 'myserver.org');
      expect(full.port, 2200);

      // IPv6 with brackets and port
      final ipv6 = parseHostInput('admin@[::1]:2022');
      expect(ipv6, isNotNull);
      expect(ipv6!.username, 'admin');
      expect(ipv6.host, '::1');
      expect(ipv6.port, 2022);

      // Plain host returns null (no split needed)
      expect(parseHostInput('example.com'), isNull);
      expect(parseHostInput('::1'), isNull);
    });
  });
}
