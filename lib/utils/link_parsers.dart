import 'dart:convert';

String safeDecodeBase64(String str) {
  try {
    return utf8.decode(base64Decode(str));
  } catch (_) {
    return str;
  }
}
