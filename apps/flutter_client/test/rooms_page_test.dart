import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2wlan_flutter_client/core/capabilities/platform_capabilities.dart';
import 'package:p2wlan_flutter_client/core/api/diagnostics_api.dart';
import 'package:p2wlan_flutter_client/core/models/diagnostics_models.dart';
import 'package:p2wlan_flutter_client/core/rooms/room_api.dart';
import 'package:p2wlan_flutter_client/core/security/secure_token_repository.dart';
import 'package:p2wlan_flutter_client/core/state/settings_store.dart';
import 'package:p2wlan_flutter_client/core/state/status_store.dart';
import 'package:p2wlan_flutter_client/features/rooms/rooms_page.dart';

const _roomId = 'room-0123456789abcdef0123456789abcdef';
Map<String, dynamic> _room(String role) => {
  'id': _roomId,
  'room_code': '12345678',
  'name': '朋友房间',
  'cidr': '10.21.1.0/24',
  'owner_id': 'owner',
  'role': role,
  'join_locked': false,
};

class _FakeRoomApi extends RoomApi {
  _FakeRoomApi({this.role = 'owner', this.empty = false})
    : super(server: 'https://control.example', token: 'account-token');
  final String role;
  bool empty;
  final calls = <String>[];
  @override
  Future<List<FriendRoom>> list() async {
    userId = role == 'owner' ? 'owner' : 'member';
    return empty ? [] : [FriendRoom.fromJson(_room(role))];
  }

  @override
  Future<RoomRoster> roster(String room) async => RoomRoster.fromJson({
    'room': _room(role),
    'members': [
      {'user_id': 'owner', 'role': 'owner'},
      {'user_id': 'member', 'role': 'member'},
    ],
    'devices': [
      {
        'id': 'device-1',
        'user_id': 'member',
        'device_name': '好友电脑',
        'virtual_ip': '10.21.1.3',
        'online': true,
      },
    ],
    'banned_user_ids': [],
  });
  @override
  Future<Map<String, dynamic>> request(
    String method,
    List<String> segments, [
    Map<String, dynamic>? payload,
  ]) async {
    calls.add('$method ${segments.join('/')} ${jsonEncode(payload)}');
    if (method == 'GET' && segments.last == 'invites') return {'invites': []};
    return {'success': true};
  }

  @override
  Future<FriendRoom> create(String name, String password) async {
    calls.add('create:$name:$password');
    empty = false;
    return FriendRoom.fromJson(_room('owner'));
  }

  @override
  Future<FriendRoom> join(
    String code, {
    String? password,
    String? invitation,
  }) async {
    calls.add('join:$code:$password:$invitation');
    return FriendRoom.fromJson(_room('member'));
  }
}

void main() {
  Future<_FakeRoomApi> pump(
    WidgetTester tester, {
    String role = 'owner',
    bool empty = false,
    Uri? invitation,
  }) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('p2wlan-rooms-ui-'),
    );
    final settings = SettingsStore(
      settingsFile: File('${dir!.path}/settings.json'),
      tokenRepository: InMemorySecureTokenRepository(),
    );
    await tester.runAsync(() async {
      await settings.load();
      await settings.updateSettings(
        const AppSettings(
          controlServer: 'https://control.example',
          authToken: 'account-token',
          onboardingCompleted: true,
        ),
      );
    });
    final status = StatusStore(
      settingsStore: settings,
      diagnosticsApi: DiagnosticsApi(),
      enableFreshnessTimer: false,
    );
    final api = _FakeRoomApi(role: role, empty: empty);
    addTearDown(() {
      api.close();
      status.dispose();
      settings.dispose();
      dir.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: RoomsPage(
          settingsStore: settings,
          statusStore: status,
          api: api,
          capabilities: PlatformCapabilities.fromPlatform('ios'),
          initialInvitation: invitation,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets(
    'owner controls and explicit single active network scope are visible',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pump(tester);
      expect(find.textContaining('每台设备同时连接一个网络'), findsOneWidget);
      expect(find.text('解散房间'), findsOneWidget);
      expect(find.text('邀请管理'), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      expect(find.text('创建房间'), findsOneWidget);
      final create = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '创建房间'),
      );
      expect(create.onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'members have no owner controls and compact layout has no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pump(tester, role: 'member');
      expect(find.text('解散房间'), findsNothing);
      expect(find.text('邀请管理'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.text('退出房间'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('create validates password and disposes the form after closing', (
    tester,
  ) async {
    final api = await pump(tester, empty: true);
    await tester.tap(find.text('创建房间'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('房间名称')), '一起玩');
    await tester.enterText(find.byKey(const ValueKey('房间密码')), 'short');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(api.calls.where((call) => call.startsWith('create:')), isEmpty);
    expect(find.text('密码需为 8–72 字节'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('房间密码')), 'password123');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('create:一起玩:password123'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'deep link never joins before confirmation and rejects other servers',
    (tester) async {
      final invitation = RoomInvitation(
        'https://evil.example',
        '12345678',
        List.filled(64, 'a').join(),
      ).toUri();
      final api = await pump(tester, invitation: invitation);
      expect(api.calls.where((call) => call.startsWith('join:')), isEmpty);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.textContaining('邀请来自其他控制服务器'), findsOneWidget);
      expect(api.calls.where((call) => call.startsWith('join:')), isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'room password join uses only the explicitly entered credentials',
    (tester) async {
      final api = await pump(tester);
      await tester.tap(find.text('房间号加入'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('房间号')), '87654321');
      await tester.enterText(find.byKey(const ValueKey('房间密码')), 'password456');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('join:87654321:password456:null'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
