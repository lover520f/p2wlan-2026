part of '../daemon_controller.dart';

extension DaemonControllerRoomRoutes on DaemonController {
  Future<String?> roomRouteConflict(
    String cidr, {
    String? authenticatedInterface,
  }) async {
    try {
      final ProcessResult result;
      if (Platform.isWindows) {
        result = await _runWindowsPowerShell(
          r'''@(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop) | Select-Object DestinationPrefix,InterfaceAlias | ConvertTo-Json -Compress''',
        );
      } else if (Platform.isLinux || Platform.isMacOS) {
        result = await _queryRoomRoutes(
          Platform.isLinux ? 'ip' : '/usr/sbin/netstat',
          Platform.isLinux
              ? ['-j', '-4', 'route', 'show', 'table', 'all']
              : ['-rn', '-f', 'inet'],
        );
      } else {
        return '当前平台无法检查本机路由冲突';
      }
      if (result.exitCode != 0) return '无法读取本机 IPv4 路由，未启动房间';
      final routes = Platform.isMacOS
          ? parseMacosRouteInventory(result.stdout.toString())
          : parseJsonRouteInventory(
              result.stdout.toString(),
              windows: Platform.isWindows,
            );
      final conflict = findNativeRoomConflict(
        cidr,
        routes,
        authenticatedInterface: authenticatedInterface,
      );
      return conflict == null ? null : '房间网段与本机现有路由重叠，未修改现有网络';
    } catch (_) {
      return '无法确认本机路由无冲突，未启动房间';
    }
  }

  Future<ProcessResult> _queryRoomRoutes(
    String executable,
    List<String> args,
  ) async {
    final process = await Process.start(executable, args);
    try {
      final result = await Future.wait<Object>([
        process.stdout.transform(systemEncoding.decoder).join(),
        process.stderr.transform(systemEncoding.decoder).join(),
        process.exitCode,
      ]).timeout(const Duration(seconds: 10));
      return ProcessResult(process.pid, result[2] as int, result[0], result[1]);
    } on TimeoutException {
      process.kill();
      return ProcessResult(process.pid, 1, '', 'route query timed out');
    }
  }
}
