import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'removeProfile updates the index before deleting template content',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gorion-profile-repository-test-',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });
      final repository = ProfileRepository(storageRootLoader: () async => root);
      final profilesDir = Directory(p.join(root.path, 'profiles'));
      await profilesDir.create(recursive: true);
      final templateFile = File(p.join(profilesDir.path, 'profile-1.json'));
      await templateFile.writeAsString('{}');
      final initialState = StoredProfilesState(
        activeProfileId: 'profile-1',
        profiles: [
          _profile(id: 'profile-1', templateFileName: 'profile-1.json'),
          _profile(id: 'profile-2', templateFileName: 'profile-2.json'),
        ],
      );
      await File(p.join(root.path, 'profiles.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(initialState.toJson()),
      );

      final next = await repository.removeProfile('profile-1');

      expect(next.activeProfileId, 'profile-2');
      expect(next.profiles.map((profile) => profile.id), ['profile-2']);
      expect(await templateFile.exists(), isFalse);

      final reloaded = await repository.loadState();
      expect(reloaded.activeProfileId, 'profile-2');
      expect(reloaded.profiles.map((profile) => profile.id), ['profile-2']);
    },
  );
}

ProxyProfile _profile({required String id, required String templateFileName}) {
  return ProxyProfile(
    id: id,
    name: 'Profile $id',
    subscriptionUrl: 'https://example.com/$id',
    templateFileName: templateFileName,
    createdAt: DateTime(2026, 4, 24),
    updatedAt: DateTime(2026, 4, 24),
    servers: const [
      ServerEntry(
        tag: 'server-1',
        displayName: 'Server 1',
        type: 'vless',
        host: 'example.com',
        port: 443,
      ),
    ],
  );
}
