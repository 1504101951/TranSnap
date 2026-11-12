import 'dart:io';

import '../common/constants/network_limits.dart';

/// 翻译请求共用的 HTTP 客户端：同一服务的连续请求复用已建立的连接，省去重复的 TCP/TLS 握手。
/// 取消只中止对应的单次请求，不关闭本客户端；应用生命周期内保持存活。
final HttpClient translationHttpClient = HttpClient()
  ..connectionTimeout = NetworkLimits.connectionTimeout
  ..idleTimeout = NetworkLimits.idleTimeout;

/// origin 为翻译服务地址。用共享客户端发送一个不含原文的 HEAD 请求，提前完成 TCP/TLS 握手，
/// 读完响应后连接留在空闲池，供随后的翻译请求复用（#68）。返回请求结束的 Future，不抛出异常。
/// 适用条件：服务对 HEAD 返回任意状态码时保持连接；若某服务回应后关闭连接，预热对它无效，需重新评估。
Future<void> prewarmTranslationConnection(Uri origin) async {
  try {
    final request = await translationHttpClient.headUrl(origin);
    final response = await request.close();
    // 响应读完，连接才回到空闲池。
    await response.drain<void>();
  } catch (_) {
    // 有意忽略：预热只是提速手段，失败不提示；正式请求按自身的超时与错误处理报告网络问题。
  }
}
