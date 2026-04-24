import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:gorion_clean/features/update/model/app_update_state.dart';

abstract class AppUpdateRepository {
  Future<GithubRelease> fetchLatestRelease();
}

class GithubReleaseRepository implements AppUpdateRepository {
  GithubReleaseRepository({
    required String userAgent,
    Dio Function()? dioFactory,
  }) : _userAgent = userAgent,
       _dioFactory = dioFactory ?? _defaultDioFactory;

  static const latestReleaseUrl =
      'https://api.github.com/repos/Gor80hd/Gorion/releases/latest';

  final String _userAgent;
  final Dio Function() _dioFactory;

  @override
  Future<GithubRelease> fetchLatestRelease() async {
    final dio = _dioFactory();
    try {
      final response = await dio.get<Object?>(
        latestReleaseUrl,
        options: Options(
          responseType: ResponseType.json,
          validateStatus: (status) => status != null && status < 500,
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': _userAgent,
            'X-GitHub-Api-Version': '2022-11-28',
          },
        ),
      );

      final statusCode = response.statusCode;
      if (statusCode == null || statusCode < 200 || statusCode >= 300) {
        throw StateError(
          'GitHub latest release request failed with status $statusCode.',
        );
      }

      final data = _asJsonMap(response.data);
      if (data == null) {
        throw const FormatException(
          'GitHub release response is not a JSON map.',
        );
      }

      return GithubRelease.fromJson(data);
    } finally {
      dio.close(force: true);
    }
  }
}

Dio _defaultDioFactory() {
  return Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ),
  );
}

Map<String, dynamic>? _asJsonMap(Object? data) {
  if (data is Map<String, dynamic>) {
    return data;
  }
  if (data is Map) {
    return data.map((key, value) => MapEntry(key.toString(), value));
  }
  if (data is String && data.trim().isNotEmpty) {
    final decoded = jsonDecode(data);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  }
  return null;
}
