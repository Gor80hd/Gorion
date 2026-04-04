import 'package:gorion_clean/features/profiles/model/profile_models.dart';

/// Home-page-compatible profile view, wrapping [ProxyProfile].
class ProfileEntity {
  const ProfileEntity(this._profile);

  final ProxyProfile _profile;

  String get id => _profile.id;
  String get name => _profile.name;
  DateTime get lastUpdate => _profile.updatedAt;

  /// All profiles have a subscription URL in gorion_clean → always a remote profile.
  bool get isRemote => true;

  /// No per-profile show/hide override in gorion_clean; always visible.
  UserOverride? get userOverride => null;

  @override
  bool operator ==(Object other) => other is ProfileEntity && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class UserOverride {
  const UserOverride({required this.showOnHome});
  final bool showOnHome;
}

/// Subclass that marks a profile as remote for `isRemoteProfile` checks.
class RemoteProfileEntity extends ProfileEntity {
  const RemoteProfileEntity(super.profile);
}

/// Converts a [ProxyProfile] to [ProfileEntity].
ProfileEntity profileToEntity(ProxyProfile profile) =>
    RemoteProfileEntity(profile);
