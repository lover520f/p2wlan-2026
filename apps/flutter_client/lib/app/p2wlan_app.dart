import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app/desktop_tray_controller.dart';
import '../app/desktop_window_status_controller.dart';
import '../app/app_strings.dart';
import '../app/app_theme.dart';
import '../app/p2wlan_colors.dart';
import '../core/api/diagnostics_api.dart';
import '../core/capabilities/platform_capabilities.dart';
import '../core/daemon/daemon_controller.dart';
import '../core/models/diagnostics_models.dart';
import '../core/state/settings_store.dart';
import '../core/state/status_store.dart';
import '../features/auth/login_page.dart';
import '../features/rooms/rooms_page.dart';
import '../core/rooms/room_profiles.dart';
import '../features/onboarding/onboarding_page.dart';
import '../shared/widgets/windows_window_controls.dart';
import 'app_constants.dart';
import 'navigation.dart';

class P2WlanApp extends StatefulWidget {
  const P2WlanApp({
    super.key,
    this.initialRefresh = true,
    this.roomLinks,
    this.autoStartPolling = true,
    this.settingsStore,
    this.diagnosticsApi,
    this.daemonController,
    this.enableDesktopTray = false,
    this.enableDesktopTaskbarStatus = false,
  });

  final bool initialRefresh;
  final Stream<Uri>? roomLinks;
  final bool autoStartPolling;
  final SettingsStore? settingsStore;
  final DiagnosticsApi? diagnosticsApi;
  final DaemonController? daemonController;
  final bool enableDesktopTray;
  final bool enableDesktopTaskbarStatus;

  @override
  State<P2WlanApp> createState() => _P2WlanAppState();
}

class _P2WlanAppState extends State<P2WlanApp> with WidgetsBindingObserver {
  late final SettingsStore _settingsStore;
  late final StatusStore _statusStore;
  DesktopTrayController? _desktopTrayController;
  DesktopWindowStatusController? _desktopWindowStatusController;
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<Uri>? _roomLinkSubscription;
  Uri? _pendingRoomLink;
  bool _openingRoomLink = false;
  var _ready = false;
  var _authenticated = false;

  @override
  void initState() {
    super.initState();
    _settingsStore = widget.settingsStore ?? SettingsStore();
    _statusStore = StatusStore(
      settingsStore: _settingsStore,
      diagnosticsApi: widget.diagnosticsApi ?? DiagnosticsApi(),
      daemonController: widget.daemonController,
      enableFreshnessTimer: true,
      autoRefreshInterval: StatusStore.defaultActivePollingInterval,
      startupCatalogRefreshTimeout: Platform.isWindows
          ? StatusStore.defaultWindowsStartupCatalogRefreshTimeout
          : StatusStore.defaultStartupCatalogRefreshTimeout,
      startupCatalogRefreshInterval: Platform.isWindows
          ? StatusStore.defaultWindowsStartupCatalogRefreshInterval
          : StatusStore.defaultStartupCatalogRefreshInterval,
      routeVerificationInterval: Platform.isWindows
          ? StatusStore.defaultWindowsRouteVerificationInterval
          : StatusStore.defaultRouteVerificationInterval,
    );
    _roomLinkSubscription = widget.roomLinks?.listen((uri) {
      if (uri.scheme != 'p2wlan' ||
          uri.host != 'join' ||
          uri.toString().length > 4096)
        return;
      _pendingRoomLink = uri;
      _scheduleRoomLink();
    }, onError: (Object _) {});
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _statusStore.updateAppLifecycleState(state);
  }

  Future<void> _bootstrap() async {
    writeDesktopTrayLifecycleTrace('bootstrap.begin');
    await _settingsStore.load();
    writeDesktopTrayLifecycleTrace('bootstrap.settings-loaded');
    final authToken = _settingsStore.settings.authToken.trim();
    _authenticated =
        _settingsStore.settings.manualMode ||
        (authToken.isNotEmpty && !isAuthTokenExpired(authToken));
    if (mounted) {
      setState(() => _ready = true);
    }
    writeDesktopTrayLifecycleTrace('bootstrap.ready');
    if (widget.enableDesktopTray && DesktopTrayController.isSupported) {
      writeDesktopTrayLifecycleTrace('bootstrap.tray-controller.begin');
      _desktopTrayController = DesktopTrayController(
        settingsStore: _settingsStore,
        statusStore: _statusStore,
      );
      writeDesktopTrayLifecycleTrace('bootstrap.tray-controller.created');
      final trayInitialization = _desktopTrayController!.initialize();
      writeDesktopTrayLifecycleTrace('bootstrap.tray-initialize.started');
      if (_isWindowsTrayNoAdapterExitTest) {
        // This is used only by the Windows release acceptance harness. It
        // enters through the same tray bootstrap and quit path as a real
        // packaged desktop app, while the harness deliberately provides no
        // virtual adapter or running daemon.
        await trayInitialization;
        writeDesktopTrayLifecycleTrace('bootstrap.tray-initialize.completed');
        final tray = _desktopTrayController;
        if (tray != null) {
          writeDesktopTrayLifecycleTrace('bootstrap.tray-quit.begin');
          await tray.quitForLifecycleTest();
          writeDesktopTrayLifecycleTrace('bootstrap.tray-quit.end');
        }
        // Do not start the normal daemon polling loop after the lifecycle
        // probe has entered the real packaged tray quit path.
        return;
      } else {
        unawaited(trayInitialization);
      }
    } else if (widget.enableDesktopTaskbarStatus &&
        DesktopWindowStatusController.isSupported) {
      _desktopWindowStatusController = DesktopWindowStatusController(
        statusStore: _statusStore,
      );
      unawaited(_desktopWindowStatusController!.initialize());
    }
    // Mobile/web builds are remote-management clients. They do not ship a
    // local diagnostics daemon, so polling the desktop default
    // 127.0.0.1:39277 would manufacture a "local service unavailable" state
    // on every Android/iOS launch.
    final canPollLocalDaemon = _capabilities.canActAsLocalVpnNode;
    if (widget.autoStartPolling && canPollLocalDaemon) {
      _statusStore.startPolling();
    } else if (widget.initialRefresh && canPollLocalDaemon) {
      unawaited(_statusStore.refreshUntilPeerCatalogSettled(silent: true));
    }
  }

  bool get _isWindowsTrayNoAdapterExitTest {
    return Platform.isWindows &&
        Platform.environment['P2WLAN_WINDOWS_TRAY_LIFECYCLE_TEST']?.trim() ==
            'no-adapter-exit';
  }

  void _scheduleRoomLink() {
    if (!_ready ||
        !_authenticated ||
        _needsOnboarding ||
        _openingRoomLink ||
        _pendingRoomLink == null)
      return;
    _openingRoomLink = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final navigator = _navigatorKey.currentState;
      if (!mounted || !_authenticated || navigator == null) {
        _openingRoomLink = false;
        return;
      }
      final invitation = _pendingRoomLink;
      _pendingRoomLink = null;
      try {
        await navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => RoomsPage(
              settingsStore: _settingsStore,
              statusStore: _statusStore,
              initialInvitation: invitation,
            ),
          ),
        );
      } finally {
        _openingRoomLink = false;
        if (mounted) _scheduleRoomLink();
      }
    });
  }

  Future<void> _logout() async {
    final settings = _settingsStore.settings;
    if (isRoomNetwork(settings.networkId) &&
        _capabilities.canActAsLocalVpnNode) {
      final stopped = await _statusStore.stopDaemon();
      if (!stopped.ok) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('本地房间网络未能停止，退出登录已取消。请先停止本地网络服务。')),
        );
        return;
      }
    }
    _pendingRoomLink = null;
    await _settingsStore.updateSettings(
      (isRoomNetwork(settings.networkId)
              ? personalNetworkSettings(settings)
              : settings)
          .copyWith(authToken: '', manualMode: false),
    );
    await _statusStore.refresh();
    if (mounted) {
      setState(() {
        _authenticated = false;
      });
    }
  }

  @override
  void dispose() {
    unawaited(_roomLinkSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_desktopTrayController?.dispose());
    _desktopWindowStatusController?.dispose();
    _statusStore.dispose();
    _settingsStore.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _settingsStore,
      builder: (context, _) {
        final modeCode = _settingsStore.settings.themeMode;
        final themeMode = switch (modeCode) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
        final strings = AppStrings.fromCode(
          _settingsStore.settings.languageCode,
        );
        _scheduleRoomLink();
        return MaterialApp(
          navigatorKey: _navigatorKey,
          scaffoldMessengerKey: _messengerKey,
          title: p2wlanAppName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeMode,
          builder: (context, child) {
            final content = child ?? const SizedBox.shrink();
            if (kIsWeb || !Platform.isWindows) return content;

            // Hidden Windows title bars still need a native resize hit area at
            // the top edge. The package frame preserves that behavior while
            // leaving the entire visible caption to Flutter.
            return Stack(
              fit: StackFit.expand,
              children: [
                VirtualWindowFrame(child: content),
                const Positioned(
                  top: 0,
                  right: 0,
                  child: WindowsWindowControls(),
                ),
              ],
            );
          },
          home: AppStringsScope(
            strings: strings,
            child: !_ready
                ? const _BootScreen()
                : _authenticated
                ? _needsOnboarding
                      ? OnboardingPage(
                          settingsStore: _settingsStore,
                          statusStore: _statusStore,
                          capabilities: _capabilities,
                          onCompleted: () {
                            if (mounted) setState(() {});
                          },
                        )
                      : P2WlanShell(
                          settingsStore: _settingsStore,
                          statusStore: _statusStore,
                          capabilities: _capabilities,
                          onLogout: _logout,
                        )
                : LoginPage(
                    settingsStore: _settingsStore,
                    statusStore: _statusStore,
                    capabilities: _capabilities,
                    onAuthenticated: () {
                      if (mounted) {
                        setState(() => _authenticated = true);
                      }
                    },
                  ),
          ),
        );
      },
    );
  }

  /// Platform capability, decided once. Pages read this rather than branching
  /// on Platform.isX.
  late final PlatformCapabilities _capabilities =
      PlatformCapabilities.current();

  /// Local-node first-run flow is required when the platform can act as a VPN
  /// node and the device has not finished onboarding yet. Remote-only
  /// platforms (mobile/web) skip straight to the shell.
  bool get _needsOnboarding =>
      _capabilities.canActAsLocalVpnNode &&
      !_settingsStore.settings.onboardingCompleted;
}

class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (!kIsWeb && Platform.isWindows)
            const Positioned(
              top: 0,
              left: 0,
              right: WindowsWindowControls.width,
              height: 56,
              child: DragToMoveArea(child: SizedBox.expand()),
            ),
          Center(
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  P2WlanColors.of(context).textMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
