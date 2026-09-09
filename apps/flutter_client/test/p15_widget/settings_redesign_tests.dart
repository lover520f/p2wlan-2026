part of '../p15_widget_test.dart';

void _registerSettingsRedesignTests() {
  testWidgets(
    'Settings redesign: undo is scoped and keeps immediate preferences',
    (tester) async {
      final stores = await _pumpSettings(
        tester,
        api: _FakeDiagnosticsApi(health: false),
      );
      final originalName = stores.settingsStore.settings.deviceName;
      await _openCategory(tester, 'Advanced Network');
      await tester.enterText(_settingsTextField('MTU'), '1301');
      await tester.pump();
      await _openCategory(tester, 'General');
      expect(
        find.byKey(const ValueKey('settings-close-behavior-select')),
        findsOneWidget,
      );
      await tester.enterText(
        _settingsTextField('Device name'),
        'changed-device',
      );
      await tester.pump();
      await _openAppSelect(tester, const ValueKey('settings-theme-select'));
      await tester.tap(find.text('Dark'));
      await tester.pump();
      await _waitForSaveComplete(
        tester,
        const ValueKey('settings-theme-select'),
      );
      expect(find.text('Theme saved'), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-undo-button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(_settingsTextField('Device name'))
            .controller!
            .text,
        originalName,
      );
      expect(stores.settingsStore.settings.themeMode, 'dark');
      expect(find.byKey(const Key('settings-save-button')), findsNothing);
      await _openCategory(tester, 'Advanced Network');
      expect(
        tester.widget<TextField>(_settingsTextField('MTU')).controller!.text,
        '1301',
      );
      expect(find.byKey(const Key('settings-save-button')), findsOneWidget);
    },
  );

  testWidgets('Settings redesign: restart impact precedes save', (
    tester,
  ) async {
    final snapshot = (await tester.runAsync(_loadFixtureSnapshot))!;
    final stores = await _pumpSettings(
      tester,
      api: _FakeDiagnosticsApi(health: true, snapshot: snapshot),
    );
    await stores.statusStore.refresh();
    await _openCategory(tester, 'Advanced Network');
    await tester.enterText(_settingsTextField('MTU'), '1302');
    await tester.pump();
    expect(
      find.text(AppStrings.fromCode('en').settingsReconnectImpact),
      findsOneWidget,
    );
    expect(stores.settingsStore.settings.mtu, isNot(1302));
    await tester.tap(find.byKey(const Key('settings-undo-button')));
    await tester.pumpAndSettle();
    expect(
      find.text(AppStrings.fromCode('en').settingsReconnectImpact),
      findsNothing,
    );
  });

  testWidgets('Settings redesign: build details collapse and copy as a whole', (
    tester,
  ) async {
    await _pumpSettings(tester, api: _FakeDiagnosticsApi(health: false));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _openCategory(tester, 'Diagnostics & About');
    final expansion = find.byKey(
      const PageStorageKey('settings-build-details'),
    );
    await tester.ensureVisible(expansion);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-copy-build-details')), findsNothing);
    await tester.tap(find.text('Build details'));
    await tester.pumpAndSettle();
    final copy = find.byKey(const Key('settings-copy-build-details'));
    await tester.ensureVisible(copy);
    await tester.pumpAndSettle();
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied, contains(AppStrings.fromCode('en').buildCommitLabel));
    expect(copied, contains(AppStrings.fromCode('en').buildIdLabel));
  });

  for (final variant in [
    (const Size(1280, 900), false, 1.0, 'desktop-light'),
    (const Size(900, 800), true, 1.0, 'desktop-dark'),
    (const Size(390, 844), false, 1.0, 'mobile'),
    (const Size(320, 740), true, 1.5, 'narrow-large-text'),
  ]) {
    testWidgets('Settings redesign: layout ${variant.$4}', (tester) async {
      const capture = bool.fromEnvironment('SETTINGS_SCREENSHOTS');
      final stores = (await tester.runAsync(
        () => _makeStores(api: _FakeDiagnosticsApi(health: false)),
      ))!;
      addTearDown(stores.dispose);
      await tester.runAsync(
        () => stores.settingsStore.updateLanguageCode('zh-Hans'),
      );
      tester.view.physicalSize = variant.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (capture) {
        await tester.runAsync(() async {
          final bytes = await File(
            const String.fromEnvironment('SETTINGS_PREVIEW_FONT'),
          ).readAsBytes();
          for (final family in [
            'PreviewFont',
            'Ahem',
            'Roboto',
            'SF Pro Text',
            'PingFang SC',
          ]) {
            final loader = FontLoader(family)
              ..addFont(Future.value(ByteData.sublistView(bytes)));
            await loader.load();
          }
          final icons = await File(
            'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
          ).readAsBytes();
          await (FontLoader(
            'MaterialIcons',
          )..addFont(Future.value(ByteData.sublistView(icons)))).load();
        });
      }
      final boundary = GlobalKey();
      final theme = variant.$2 ? AppTheme.darkTheme : AppTheme.lightTheme;
      await tester.pumpWidget(
        MaterialApp(
          theme: capture
              ? theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: 'PreviewFont'),
                  primaryTextTheme: theme.primaryTextTheme.apply(
                    fontFamily: 'PreviewFont',
                  ),
                  appBarTheme: theme.appBarTheme.copyWith(
                    titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                      fontFamily: 'PreviewFont',
                    ),
                  ),
                  outlinedButtonTheme: OutlinedButtonThemeData(
                    style: theme.outlinedButtonTheme.style?.copyWith(
                      textStyle: const WidgetStatePropertyAll(
                        TextStyle(fontFamily: 'PreviewFont', fontSize: 13),
                      ),
                    ),
                  ),
                  textButtonTheme: TextButtonThemeData(
                    style: theme.textButtonTheme.style?.copyWith(
                      textStyle: const WidgetStatePropertyAll(
                        TextStyle(fontFamily: 'PreviewFont', fontSize: 13),
                      ),
                    ),
                  ),
                  filledButtonTheme: FilledButtonThemeData(
                    style: theme.filledButtonTheme.style?.copyWith(
                      textStyle: const WidgetStatePropertyAll(
                        TextStyle(fontFamily: 'PreviewFont', fontSize: 13),
                      ),
                    ),
                  ),
                )
              : theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(variant.$3)),
            child: RepaintBoundary(key: boundary, child: child!),
          ),
          home: Scaffold(
            backgroundColor: theme.colorScheme.surfaceContainerLow,
            body: SettingsPage(
              settingsStore: stores.settingsStore,
              statusStore: stores.statusStore,
              capabilities: PlatformCapabilities.fromPlatform(
                variant.$1.width < 500 ? 'android' : 'macos',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final category in ['通用', '账户与连接', '高级网络', '诊断与关于']) {
        // Mobile routes use the native back control.
        final back = find.byKey(const Key('settings-mobile-category-back'));
        if (back.evaluate().isNotEmpty) {
          await tester.tap(back);
          await tester.pumpAndSettle();
        }
        await _openCategory(tester, category);
        expect(tester.takeException(), isNull);
        if (capture) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final dir = Directory('/tmp/p2wlan-settings-preview');
            await dir.create(recursive: true);
            await File('${dir.path}/${variant.$4}-$category.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        // Exercise long forms all the way down, including scaled text.
        final list = find.byType(ListView).last;
        await tester.drag(list, const Offset(0, -1400));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(ListView), findsWidgets);
      }
    });
  }
}
