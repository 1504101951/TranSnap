import 'dart:io';

import '../common/constants/network_limits.dart';

final HttpClient translationHttpClient = HttpClient()
  ..connectionTimeout = NetworkLimits.connectionTimeout
  ..idleTimeout = NetworkLimits.idleTimeout;

Future<void> prewarmTranslationConnection(Uri origin) async {
  try {
    final request = await translationHttpClient.headUrl(origin);
    final response = await request.close();
    await response.drain<void>();
  } catch (_) {
  }
}
