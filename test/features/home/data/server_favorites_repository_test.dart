import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/home/data/server_favorites_repository.dart';

void main() {
  late Directory tempDir;
  late ServerFavoritesRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gorion-favorites-');
    repository = ServerFavoritesRepository(
      storageRootLoader: () async {
        return tempDir;
      },
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('persists favorite server keys', () async {
    await repository.save({'profile-1::server-a', 'profile-2::server-b'});

    final loaded = await repository.load();

    expect(loaded, {'profile-1::server-a', 'profile-2::server-b'});
  });
}
