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
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0D1A12),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(message, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(color: Color(0xFF1EFFAC))),
          ),
        ],
      ),
    );
  }

  BuildContext? _buildContext;
  void attachContext(BuildContext ctx) => _buildContext = ctx;
}

final dialogNotifierProvider =
    NotifierProvider<_DialogNotifier, void>(_DialogNotifier.new);
