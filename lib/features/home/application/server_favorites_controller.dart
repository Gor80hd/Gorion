import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/data/server_favorites_repository.dart';

final serverFavoritesRepositoryProvider = Provider<ServerFavoritesRepository>(
  (ref) => ServerFavoritesRepository(),
);

final serverFavoritesProvider =
    StateNotifierProvider<ServerFavoritesController, Set<String>>((ref) {
      return ServerFavoritesController(
        repository: ref.read(serverFavoritesRepositoryProvider),
      );
    });

class ServerFavoritesController extends StateNotifier<Set<String>> {
  ServerFavoritesController({required ServerFavoritesRepository repository})
    : _repository = repository,
      super(const <String>{}) {
    unawaited(_restore());
  }

  final ServerFavoritesRepository _repository;
  bool _disposed = false;
  bool _hasLocalChange = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool contains(String key) => state.contains(key);

  Future<void> toggle(String key) async {
    if (key.isEmpty) {
      return;
    }

    _hasLocalChange = true;
    final previous = state;
    final next = {...state};
    if (!next.add(key)) {
      next.remove(key);
    }
    state = Set.unmodifiable(next);

    try {
      final stored = await _repository.save(state);
      if (!_disposed) {
        state = Set.unmodifiable(stored);
      }
    } catch (_) {
      if (!_disposed) {
        state = previous;
      }
    }
  }

  Future<void> _restore() async {
    try {
      final stored = await _repository.load();
      if (!_disposed && !_hasLocalChange) {
        state = Set.unmodifiable(stored);
      }
    } catch (_) {
      // Keep the in-memory default when storage is unavailable.
    }
  }
}
