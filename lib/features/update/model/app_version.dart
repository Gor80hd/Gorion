class AppVersion implements Comparable<AppVersion> {
  const AppVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.preRelease,
  });

  final int major;
  final int minor;
  final int patch;
  final String? preRelease;

  static final RegExp _versionPattern = RegExp(
    r'(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?',
  );

  static AppVersion? tryParse(String raw) {
    final normalized = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
    if (normalized.isEmpty) {
      return null;
    }

    final match = _versionPattern.firstMatch(normalized);
    if (match == null) {
      return null;
    }

    final major = int.tryParse(match.group(1) ?? '');
    if (major == null) {
      return null;
    }

    return AppVersion(
      major: major,
      minor: int.tryParse(match.group(2) ?? '') ?? 0,
      patch: int.tryParse(match.group(3) ?? '') ?? 0,
      preRelease: match.group(4),
    );
  }

  @override
  int compareTo(AppVersion other) {
    final majorComparison = major.compareTo(other.major);
    if (majorComparison != 0) {
      return majorComparison;
    }

    final minorComparison = minor.compareTo(other.minor);
    if (minorComparison != 0) {
      return minorComparison;
    }

    final patchComparison = patch.compareTo(other.patch);
    if (patchComparison != 0) {
      return patchComparison;
    }

    final leftPreRelease = preRelease;
    final rightPreRelease = other.preRelease;
    if (leftPreRelease == rightPreRelease) {
      return 0;
    }
    if (leftPreRelease == null) {
      return 1;
    }
    if (rightPreRelease == null) {
      return -1;
    }
    return leftPreRelease.compareTo(rightPreRelease);
  }

  @override
  String toString() {
    final suffix = preRelease == null ? '' : '-$preRelease';
    return '$major.$minor.$patch$suffix';
  }
}

String? normalizeAppVersionLabel(String raw) {
  return AppVersion.tryParse(raw)?.toString();
}
