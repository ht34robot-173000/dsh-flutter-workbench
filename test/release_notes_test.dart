// 更新说明的裁剪测试。
//
// 为什么值得测：Release body 里「下载链接」和「源码链接」在 App 里是噪音
// （界面上已经有下载按钮），但裁剪规则一旦写错就会把正文也切掉。
//
// 注意：这里复制的裁剪规则必须和 lib/ui/update_page.dart 的
// `_trimNotes` 保持一致。两边改动要同步。
import 'package:flutter_test/flutter_test.dart';

String trimNotes(String raw) {
  final lines = raw.split('\n');
  final out = <String>[];
  var skip = false;
  var skipLevel = 0;

  bool isHeading(String t) => RegExp(r'^#{1,6}\s').hasMatch(t);
  int headingLevel(String t) {
    final m = RegExp(r'^(#{1,6})\s').firstMatch(t);
    return m == null ? 0 : m.group(1)!.length;
  }

  bool isNoiseHeading(String t) =>
      RegExp(r'^#{1,6}\s*(下载|Download|源码|Source)(\s|$)', caseSensitive: false)
          .hasMatch(t);

  for (final line in lines) {
    final t = line.trim();

    if (isHeading(t)) {
      if (skip && headingLevel(t) <= skipLevel) skip = false;
      if (!skip && isNoiseHeading(t)) {
        skip = true;
        skipLevel = headingLevel(t);
        continue;
      }
      if (skip) continue;
      out.add(line);
      continue;
    }

    if (skip) continue;

    if (t.isNotEmpty &&
        (t.contains('github.com/') || t.contains('gh-proxy.com/'))) {
      continue;
    }
    out.add(line);
  }

  var s = out.join('\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

void main() {
  group('trimNotes', () {
    test('去掉下载区块，保留正文和后续标题', () {
      const raw = '''## v0.7.2

### 本版修复

- 修复了 A 问题

### 下载

- [直接下载](https://github.com/x/y/raw/main/a.apk)
- [国内镜像](https://gh-proxy.com/https://github.com/x/y/a.apk)

### 功能

- 会话列表
''';
      final out = trimNotes(raw);
      expect(out.contains('修复了 A 问题'), isTrue);
      expect(out.contains('### 下载'), isFalse);
      expect(out.contains('国内镜像'), isFalse);
      expect(out.contains('.apk'), isFalse);
      // 关键：下载区块后面的「功能」标题不能被一起吃掉
      expect(out.contains('### 功能'), isTrue);
      expect(out.contains('会话列表'), isTrue);
    });

    test('去掉末尾的源码区块', () {
      const raw = '''## v1.0

正文内容

### 源码

https://github.com/x/y
''';
      final out = trimNotes(raw);
      expect(out.contains('正文内容'), isTrue);
      expect(out.contains('### 源码'), isFalse);
    });

    test('裸 GitHub 链接行被移除', () {
      const raw = '''正文

https://github.com/a/b/raw/main/x.apk

继续正文''';
      final out = trimNotes(raw);
      expect(out.contains('github.com'), isFalse);
      expect(out.contains('正文'), isTrue);
      expect(out.contains('继续正文'), isTrue);
    });

    test('非 GitHub 的链接保留', () {
      const raw = '正文 [文档](https://docs.example.com)';
      expect(trimNotes(raw).contains('docs.example.com'), isTrue);
    });

    test('连续空行压缩成一行', () {
      expect(trimNotes('A\n\n\n\n\nB'), 'A\n\nB');
    });

    test('空输入不崩', () {
      expect(trimNotes(''), '');
      expect(trimNotes('   '), '');
    });

    test('只有标题时不报错', () {
      expect(trimNotes('## v1.0'), '## v1.0');
    });

    test('没有下载/源码区块时原样保留', () {
      const raw = '## v1.0\n\n- 改动一\n- 改动二';
      final out = trimNotes(raw);
      expect(out, raw);
    });
  });
}

