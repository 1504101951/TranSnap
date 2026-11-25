import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/translation/live_block_cache.dart';

void main() {
  test('占用恰好等于预算时保留全部条目，超出后淘汰最久未用的条目', () {
    final cache = LiveBlockCache(budgetBytes: 20);
    cache.store('a', '1111');
    cache.store('b', '2222');
    expect(cache.bytes, 20);
    expect(cache.translation('a'), '1111');
    expect(cache.translation('b'), '2222');
    cache.store('c', '3333');
    expect(cache.bytes, 20);
    expect(cache.translation('a'), isNull);
    expect(cache.translation('b'), '2222');
    expect(cache.translation('c'), '3333');
  });

  test('命中会把条目记为最近使用，之后淘汰的是另一条', () {
    final cache = LiveBlockCache(budgetBytes: 20);
    cache.store('a', '1111');
    cache.store('b', '2222');
    expect(cache.translation('a'), '1111');
    cache.store('c', '3333');
    expect(cache.translation('a'), '1111');
    expect(cache.translation('b'), isNull);
  });

  test('失败次数与拒发标记按键记录，清空后全部归零', () {
    final cache = LiveBlockCache(budgetBytes: 1000);
    expect(cache.failures('a'), 0);
    expect(cache.rejected('a'), isFalse);
    cache.noteFailure('a');
    cache.noteFailure('a');
    cache.reject('b');
    expect(cache.failures('a'), 2);
    expect(cache.rejected('b'), isTrue);
    expect(cache.translation('a'), isNull);
    cache.clear();
    expect(cache.failures('a'), 0);
    expect(cache.rejected('b'), isFalse);
    expect(cache.bytes, 0);
  });
}
