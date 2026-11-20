// 附件（图片 / 文件）通路测试。
//
// 关键契约：
//   - 图片进 `session.prompt` 的 images 数组（base64 + mediaType）；
//   - 文件**不能**进消息，只能先上传到宿主再给路径 —— 所以正文里要长出那段路径；
//   - 不合法的（SVG、超大）要在客户端就挡掉，并说出为什么。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/data/attachments.dart';

Uint8List _bytes(int n) => Uint8List.fromList(List<int>.filled(n, 7));

PendingAttachment _img(String name, {int size = 10}) =>
    PendingAttachment(name: name, bytes: _bytes(size), isImage: true);

PendingAttachment _file(String name, {int size = 10}) =>
    PendingAttachment(name: name, bytes: _bytes(size), isImage: false);

void main() {
  group('PendingAttachment', () {
    test('mediaType 按扩展名推断', () {
      expect(_img('a.png').mediaType, 'image/png');
      expect(_img('a.JPG').mediaType, 'image/jpeg');
      expect(_img('a.jpeg').mediaType, 'image/jpeg');
      expect(_img('a.webp').mediaType, 'image/webp');
      expect(_img('a.gif').mediaType, 'image/gif');
      expect(_file('a.pdf').mediaType, 'application/pdf');
      expect(_file('a.bin').mediaType, 'application/octet-stream');
    });

    test('base64 与图片 payload 结构正确', () {
      final a = _img('pic.png');
      expect(a.base64Data, base64Encode(a.bytes));
      final p = a.toImagePayload();
      expect(p['mediaType'], 'image/png');
      expect(p['name'], 'pic.png');
      expect(base64Decode(p['data'] as String).length, a.sizeBytes);
    });

    test('大小文案', () {
      expect(_file('a', size: 500).sizeText, '500 B');
      expect(_file('a', size: 2048).sizeText, '2 KB');
      expect(_file('a', size: 3 * 1024 * 1024).sizeText, '3.0 MB');
    });
  });

  group('buildImagesPayload', () {
    test('只收图片，且丢掉非白名单格式与超限的', () {
      final r = buildImagesPayload([
        _img('ok.png'),
        _img('vector.svg'),
        _img('huge.png', size: kMaxImageBytes + 1),
        _file('doc.pdf'),
      ]);
      expect(r.images, hasLength(1));
      expect(r.images.first['name'], 'ok.png');
      expect(r.dropped, hasLength(2));
      expect(r.dropped.join(), contains('vector.svg'));
      expect(r.dropped.join(), contains('huge.png'));
    });

    test('空列表给空数组', () {
      final r = buildImagesPayload([]);
      expect(r.images, isEmpty);
      expect(r.dropped, isEmpty);
    });
  });

  group('正文拼接', () {
    test('没有文件时只有原话', () {
      expect(composeText('你好', []), '你好');
    });

    test('文件路径进正文，标明「已上传到宿主」', () {
      final t = composeText('看下这个', [r'C:\Users\x\.dsh\mobile-uploads\1-a.pdf']);
      expect(t, startsWith('看下这个'));
      expect(t, contains('已上传到宿主'));
      expect(t, contains(r'C:\Users\x\.dsh\mobile-uploads\1-a.pdf'));
    });

    test('只有文件、没有输入也算有内容（否则会被判空发不出去）', () {
      final t = composeText('   ', [r'F:\x\a.txt']);
      expect(t.trim(), isNotEmpty);
      expect(t, contains(r'F:\x\a.txt'));
    });

    test('空路径被忽略', () {
      expect(composeText('hi', ['', '  ']), 'hi');
    });
  });

  group('uploadDirFor / stampedName', () {
    test('Windows 与 posix 分隔符都对', () {
      expect(uploadDirFor(r'C:\Users\a'), r'C:\Users\a\.dsh\mobile-uploads');
      expect(uploadDirFor('/home/a'), '/home/a/.dsh/mobile-uploads');
      expect(uploadDirFor(r'C:\Users\a\'), r'C:\Users\a\.dsh\mobile-uploads');
      expect(uploadDirFor(''), '');
    });

    test('文件名带时间戳，且剔除危险字符', () {
      final n = stampedName(r'a/b:c*.txt', now: DateTime(2026, 11, 20, 17, 5, 9));
      expect(n, '20261120-170509-a_b_c_.txt');
      expect(n.contains('/'), isFalse);
    });
  });
}
