// 文件管理数据层的纯逻辑测试。
//
// 覆盖两处容易错的解析：
//   1. `fs.list` 空路径 = 盘符列表（宿主契约，不是我们拼的）
//   2. 字节数格式化
//
// 真实网络行为（上传/下载/票据）在模拟器上验证，
// 这里只锁纯函数，防止以后改坏。
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/data/fs_api.dart';

void main() {
  group('FsListing.fromJson', () {
    test('空路径 = 盘符列表，parent 为 null', () {
      // 宿主对 fs.list('') 的真实返回形状（照 lib/fs-ops.js 的 ok() 构造）
      final l = FsListing.fromJson({
        'path': '',
        'home': 'C:\\Users\\x',
        'parent': null,
        'sep': '\\',
        'platform': 'win32',
        'entries': [
          {'name': 'C:', 'path': 'C:\\', 'kind': 'dir', 'size': 0, 'mtime': 0, 'ext': '', 'hidden': false},
          {'name': 'F:', 'path': 'F:\\', 'kind': 'dir', 'size': 0, 'mtime': 0, 'ext': '', 'hidden': false},
        ],
        'truncated': false,
        'freeBytes': null,
        'drives': ['C:\\', 'F:\\'],
      });
      expect(l.isDriveRoot, isTrue);
      expect(l.parent, isNull);
      expect(l.entries.length, 2);
      expect(l.entries.first.isDir, isTrue);
      expect(l.drives, ['C:\\', 'F:\\']);
      expect(l.sep, '\\');
    });

    test('普通目录：parent 有值、文件和目录混排', () {
      final l = FsListing.fromJson({
        'path': 'F:\\插件',
        'parent': 'F:\\',
        'sep': '\\',
        'home': 'C:\\Users\\x',
        'entries': [
          {'name': 'AGENTS.md', 'path': 'F:\\插件\\AGENTS.md', 'kind': 'file',
           'size': 12897, 'mtime': 1795000000000, 'ext': '.md', 'hidden': false},
          {'name': 'dsh-mobile', 'path': 'F:\\插件\\dsh-mobile', 'kind': 'dir',
           'size': 0, 'mtime': 1795000000000, 'ext': '', 'hidden': false},
        ],
        'truncated': false,
      });
      expect(l.isDriveRoot, isFalse);
      expect(l.parent, 'F:\\');
      expect(l.entries.length, 2);
      final file = l.entries.firstWhere((e) => !e.isDir);
      expect(file.name, 'AGENTS.md');
      expect(file.size, 12897);
      expect(file.ext, '.md');
    });

    test('空 value 不崩', () {
      final l = FsListing.fromJson(null);
      expect(l.entries, isEmpty);
      expect(l.path, '');
      expect(l.isDriveRoot, isTrue);
    });
  });

  group('formatBytes', () {
    test('各量级', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(7 * 1024 + 300), '7.3 KB');
      expect(formatBytes(219 * 1024 * 1024), '219 MB');
      expect(formatBytes(5 * 1024 * 1024 * 1024), '5.0 GB');
    });
  });

  group('formatFsTime', () {
    test('与列表页同口径 MM-dd HH:mm', () {
      // 0 表示没有时间，返回空串（不要显示 1970-01-01）
      expect(formatFsTime(0), '');
      final s = formatFsTime(1795000000000);
      expect(RegExp(r'^\d{2}-\d{2} \d{2}:\d{2}$').hasMatch(s), isTrue);
    });
  });
}
