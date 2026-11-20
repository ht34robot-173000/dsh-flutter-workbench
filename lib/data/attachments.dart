/// DSH 工作台 —— 发送附件（图片 / 文件）。
///
/// 两条通路**完全不一样**，别混：
///
/// | 类型 | 怎么进会话 | 宿主契约 |
/// |---|---|---|
/// | 图片 | 直接塞进消息的 content 块 | `session.prompt { images: [{data(base64), mediaType, name}] }` |
/// | 文件 | 先 `fs.upload` 落到宿主磁盘，再把**路径写进正文** | `fs.upload {dir, name, base64}` → `{path}` |
///
/// 为什么文件不能直接塞：宿主的 `session.prompt` 只认 `fileReceipts`（upload receipt id），
/// 而 receipt 只能由桌面端的上传流程拿到 —— 本插件没有这条路。
/// 所以手机上「发文件」= 传到宿主某个目录 + 在消息里给出路径，
/// agent 自己会去读（它本来就有读文件的工具）。这一点必须在界面上说清楚，
/// 否则用户以为自己发了「附件」，其实是给了一条路径。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 一条待发送的附件。
class PendingAttachment {
  /// 手机本地的名字（展示用）。
  final String name;

  /// 原始字节。图片要转 base64 塞进消息；文件要 base64 上传。
  final Uint8List bytes;

  /// 是否按图片处理（走 images 通道）。
  final bool isImage;

  const PendingAttachment({
    required this.name,
    required this.bytes,
    required this.isImage,
  });

  int get sizeBytes => bytes.length;

  String get sizeText {
    final kb = sizeBytes / 1024;
    if (kb < 1) return '$sizeBytes B';
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  /// MIME。宿主只收白名单里的图片类型（png/jpeg/webp/gif）。
  String get mediaType {
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.txt') || n.endsWith('.md') || n.endsWith('.log')) {
      return 'text/plain';
    }
    if (n.endsWith('.json')) return 'application/json';
    if (n.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }

  String get base64Data => base64Encode(bytes);

  /// 给 `session.prompt` 的 images 项。
  Map<String, dynamic> toImagePayload() => {
        'data': base64Data,
        'mediaType': mediaType,
        'name': name,
      };
}

/// 宿主只收这几种图片（见 lib/session.js 的 ALLOWED_IMAGE_TYPES）。
const Set<String> kAllowedImageTypes = {
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
};

/// 单条图片上限：再大 base64 之后走代理会很慢，实践里 8MB 够用。
const int kMaxImageBytes = 8 * 1024 * 1024;

/// 单条文件上限（上传是整块 base64 走一次性 JSON，过大会超时）。
const int kMaxFileBytes = 32 * 1024 * 1024;

/// 组装 `images` 数组：过滤掉不合法/超限的，并把被丢掉的**原因**带回去，
/// 让界面能如实提示，而不是「发了三张只到两张」。
({List<Map<String, dynamic>> images, List<String> dropped}) buildImagesPayload(
  Iterable<PendingAttachment> list,
) {
  final images = <Map<String, dynamic>>[];
  final dropped = <String>[];
  for (final a in list) {
    if (!a.isImage) continue;
    if (!kAllowedImageTypes.contains(a.mediaType)) {
      dropped.add('${a.name}（不支持的格式）');
      continue;
    }
    if (a.sizeBytes > kMaxImageBytes) {
      dropped.add('${a.name}（超过 8MB）');
      continue;
    }
    images.add(a.toImagePayload());
  }
  return (images: images, dropped: dropped);
}

/// 把已上传文件的路径拼成一段正文，附在用户输入后面。
///
/// 用「已上传到宿主」而不是「附件」，是因为它真的只是一段路径。
String filesFooter(Iterable<String> hostPaths) {
  final list = hostPaths.where((p) => p.trim().isNotEmpty).toList();
  if (list.isEmpty) return '';
  final buf = StringBuffer('\n\n已上传到宿主（可直接读取）：');
  for (final p in list) {
    buf.write('\n- $p');
  }
  return buf.toString();
}

/// 合并用户输入 + 文件路径段。全是空白时返回空串（调用方据此判空）。
String composeText(String userText, Iterable<String> hostPaths) {
  final t = userText.trimRight();
  final footer = filesFooter(hostPaths);
  final out = (t + footer).trim();
  return out;
}

/// 上传目标目录：宿主主目录下的 `.dsh\mobile-uploads`。
///
/// 用点前缀、放在 home 里，是为了不污染工作区；文件名前面再加时间戳，
/// 免得两次同名文件互相覆盖。
String uploadDirFor(String hostHome) {
  if (hostHome.trim().isEmpty) return '';
  final sep = hostHome.contains('\\') ? '\\' : '/';
  final h = hostHome.endsWith(sep) ? hostHome.substring(0, hostHome.length - 1) : hostHome;
  return '$h$sep.dsh$sep' 'mobile-uploads';
}

/// 带时间戳的上传文件名。
String stampedName(String original, {DateTime? now}) {
  final t = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  // 只留安全字符，避免宿主那边 basename 处理出意外
  final safe = original.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return '$stamp-$safe';
}
