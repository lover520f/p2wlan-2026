import 'dart:convert';
import 'dart:io';

class NativeIpv4Route {
  const NativeIpv4Route(this.cidr, this.interfaceName);

  final String cidr;
  final String interfaceName;
}

String? normalizeRouteDestination(String value) {
  if (value == 'default') return null;
  final parts = value.split('/');
  if (parts.length > 2) throw const FormatException('Invalid route prefix');
  final octets = parts.first.split('.');
  if (octets.isEmpty ||
      octets.length > 4 ||
      octets.any(
        (octet) =>
            int.tryParse(octet) == null ||
            int.parse(octet) < 0 ||
            int.parse(octet) > 255,
      )) {
    throw const FormatException('Invalid IPv4 route');
  }
  final prefix = parts.length == 2 ? int.tryParse(parts[1]) : octets.length * 8;
  if (prefix == null || prefix < 0 || prefix > 32) {
    throw const FormatException('Invalid route prefix');
  }
  if (prefix == 0) return null;
  return '${[...octets, ...List.filled(4 - octets.length, '0')].join('.')}/$prefix';
}

List<NativeIpv4Route> parseJsonRouteInventory(
  String text, {
  bool windows = false,
}) {
  final decoded = jsonDecode(text);
  final rows = decoded is List
      ? decoded
      : decoded is Map
      ? [decoded]
      : null;
  if (rows == null) throw const FormatException('Invalid route inventory');
  final routes = <NativeIpv4Route>[];
  for (final row in rows) {
    if (row is! Map) throw const FormatException('Invalid route entry');
    final raw = row[windows ? 'DestinationPrefix' : 'dst'];
    final interfaceName = row[windows ? 'InterfaceAlias' : 'dev'];
    if (raw is! String) {
      throw const FormatException('Missing route destination');
    }
    final cidr = normalizeRouteDestination(raw);
    if (cidr == null) continue;
    if (interfaceName != null && interfaceName is! String) {
      throw const FormatException('Invalid route interface');
    }
    routes.add(NativeIpv4Route(cidr, interfaceName as String? ?? ''));
  }
  return routes;
}

List<NativeIpv4Route> parseMacosRouteInventory(String text) {
  final routes = <NativeIpv4Route>[];
  int? interfaceIndex;
  for (final line in const LineSplitter().convert(text)) {
    final columns = line.trim().split(RegExp(r'\s+'));
    if (columns.first == 'Destination') {
      final index = columns.indexOf('Netif');
      if (index < 0) throw const FormatException('Missing Netif column');
      interfaceIndex = index;
      continue;
    }
    if (interfaceIndex == null || line.trim().isEmpty) continue;
    if (columns.length <= interfaceIndex) {
      throw const FormatException('Truncated route entry');
    }
    final cidr = normalizeRouteDestination(columns.first);
    if (cidr != null) {
      routes.add(NativeIpv4Route(cidr, columns[interfaceIndex]));
    }
  }
  if (interfaceIndex == null) {
    throw const FormatException('Missing route table');
  }
  return routes;
}

bool nativeRouteOverlaps(String left, String right) {
  (int, int) range(String cidr) {
    final parts = cidr.split('/');
    if (parts.length != 2) throw const FormatException('Invalid CIDR');
    final address = InternetAddress.tryParse(parts.first);
    final prefix = int.tryParse(parts.last);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        prefix == null ||
        prefix < 0 ||
        prefix > 32) {
      throw const FormatException('Invalid CIDR');
    }
    final value = address.rawAddress.fold<int>(
      0,
      (value, byte) => (value << 8) | byte,
    );
    final mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;
    final first = value & mask;
    return (first, first | (0xffffffff ^ mask));
  }

  final a = range(left);
  final b = range(right);
  return a.$1 <= b.$2 && b.$1 <= a.$2;
}

NativeIpv4Route? findNativeRoomConflict(
  String cidr,
  List<NativeIpv4Route> routes, {
  String? authenticatedInterface,
}) {
  for (final route in routes) {
    if (authenticatedInterface != null &&
        authenticatedInterface.isNotEmpty &&
        route.interfaceName == authenticatedInterface) {
      continue;
    }
    if (nativeRouteOverlaps(cidr, route.cidr)) return route;
  }
  return null;
}

String nativeRoomConflictMessage(String roomCidr, NativeIpv4Route conflict) {
  final interface = conflict.interfaceName.isEmpty
      ? '未标明接口的路由'
      : '接口 ${conflict.interfaceName}';
  return '房间网段 $roomCidr 与本机 $interface 的 ${conflict.cidr} 重叠。'
      '房间已加入，但尚未连接；请先断开使用该网段的其他 VPN，或检查旧连接是否已退出。'
      '不会自动删除现有路由。';
}
