import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class _DialogNotifier extends Notifier<void> {
  @override
  void build() {}

  void showCustomAlert({required String title, required String message}) {
    final context = _buildContext;
    if (context == null || !context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final scheme = theme.colorScheme;
        final muted =
            theme.textTheme.bodyMedium?.color ??
            scheme.onSurface.withValues(alpha: 0.72);

        return AlertDialog(
          backgroundColor: scheme.surface,
          title: Text(title, style: TextStyle(color: scheme.onSurface)),
          content: Text(message, style: TextStyle(color: muted)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  BuildContext? _buildContext;
  void attachContext(BuildContext ctx) => _buildContext = ctx;
}

final dialogNotifierProvider = NotifierProvider<_DialogNotifier, void>(
  _DialogNotifier.new,
);
