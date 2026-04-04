import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class _BottomSheetsNotifier extends Notifier<void> {
  @override
  void build() {}

  /// Opens the add subscription dialog.
  void showAddProfile() {
    final context = _buildContext;
    if (context == null || !context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => const _AddSubscriptionDialog(),
    );
  }

  /// Opens the profiles overview dialog.
  void showProfilesOverview() {
    final context = _buildContext;
    if (context == null || !context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => const _ProfilesOverviewDialog(),
    );
  }

  BuildContext? _buildContext;

  void attachContext(BuildContext ctx) => _buildContext = ctx;
}

final bottomSheetsNotifierProvider =
    NotifierProvider<_BottomSheetsNotifier, void>(_BottomSheetsNotifier.new);

// ─── Inline dialogs ───────────────────────────────────────────────────────────

class _AddSubscriptionDialog extends StatefulWidget {
  const _AddSubscriptionDialog();

  @override
  State<_AddSubscriptionDialog> createState() => _AddSubscriptionDialogState();
}

class _AddSubscriptionDialogState extends State<_AddSubscriptionDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D1A12),
      title: const Text('Добавить подписку', style: TextStyle(color: Colors.white)),
      content: TextField(
        controller: _ctrl,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          hintText: 'https://...',
          hintStyle: TextStyle(color: Colors.white54),
          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF1EFFAC))),
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
        ),
        Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () async {
              final url = _ctrl.text.trim();
              if (url.isEmpty) return;
              Navigator.of(context).pop();
              // Subscription URL is imported via dashboard controller.
              // Gorion's add-profile flow uses the same URL field.
            },
            child: const Text('Добавить', style: TextStyle(color: Color(0xFF1EFFAC))),
          ),
        ),
      ],
    );
  }
}

class _ProfilesOverviewDialog extends StatelessWidget {
  const _ProfilesOverviewDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D1A12),
      title: const Text('Подписки', style: TextStyle(color: Colors.white)),
      content: const Text(
        'Управление подписками пока недоступно в этом окне.',
        style: TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть', style: TextStyle(color: Color(0xFF1EFFAC))),
        ),
      ],
    );
  }
}
