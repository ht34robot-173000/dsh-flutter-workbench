/// DSH 工作台 —— 文件管理数据层。
///
/// 对接宿主 `/rw/api/fs.*`，实现照 Kotlin 版 `lib/fs-ops.js` 的契约。
///
/// ⚠️ 四条必须知道的（都来自 Kotlin 版实测）：
///
///  1. **`fs.list` 传空路径 = 列盘符**。宿主的返回值里 `path` 是 `''`、
///     `parent` 是 `null`、`entries` 是各盘符（`name: "C:"`, `path: "C:\\"`,
///     `kind: "dir"`）。别自己拼盘符列表 —— 宿主已经过滤掉不存在的盘。
///
///  2. **下载必须走票据**。`fs.download` 是 GET，系统浏览器/下载器发起时
///     **不带 `rw_device` cookie**（不同 cookie jar），所以必须先
///     `fs.ticket` 换一张 60 秒一次性票，把票拼进 URL。
///
///  3. **上传走 base64**。`fs.upload` 要 `{dir, name, base64}`，
///     宿主用 `basename(name)` 防 `../` 逃逸。单文件上限 20MB
///     （服务端 `maxUpload=20MB`，base64 膨胀 4/3 后约 27MB，
///     仍在 `readJson` 的 32MB 上限内）。
///
///  4. **中文路径**。所有路径都要按 UTF-8 走完 JSON 链路，
///     Kotlin 版踩过「PowerShell 发请求把中文变成 ??」的坑。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'ds_api.dart';
import 'prefs.dart';

/// 一个目录项。
class FsEntry {
  final String name;
  final String path;

  /// 'dir' | 'file' | 'link'
  final String kind;
  final int size;
  final int mtime;
  final String ext;
  final bool hidden;

  const FsEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.size = 0,
    this.mtime = 0,
    this.ext = '',
    this.hidden = false,
  });

  bool get isDir => kind == 'dir';

  factory FsEntry.fromJson(Map<String, dynamic> j) => FsEntry(
        name: (j['name'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        kind: (j['kind'] ?? 'file').toString(),
        size: (j['size'] is num) ? (j['size'] as num).toInt() : 0,
        mtime: (j['mtime'] is num) ? (j['mtime'] as num).toInt() : 0,
        ext: (j['ext'] ?? '').toString(),
        hidden: j['hidden'] == true,
      );
}

/// 一次 list 的结果。
class FsListing {
  /// 当前目录。空串表示「盘符列表」这一层。
  final String path;

  /// 上一级。null 表示已在顶层（盘符列表）。
  final String? parent;

  /// 路径分隔符（Windows `\`，Linux `/`）。
  final String sep;

  /// 用户主目录，UI 上给个「回到主目录」的快捷入口。
  final String home;

  final List<FsEntry> entries;
  final bool truncated;
  final List<String> drives;

  const FsListing({
    required this.path,
    required this.parent,
    required this.sep,
    required this.home,
    required this.entries,
    this.truncated = false,
    this.drives = const [],
  });

  /// 是否处于「盘符列表」这一层。
  bool get isDriveRoot => path.isEmpty;

  factory FsListing.fromJson(Map<String, dynamic>? v) {
    final entries = <FsEntry>[];
    final raw = v?['entries'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) entries.add(FsEntry.fromJson(e.cast<String, dynamic>()));
      }
    }
    final drives = <String>[];
    final dr = v?['drives'];
    if (dr is List) {
      for (final d in dr) {
        if (d is String) drives.add(d);
      }
    }
    final p = v?['parent'];
    return FsListing(
      path: (v?['path'] ?? '').toString(),
      parent: (p is String && p.isNotEmpty) ? p : null,
      sep: (v?['sep'] ?? '/').toString(),
      home: (v?['home'] ?? '').toString(),
      entries: entries,
      truncated: v?['truncated'] == true,
      drives: drives,
    );
  }
}

class FsApi {
  final Prefs prefs;
  late Dio _dio;

  FsApi(this.prefs) {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 120),
      validateStatus: (_) => true,
      responseType: ResponseType.plain,
    ));
    reload();
  }

  void reload() {
    final base = prefs.baseUrl;
    _dio.options.baseUrl = base.isEmpty ? 'http://127.0.0.1:19387' : base;
    _dio.options.headers = {
      if ((prefs.cookie ?? '').isNotEmpty) 'cookie': prefs.cookie,
      'content-type': 'application/json; charset=utf-8',
    };
  }

  Future<ApiResult> _post(String method, Map<String, dynamic> body) async {
    try {
      final res = await _dio.post(
        '/rw/api/$method',
        // ⚠️ 必须显式用 UTF-8 字节序列化：
        // 直接传 String 时 dio 会按 headers 里的 charset 编码，
        // 中文路径在某些组合下会被转义错（Kotlin 版踩过同类问题）。
        data: utf8.encode(jsonEncode(body)),
      );
      return _parse(res);
    } on DioException catch (e) {
      return ApiResult.network(_describe(e));
    } catch (e) {
      return ApiResult.network('请求失败：$e');
    }
  }

  ApiResult _parse(Response<dynamic> res) {
    final code = res.statusCode ?? 0;
    final text = (res.data as String?) ?? '';
    Map<String, dynamic>? json;
    if (text.isNotEmpty) {
      try {
        final d = jsonDecode(text);
        if (d is Map<String, dynamic>) json = d;
      } catch (_) {}
    }
    final ok = json?['ok'] == true;
    final err = json?['error'];
    return ApiResult(
      ok: ok,
      value: json,
      statusCode: code,
      errorCode: err is Map ? (err['code']?.toString()) : (ok ? null : 'http-$code'),
      errorMessage: err is Map ? (err['message']?.toString()) : null,
    );
  }

  String _describe(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '请求超时';
      case DioExceptionType.connectionError:
        return '连不上 ${_dio.options.baseUrl}';
      case DioExceptionType.badCertificate:
        return '证书校验失败';
      default:
        return e.message ?? '网络错误';
    }
  }

  /// 列目录。**`path` 传空串就返回盘符列表**（宿主契约）。
  Future<(ApiResult, FsListing?)> list(
    String path, {
    bool showHidden = false,
  }) async {
    final r = await _post('fs.list', {
      'path': path,
      'showHidden': showHidden,
    });
    if (!r.ok) return (r, null);
    final v = r.value?['value'];
    return (
      r,
      FsListing.fromJson(v is Map ? v.cast<String, dynamic>() : null),
    );
  }

  /// 读文本文件。宿主只收文本（二进制会被拒，报 `binary-file`）。
  Future<(ApiResult, String?)> readText(String path) async {
    final r = await _post('fs.read', {'path': path});
    if (!r.ok) return (r, null);
    final v = r.value?['value'];
    final text = (v is Map) ? (v['text'] ?? '').toString() : '';
    return (r, text);
  }

  Future<ApiResult> writeText(String path, String text) =>
      _post('fs.write', {'path': path, 'text': text});

  Future<ApiResult> mkdir(String path) => _post('fs.mkdir', {'path': path});

  Future<ApiResult> touch(String path) => _post('fs.touch', {'path': path});

  Future<ApiResult> remove(String path, {bool recursive = false}) =>
      _post('fs.remove', {'path': path, 'recursive': recursive});

  Future<ApiResult> move(String from, String to) =>
      _post('fs.move', {'from': from, 'to': to});

  Future<ApiResult> copy(String from, String to) =>
      _post('fs.copy', {'from': from, 'to': to});

  /// 上传一个文件到目录。
  ///
  /// 走 `fs.upload` + base64 —— 和 Kotlin 版一致。
  /// 上限 20MB：超过就让用户在电脑上操作（手机传大文件本来就慢，
  /// 而且服务端 `readJson` 的 32MB 整包上限会被 base64 膨胀顶破）。
  static const int maxUploadBytes = 20 * 1024 * 1024;

  Future<ApiResult> upload({
    required String dir,
    required String name,
    required List<int> bytes,
  }) async {
    if (bytes.length > maxUploadBytes) {
      return const ApiResult(
        ok: false,
        errorCode: 'file-too-large',
        errorMessage: '超过 20MB，请在电脑上操作',
      );
    }
    return _post('fs.upload', {
      'dir': dir,
      'name': name,
      'base64': base64Encode(bytes),
    });
  }

  /// 换一张一次性下载票据。
  ///
  /// 返回的 `url` 是相对路径（`/rw/api/fs.download?path=...&ticket=...`），
  /// 需要拼上 baseUrl 才能给浏览器。
  Future<(ApiResult, String?)> ticket(String path) async {
    final r = await _post('fs.ticket', {'path': path});
    if (!r.ok) return (r, null);
    final v = r.value?['value'];
    final rel = (v is Map) ? (v['url'] ?? '').toString() : '';
    if (rel.isEmpty) return (r, null);
    final base = prefs.baseUrl;
    return (r, rel.startsWith('http') ? rel : '$base$rel');
  }

  /// 直接下载字节（自己用，不经过系统浏览器）。
  ///
  /// 走带 cookie 的请求，不需要票据 —— 票据是给「不带 cookie 的系统下载器」用的。
  Future<(ApiResult, List<int>?)> downloadBytes(String path) async {
    try {
      final res = await _dio.get<List<int>>(
        '/rw/api/fs.download',
        queryParameters: {'path': path},
        options: Options(responseType: ResponseType.bytes),
      );
      if (res.statusCode != 200) {
        final code = res.statusCode ?? 0;
        return (
          ApiResult(
            ok: false,
            statusCode: code,
            errorCode: 'http-$code',
          ),
          null,
        );
      }
      return (const ApiResult(ok: true), res.data);
    } on DioException catch (e) {
      return (ApiResult.network(_describe(e)), null);
    }
  }
}

/// 人读的字节数。
String formatBytes(int n) {
  if (n <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = n.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0
      ? '${v.toStringAsFixed(0)} B'
      : '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

/// 人读的时间（`MM-dd HH:mm`，与列表页同一口径）。
String formatFsTime(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
