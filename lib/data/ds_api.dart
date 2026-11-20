/// DSH 远程工作台 —— 接口客户端。
///
/// 对应宿主插件 `dsh-remote-workbench` 的 `/rw` 路由。
///
/// 两条必须知道的路由规则（照抄 Kotlin 版的踩坑记录）：
///
///  1. `/rw/api/*` 下的接口**都要带 `rw_device` cookie**，否则 401「设备未配对」。
///  2. `/rw/pair/accept` **不在** `/rw/api` 下面。早期版本用统一的
///     `api.post()` 去发配对请求，那个函数会自己拼 `/rw/api/...`，
///     结果打到不存在的路径。所以配对走独立的 `acceptPair()`。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'prefs.dart';

/// 接口返回的统一包装。`ok=false` 时不抛异常，把 error 原样带回来 ——
/// 调用方永远只处理两种结果，不需要满地 try/catch。
class ApiResult {
  final bool ok;
  final Map<String, dynamic>? value;
  final String? errorCode;
  final String? errorMessage;
  final int statusCode;

  const ApiResult({
    required this.ok,
    this.value,
    this.errorCode,
    this.errorMessage,
    this.statusCode = 0,
  });

  /// 网络层失败（连不上、超时、DNS）。和「业务失败」分开是必要的：
  /// 前者要让用户看「连不上服务器」，后者要看具体错误码。
  static ApiResult network(String message) => ApiResult(
        ok: false,
        errorCode: 'network',
        errorMessage: message,
      );

  String get friendlyError {
    switch (errorCode) {
      case 'network':
        return '连不上服务器 —— 检查地址对不对、手机和电脑在不在同一个网络';
      case 'unpaired':
        return '设备未配对 —— 去设置里扫码或输入配对码';
      case 'loopback-only':
        return '这个操作只能在电脑上做';
      case 'invalid-token':
        return '配对码不对或已过期（只有 10 分钟）';
      default:
        return errorMessage ?? (errorCode ?? '未知错误');
    }
  }
}

class DshApi {
  final Prefs prefs;
  late Dio _dio;

  /// 请求打点。默认关闭，排查「切个主题怎么又发请求了」这类问题时打开：
  ///   `flutter build apk --dart-define=DSH_API_TRACE=true`
  /// 然后 `adb logcat | Select-String '\[api\]'` 就能看到每一次 `/rw/api/*`。
  static const bool trace = bool.fromEnvironment('DSH_API_TRACE');

  DshApi(this.prefs) {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 45),
      sendTimeout: const Duration(seconds: 45),
      // 不让 dio 因为 4xx/5xx 抛异常，我们要自己读 body 里的 error
      validateStatus: (_) => true,
      responseType: ResponseType.plain,
    ));
    _syncBase();
  }

  /// 地址/模式变化后必须调一次，否则所有请求还打向旧地址。
  void reload() {
    _syncBase();
  }

  void _syncBase() {
    final base = prefs.baseUrl;
    _dio.options.baseUrl = base.isEmpty ? 'http://127.0.0.1:19387' : base;
    _dio.options.headers = {
      if ((prefs.cookie ?? '').isNotEmpty) 'cookie': prefs.cookie,
      'content-type': 'application/json; charset=utf-8',
    };
  }

  /// 真正的 `/rw/api/<method>` 调用。
  Future<ApiResult> api(String method, [Map<String, dynamic> body = const {}]) async {
    if (trace) debugPrint('[api] $method');
    final url = '/rw/api/$method';
    try {
      final res = await _dio.post(url, data: jsonEncode(body));
      return _parse(res);
    } on DioException catch (e) {
      return ApiResult.network(_describeDio(e));
    } catch (e) {
      return ApiResult.network('请求失败：$e');
    }
  }

  /// 是否有配对凭据（不代表还有效，只代表存过）。
  bool get hasCookie => (prefs.cookie ?? '').isNotEmpty;

  /// 当前连接是否可用 —— 走 `state` 接口，它是最轻的一个。
  Future<ApiResult> state() async {
    try {
      final res = await _dio.get('/rw/api/state');
      return _parse(res);
    } on DioException catch (e) {
      return ApiResult.network(_describeDio(e));
    } catch (e) {
      return ApiResult.network('请求失败：$e');
    }
  }

  /// 用配对码换设备 cookie。
  ///
  /// **单独一个方法**的原因见文件头第 2 条：这个路由不在 `/rw/api` 下面。
  /// 成功时会把 `set-cookie` 里的 `rw_device=...` 存进对应模式的格子。
  ///
  /// `token` 可以是 6 位配对码，也可以是 nonce 串 ——
  /// 宿主 `auth.accept()` 两者都收（`same(p.code, token) || same(p.nonce, token)`）。
  /// 早先这里硬校验「必须 6 位数字」，导致扫码拿到的 nonce 一律被判 bad-code。
  Future<ApiResult> acceptPair(String token) async {
    final clean = token.trim();
    if (clean.length < 6) {
      return const ApiResult(
        ok: false,
        errorCode: 'bad-code',
        errorMessage: '配对码无效',
      );
    }
    try {
      // 关键：不要带 cookie。带着上一次的旧 cookie 去配对，
      // 宿主侧行为未定义（实测某些情况下会直接返回旧的设备信息）。
      final res = await _dio.post(
        '/rw/pair/accept',
        data: jsonEncode({'token': clean}),
        options: Options(headers: {'cookie': null}),
      );

      final out = _parse(res);
      if (!out.ok) return out;

      final raw = res.headers['set-cookie'];
      final cookie = _extractDeviceCookie(raw);
      if (cookie == null) {
        return const ApiResult(
          ok: false,
          errorCode: 'no-cookie',
          errorMessage: '宿主没有下发设备凭据',
        );
      }
      await prefs.setCookie(cookie);
      reload();
      return out;
    } on DioException catch (e) {
      return ApiResult.network(_describeDio(e));
    } catch (e) {
      return ApiResult.network('配对失败：$e');
    }
  }

  /// 从 set-cookie 里抠出 `rw_device=xxx`。
  ///
  /// 只取 `name=value` 部分，属性（Path/HttpOnly/Max-Age）交给系统管。
  static String? _extractDeviceCookie(List<String>? raw) {
    if (raw == null) return null;
    for (final line in raw) {
      final first = line.split(';').first.trim();
      if (first.startsWith('rw_device=')) return first;
    }
    return null;
  }

  ApiResult _parse(Response<dynamic> res) {
    final code = res.statusCode ?? 0;
    final text = (res.data as String?) ?? '';
    Map<String, dynamic>? json;
    if (text.isNotEmpty) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {
        // 非 JSON 响应（比如网关的 HTML 错误页）—— 保留状态码，别吞掉
      }
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

  String _describeDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '请求超时';
      case DioExceptionType.connectionError:
        return '连不上 ${_dio.options.baseUrl}';
      case DioExceptionType.badCertificate:
        return '证书校验失败';
      case DioExceptionType.cancel:
        return '请求已取消';
      default:
        return e.message ?? '网络错误';
    }
  }
}
