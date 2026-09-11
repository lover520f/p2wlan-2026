import 'dart:async';

import 'package:flutter/material.dart';

final _activeNotices = Expando<OverlayEntry>();

/// Displays a single non-modal notification near the upper center.
void showAppNotice(
  BuildContext context, {
  required Widget content,
  Duration duration = const Duration(seconds: 4),
}) {
  if (!context.mounted) return;
  final overlay = Navigator.of(context, rootNavigator: true).overlay!;
  _activeNotices[overlay]?.remove();
  late final OverlayEntry entry;
  void dismiss() {
    if (_activeNotices[overlay] != entry) return;
    _activeNotices[overlay] = null;
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (_) =>
        _Notice(content: content, duration: duration, dismiss: dismiss),
  );
  _activeNotices[overlay] = entry;
  overlay.insert(entry);
}

class _Notice extends StatefulWidget {
  const _Notice({
    required this.content,
    required this.duration,
    required this.dismiss,
  });
  final Widget content;
  final Duration duration;
  final VoidCallback dismiss;
  @override
  State<_Notice> createState() => _NoticeState();
}

class _NoticeState extends State<_Notice> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, widget.dismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final topInset = (MediaQuery.sizeOf(context).height * .12).clamp(
      24.0,
      96.0,
    );
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, topInset, 20, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 180),
              builder: (context, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, -8 * (1 - value)),
                  child: child,
                ),
              ),
              child: Stack(
                children: [
                  IgnorePointer(
                    child: Material(
                      color: colors.surfaceContainerHigh,
                      elevation: 8,
                      shadowColor: colors.shadow.withValues(alpha: .16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: colors.outlineVariant),
                      ),
                      child: Semantics(
                        liveRegion: true,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 12, 52, 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.info_outline_rounded,
                                color: colors.primary,
                                size: 22,
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: IntrinsicHeight(
                                  child: DefaultTextStyle(
                                    style: theme.textTheme.bodyMedium!.copyWith(
                                      color: colors.onSurface,
                                    ),
                                    child: widget.content,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: widget.dismiss,
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
