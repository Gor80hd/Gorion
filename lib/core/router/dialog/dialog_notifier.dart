import 'package:flutter/material.dart';

class AppAlertDialog extends StatelessWidget {
  const AppAlertDialog({
    super.key,
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
