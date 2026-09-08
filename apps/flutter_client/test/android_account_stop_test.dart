import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2wlan_flutter_client/core/api/diagnostics_api.dart';
import 'package:p2wlan_flutter_client/core/daemon/daemon_controller.dart';

class _Transport implements AndroidVpnTransport {
  bool accepted = true;
  bool statusUnavailable = false;
  int reads = 0;
  @override
  Future<bool> prepareVpn() async => true;
  @override
  Future<bool> start(String json) async => true;
  @override
  Future<bool> stop() async => accepted;
  @override
  Future<AndroidVpnStatus> status() async {
    reads++;
    if (statusUnavailable) throw StateError('bridge unavailable');
    return const AndroidVpnStatus(
      serviceRunning: false,
      nativeRunning: false,
      nativeReady: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'unreadable Android status cannot authorize an account switch',
    () async {
      final transport = _Transport()..statusUnavailable = true;
      final api = DiagnosticsApi();
      addTearDown(api.close);
      final controller = DaemonController(
        diagnosticsApi: api,
        androidVpnTransport: transport,
      );
      final result = await controller.stopAndroidVpnForTesting();
      expect(result.ok, isFalse);
      expect(result.message, contains('无法确认'));
    },
  );
  test('rejected Android stop does not treat old VPN as gone', () async {
    final transport = _Transport()..accepted = false;
    final api = DiagnosticsApi();
    addTearDown(api.close);
    final result = await DaemonController(
      diagnosticsApi: api,
      androidVpnTransport: transport,
    ).stopAndroidVpnForTesting();
    expect(result.ok, isFalse);
    expect(transport.reads, 0);
  });
  test('explicit native stopped state allows completion', () async {
    final transport = _Transport();
    final api = DiagnosticsApi();
    addTearDown(api.close);
    final result = await DaemonController(
      diagnosticsApi: api,
      androidVpnTransport: transport,
    ).stopAndroidVpnForTesting();
    expect(result.ok, isTrue);
    expect(transport.reads, 1);
  });
  test('null or malformed platform response is not an offline VPN', () async {
    const channel = MethodChannel('p2wlan/test_android_account_status');
    const transport = MethodChannelAndroidVpnTransport(channel: channel);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (final response in [
      null,
      <String, Object?>{},
      {'nativeRunning': 'false'},
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => response);
      await expectLater(transport.status(), throwsA(isA<PlatformException>()));
    }
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'nativeRunning': false},
    );
    expect((await transport.status()).nativeRunning, isFalse);
  });
}
