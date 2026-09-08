import 'package:flutter_test/flutter_test.dart';
import 'package:p2wlan_flutter_client/core/rooms/route_inventory.dart';

void main() {
  test('route conflict explains both ranges and the actual interface', () {
    final message = nativeRoomConflictMessage(
      '10.21.1.0/24',
      const NativeIpv4Route('10.0.0.0/8', 'Other VPN'),
    );
    expect(message, contains('10.21.1.0/24'));
    expect(message, contains('10.0.0.0/8'));
    expect(message, contains('Other VPN'));
    expect(message, contains('房间已加入，但尚未连接'));
    expect(message, contains('不会自动删除现有路由'));
  });

  test('Linux wider routes allow a more-specific room route', () {
    final routes = parseJsonRouteInventory('''[
      {"dst":"default","gateway":"192.168.1.1","dev":"eth0"},
      {"dst":"10.0.0.0/8","dev":"eth1","table":"custom"},
      {"type":"local","dst":"127.0.0.1","dev":"lo","table":"local"}
    ]''');
    expect(routes.length, 2);
    expect(findNativeRoomConflict('10.21.1.0/24', routes), isNull);
  });

  test('blackhole route without interface still blocks conflicting room', () {
    final routes = parseJsonRouteInventory(
      '[{"type":"blackhole","dst":"10.21.9.0/24"}]',
    );
    expect(findNativeRoomConflict('10.21.9.0/24', routes), isNotNull);
  });

  test('Windows handles a single JSON object and route arrays', () {
    final single = parseJsonRouteInventory(
      '{"DestinationPrefix":"10.21.1.0/24","InterfaceAlias":"VPN Other"}',
      windows: true,
    );
    expect(single.single.interfaceName, 'VPN Other');
    expect(findNativeRoomConflict('10.21.2.0/24', single), isNull);
    final routes = parseJsonRouteInventory('''[
      {"DestinationPrefix":"0.0.0.0/0","InterfaceAlias":"Ethernet"},
      {"DestinationPrefix":"10.21.3.5/32","InterfaceAlias":"P2WLAN"}
    ]''', windows: true);
    expect(
      findNativeRoomConflict('10.21.3.0/24', routes)?.cidr,
      '10.21.3.5/32',
    );
  });

  test('macOS netstat abbreviated subnet and host routes normalize', () {
    final routes = parseMacosRouteInventory('''Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            192.168.1.1         UGScg                 en0
10.21.1            10.21.1.2           UGSc                  utun3
10.21.1.2          10.21.1.2           UH                    utun3
127                127.0.0.1          UCS                   lo0
192.168.1/24       link#6             UCS                   en0
''');
    expect(routes.map((route) => route.cidr), [
      '10.21.1.0/24',
      '10.21.1.2/32',
      '127.0.0.0/8',
      '192.168.1.0/24',
    ]);
    expect(
      findNativeRoomConflict('10.21.1.0/24', routes)?.interfaceName,
      'utun3',
    );
  });

  test('only authenticated same-instance interface is exempted', () {
    const routes = [
      NativeIpv4Route('10.21.1.0/24', 'utun3'),
      NativeIpv4Route('10.21.1.128/25', 'utun4'),
    ];
    expect(
      findNativeRoomConflict(
        '10.21.1.0/24',
        routes,
        authenticatedInterface: 'utun3',
      )?.interfaceName,
      'utun4',
    );
    expect(
      findNativeRoomConflict(
        '10.21.1.0/24',
        routes.take(1).toList(),
        authenticatedInterface: 'utun3',
      ),
      isNull,
    );
    expect(
      findNativeRoomConflict(
        '10.21.1.0/24',
        routes,
        authenticatedInterface: '',
      ),
      isNotNull,
    );
  });

  test('room host route overlaps even when prefix strings differ', () {
    expect(nativeRouteOverlaps('10.21.1.0/24', '10.21.1.100/32'), isTrue);
    expect(nativeRouteOverlaps('10.21.1.0/24', '10.21.2.0/24'), isFalse);
    expect(nativeRouteOverlaps('10.21.1.0/24', '10.21.1.17/24'), isTrue);
  });

  test('split-default VPN route allows a more-specific room route', () {
    final routes = parseJsonRouteInventory(
      '[{"dst":"0.0.0.0/1","dev":"tun0"}]',
    );
    expect(findNativeRoomConflict('10.21.2.0/24', routes), isNull);
  });

  test(
    'macOS broad VPN route coexists with room but does not hide conflicts',
    () {
      final routes = parseMacosRouteInventory("""
Destination Gateway Flags Netif
8/5 172.18.0.1 UGSc utun97
""");
      expect(findNativeRoomConflict('10.21.1.0/24', routes), isNull);
      for (final cidr in ['10.21.1.0/24', '10.21.1.128/25', '10.21.1.7/32']) {
        final conflict = NativeIpv4Route(cidr, 'utun4');
        expect(
          findNativeRoomConflict('10.21.1.0/24', [...routes, conflict]),
          same(conflict),
        );
      }
    },
  );

  test('malformed inventories are not silently treated as conflict-free', () {
    for (final text in [
      'not json',
      'null',
      '[{}]',
      '[1]',
      '[{"dst":"bad"}]',
      '[{"dst":"10.21.0.0/16","dev":7}]',
    ]) {
      expect(() => parseJsonRouteInventory(text), throwsFormatException);
    }
    for (final text in [
      '',
      'Destination Gateway Flags\n',
      'Destination Gateway Flags Netif\n10.21.1 gateway',
    ]) {
      expect(() => parseMacosRouteInventory(text), throwsFormatException);
    }
    for (final prefix in [
      '10.21.0.0/33',
      '10.21.0.0/-1',
      '::/0',
      '256.21.1.0/24',
      '10.21.1.0/24/2',
    ]) {
      expect(() => normalizeRouteDestination(prefix), throwsFormatException);
    }
  });
}
