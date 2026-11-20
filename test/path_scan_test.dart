// 路径扫描的纯逻辑测试。
//
// 这块容易「看起来对、实际点不开」，所以样本全取自真实对话里出现过的写法：
// 反引号包裹、JSON 转义的反斜杠、中文路径、尾跟标点、盘符根。
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/data/path_scan.dart';

void main() {
  group('scanPaths', () {
    test('反引号里的 Windows 路径', () {
      final r = scanPaths('改这里 `F:\\插件\\dsh-mobile\\01-文档\\HANDOFF.md` 就行');
      expect(r, hasLength(1));
      expect(r.first.path, r'F:\插件\dsh-mobile\01-文档\HANDOFF.md');
      expect(r.first.looksLikeFile, isTrue);
    });

    test('JSON 转义的两个反斜杠要折叠成一个', () {
      // 代码块里宿主会把路径写成 F:\\插件\\x，直接拿去 fs.list 是不存在的
      final r = scanPaths(r'见 F:\\dsh-flutter\\lib\\main.dart 这一行');
      expect(r.first.path, r'F:\dsh-flutter\lib\main.dart');
    });

    test('正斜杠统一成反斜杠', () {
      final r = scanPaths('路径 F:/dsh-flutter/lib/ui/chat_page.dart');
      expect(r.first.path, r'F:\dsh-flutter\lib\ui\chat_page.dart');
    });

    test('尾部标点必须剥掉（否则是本不存在的路径）', () {
      expect(scanPaths('看 F:\\a\\b.md。').first.path, r'F:\a\b.md');
      expect(scanPaths('看 F:\\a\\b.md，然后').first.path, r'F:\a\b.md');
      expect(scanPaths('看（F:\\a\\b.md）').first.path, r'F:\a\b.md');
      expect(scanPaths('看 F:\\a\\b.md) ').first.path, r'F:\a\b.md');
    });

    test('目录（无扩展名）也能识别，looksLikeFile=false', () {
      final r = scanPaths('去 F:\\插件\\dsh-mobile 下面找');
      expect(r.first.path, r'F:\插件\dsh-mobile');
      expect(r.first.looksLikeFile, isFalse);
    });

    test('盘符根保留反斜杠', () {
      expect(scanPaths('整盘 F:\\ 都在').first.path, r'F:\');
    });

    test('同一路径只留一条（正文和代码块里重复出现）', () {
      const t = 'F:\\a\\b.md 和 F:/a/b.md 其实是同一个';
      expect(scanPaths(t), hasLength(1));
    });

    test('默认最多 4 条，避免一条消息挂一屏按钮', () {
      final t = List.generate(8, (i) => 'F:\\d$i\\x.txt').join(' ');
      expect(scanPaths(t), hasLength(4));
    });

    test('相对路径不识别（脱离上下文会点错地方）', () {
      expect(scanPaths('改 lib/ui/chat_page.dart 这个文件'), isEmpty);
      expect(scanPaths('./lib/main.dart'), isEmpty);
    });

    test('普通文字里的冒号数字不会被误判', () {
      expect(scanPaths('比例 1:2 ，时间 12:30'), isEmpty);
      expect(scanPaths('http://example.com/a/b'), isEmpty);
    });

    test('file:// 前缀能被剥掉', () {
      final r = scanPaths('打开 file:///F:/插件/AGENTS.md');
      expect(r.first.path, r'F:\插件\AGENTS.md');
    });

    test('空文本 / 纯空白不抛', () {
      expect(scanPaths(''), isEmpty);
      expect(scanPaths('   \n\t '), isEmpty);
    });
  });

  group('parentDirPath', () {
    test('普通文件取上级目录', () {
      expect(parentDirPath(r'F:\a\b\c.md'), r'F:\a\b');
    });

    test('盘符下一层退回盘符根', () {
      expect(parentDirPath(r'F:\c.md'), r'F:\');
    });

    test('盘符根本身返回自己', () {
      expect(parentDirPath(r'F:\'), r'F:\');
    });

    test('带尾分隔符的目录也能取父级', () {
      expect(parentDirPath(r'F:\a\b\'), r'F:\a');
    });
  });
}
