import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/translation/translation_http.dart';

/// 无参数；验证连接预热让后续翻译请求复用同一条连接，以及预热失败不抛出（#68）。
void main() {
  test('预热发送不含原文的 HEAD，随后的翻译请求复用同一条连接', () async {
    // 作用：预热完成握手后连接留在共享客户端的空闲池，正式请求不再新建连接。
    // 边界：本机服务记录每个请求的方法、正文长度与客户端端口；端口相同即同一条 TCP 连接。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <({String method, int length, int port})>[];
    final serving = server.listen((request) async {
      final body = await request.fold<int>(
        0,
        (sum, chunk) => sum + chunk.length,
      );
      seen.add((
        method: request.method,
        length: body,
        port: request.connectionInfo!.remotePort,
      ));
      await request.response.close();
    });
    addTearDown(serving.cancel);
    final origin = Uri.parse('http://127.0.0.1:${server.port}/');

    await prewarmTranslationConnection(origin);
    final request = await translationHttpClient.postUrl(origin);
    request.write('q=Hello');
    await (await request.close()).drain<void>();

    expect(seen, hasLength(2));
    expect(seen[0].method, 'HEAD');
    expect(seen[0].length, 0);
    expect(seen[1].method, 'POST');
    expect(seen[1].port, seen[0].port);
  });

  test('预热连接失败时正常结束，不抛出异常', () async {
    // 作用：预热只是提速手段，服务不可达不能打断截图或实时翻译。
    // 边界：先占用再关闭一个本机端口，保证连接被拒绝。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);
    await expectLater(
      prewarmTranslationConnection(Uri.parse('http://127.0.0.1:$port/')),
      completes,
    );
  });
}
