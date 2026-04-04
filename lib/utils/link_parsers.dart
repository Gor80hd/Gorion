import 'dart:convert';

typedef ProfileLink = ({String url, String name});

String safeDecodeBase64(String str) {
  try {
    return utf8.decode(base64Decode(str));
  } catch (_) {
    return str;
  }
}
