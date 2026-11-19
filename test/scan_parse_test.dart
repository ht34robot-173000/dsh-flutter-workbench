// 配对二维码解析的测试。
//
// 为什么重点测这个：解析错了表现为「扫码后连不上」，
// 界面上什么都看不出来 —— 是最难排查的一类。
//
// 全部样本来自桌面端 client.js:918 的真实格式：
//   <baseUrl>/rw/pair?code=123456
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/data/scan_parse.dart';

void main() {
  group('parsePairQr 正常路径', () {
    test('标准格式：https + 域名 + code', () {
      final r = parsePairQr('https://dsh.ht34robot.cyou/rw/pair?code=123456');
      expect(r, isNotNull);
      expect(r?.baseUrl, 'https://dsh.ht34robot.cyou');
      expect(r?.code, '123456');
    });

    test('局域网 IP + 端口', () {
      final r = parsePairQr('http://192.168.1.5:19387/rw/pair?code=654321');
      expect(r, isNotNull);
      expect(r?.baseUrl, 'http://192.168.1.5:19387');
      expect(r?.code, '654321');
    });

    test('本机回环', () {
      final r = parsePairQr('http://127.0.0.1:19387/rw/pair?code=111222');
      expect(r?.baseUrl, 'http://127.0.0.1:19387');
    });

    test('参数顺序变化 / 带额外参数也能取到 code', () {
      final r = parsePairQr('https://x.com/rw/pair?foo=bar&code=999888&z=1');
      expect(r, isNotNull);
      expect(r?.code, '999888');
      expect(r?.baseUrl, 'https://x.com');
    });

    test('末尾多余斜杠被去掉（避免拼出 //rw/api）', () {
      final r = parsePairQr('https://x.com/rw/pair?code=123456');
      expect(r?.baseUrl.endsWith('/'), isFalse);
    });

    test('纯 6 位码：baseUrl 为空，调用方沿用已存地址', () {
      final r = parsePairQr('123456');
      expect(r, isNotNull);
      expect(r?.baseUrl, '');
      expect(r?.code, '123456');
    });

    test('首尾空白被忽略', () {
      final r = parsePairQr('  https://x.com/rw/pair?code=123456  ');
      expect(r?.code, '123456');
    });

    test('nonce 串（非纯数字）也接受 —— 宿主 auth.accept 两种都收', () {
      final r = parsePairQr('https://x.com/rw/pair?code=abcdef123456');
      expect(r?.code, 'abcdef123456');
    });
  });

  group('parsePairQr 拒绝非法输入', () {
    test('空串 / null', () {
      expect(parsePairQr(''), isNull);
      expect(parsePairQr(null), isNull);
      expect(parsePairQr('   '), isNull);
    });

    test('普通网址（没有 code 参数）不是配对码', () {
      expect(parsePairQr('https://example.com'), isNull);
      expect(parsePairQr('https://example.com/rw/pair'), isNull);
    });

    test('非 http(s) scheme 拒绝', () {
      expect(parsePairQr('ftp://x.com/rw/pair?code=123456'), isNull);
      expect(parsePairQr('dsh://x/rw/pair?code=123456'), isNull);
    });

    test('code 太短拒绝', () {
      expect(parsePairQr('https://x.com/rw/pair?code=123'), isNull);
      expect(parsePairQr('12345'), isNull);
    });

    test('随机文字不是配对码', () {
      expect(parsePairQr('hello world'), isNull);
      expect(parsePairQr('哈哈哈哈哈'), isNull);
    });
  });

  group('PairScanResult 相等性', () {
    test('同地址同码相等（去重逻辑依赖它）', () {
      const a = PairScanResult(baseUrl: 'https://x', code: '123456');
      const b = PairScanResult(baseUrl: 'https://x', code: '123456');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('地址不同就不相等', () {
      const a = PairScanResult(baseUrl: 'https://x', code: '123456');
      const b = PairScanResult(baseUrl: 'https://y', code: '123456');
      expect(a, isNot(b));
    });
  });
}
