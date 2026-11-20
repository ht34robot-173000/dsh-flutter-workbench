/// DSH 工作台 —— SSE 实时流客户端。
///
/// 连接宿主 `GET /rw/api/session.live`，把帧解析后通过 Stream 抛给上层。
///
/// ⚠️ **为什么不用 dio 拉 SSE**（2026-11-19 实测踩坑）
///
/// 一开始用 `dio.get<ResponseBody>(..., responseType: stream)`。
/// 实测日志：`resp status=200` → 收到第一个 chunk → 解析出 `LiveHello`
/// → **然后再也没有任何 chunk**。宿主那边明明在推数据。
///
/// 原因是 dio 的 `ResponseBody.stream` 在 `receiveTimeout: null` 的组合下
/// 不会持续吐字节（内部走了 buffering 路径）。SDK 的 stream 语义在
/// 「长连接 + 无超时」这个场景下不可靠。
///
/// 所以这里改用 **`dart:io` 的 `HttpClient` 裸连**：
///   - `send()` 拿 `HttpClientResponse`，它**本身就是**一个逐块吐字节的 Stream
///   - 不会做任何缓冲或聚合
///   - 也没有 dio 那些拦截器/转换层的干扰
///
/// 三条协议约束（都来自 Kotlin 版实测）：
///
///  1. **读超时必须关掉**：`idleTimeout = null`。普通超时会掐断长连接，
///     表现是「明明在跑却一直重连」。
///  2. **三类帧缺一不可**：status（转圈）/ event（正文）/ chunk（逐字）。
///  3. **注释帧（`: ping`）要忽略但不能判死连接**。Cloudflare 会掐空闲连接，
///     宿主每 20 秒发一行注释保活。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';

import 'chat_data.dart';
import 'prefs.dart';

class LiveClient {
  final Prefs prefs;

  StreamController<LiveFrame>? _ctrl;
  StreamSubscription? _lineSub;
  HttpClient? _client;

  /// 当前这条流是否已经**交给过**调用方。
  ///
  /// ⚠️ 单订阅流（StreamController.stream）**一辈子只能 listen 一次**：
  /// 即使上一个监听已经 cancel，再 listen 也会抛
  /// `Bad state: Stream has already been listened to`。
  ///
  /// 实测后果：进对话页 → 返回 → 再进另一个对话页，整个页面直接崩成灰屏
  /// （异常抛在 `initState` 里，界面只剩状态栏）。
  /// 所以这里记一笔，交出去过就在下次 `connect()` 重新开一条。
  bool _handed = false;

  /* ---------------- 自动重连 ---------------- */

  /// 重连计时器。连接断了之后定时重开，而不是躺着等用户杀进程。
  Timer? _retry;
  Timer? get retryTimer => _retry;

  /// 退避时长：3s → 6s → 12s → 30s 封顶。
  Duration _backoff = const Duration(seconds: 3);

  /// 主动 close（用户退出页面）时不再重连。
  bool _closedByUser = false;

  LiveClient(this.prefs);

  /// 开始监听。
  ///
  /// 用单订阅控制器：`connect()` 里立刻发起请求，而 `: connected` 和第一批帧
  /// 往往在调用方 `listen()` 之前就到。单订阅控制器的 `add()` 会进队列，
  /// 等 `listen()` 时一起冲出来，不会丢。（broadcast 控制器会直接丢弃。）
  Stream<LiveFrame> connect() {
    final existing = _ctrl;
    if (existing != null && !existing.isClosed && !_handed) {
      _handed = true;
      return existing.stream;
    }

    // 上一条流已经被消费过（或已关闭）：旧的连根收掉，重新开一条。
    if (existing != null && !existing.isClosed) {
      unawaited(existing.close());
    }
    unawaited(_lineSub?.cancel());
    _lineSub = null;
    _client?.close(force: true);
    _client = null;

    final ctrl = StreamController<LiveFrame>();
    _ctrl = ctrl;
    _handed = true;
    _start(ctrl);
    return ctrl.stream;
  }

  void _start(StreamController<LiveFrame> ctrl) {
    final base = prefs.baseUrl;
    if (base.isEmpty) {
      ctrl.add(const LiveStatus('', false));
      return;
    }

    unawaited(_open(Uri.parse('$base/rw/api/session.live'), ctrl));
  }

  Future<void> _open(Uri uri, StreamController<LiveFrame> ctrl) async {
    try {
      final client = HttpClient()
        // 连接超时给 15 秒（建连阶段需要它）
        ..connectionTimeout = const Duration(seconds: 15);

      /*
       * ⚠️ `idleTimeout` **不能设 null**（dart:io 里它是非空 Duration）。
       *
       * 但它和「长连接」并不冲突：`idleTimeout` 指的是**空闲多久后关闭
       * 这个 keep-alive 连接**。SSE 每隔 20 秒有 `: ping` 注释帧，
       * 连接永远不空闲，所以给一个比心跳长的值就够（这里 30 秒）。
       *
       * 真正会掐断长连接的是「读超时」——那在 dart:io 里由 socket 层控制，
       * HttpClient 没有暴露成参数，所以这里天然不设读超时。
       * 这和 dio 里必须 `receiveTimeout: null` 是同一件事的两种表现。
       */
      client.idleTimeout = const Duration(seconds: 30);

      _client = client;

      final req = await client.getUrl(uri);
      final ck = prefs.cookie ?? '';
      if (ck.isNotEmpty) req.headers.set('cookie', ck);
      req.headers.set('accept', 'text/event-stream');
      req.headers.set('cache-control', 'no-cache');
      // 关掉压缩：gzip 会让逐字流攒成一块才吐，打字机效果就没了
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      final resp = await req.close();
      if (resp.statusCode != 200) {
        if (!ctrl.isClosed) ctrl.add(const LiveStatus('', false));
        // 宿主刚重启时这里大概率是 502/530（隧道还没回来）→ 交给重连
        _scheduleRetry(ctrl);
        return;
      }

      // 连上了：退避归零，下次断线还从 3 秒开始
      _backoff = const Duration(seconds: 3);

      // HttpClientResponse 本身就是逐块吐字节的 Stream<List<int>>
      _lineSub = _pump(resp, ctrl);
    } catch (e) {
      if (!ctrl.isClosed) ctrl.add(const LiveStatus('', false));
      _scheduleRetry(ctrl);
    }
  }

  /// 排一次重连。
  ///
  /// 为什么要它：宿主（或隧道）重启后，旧的 SSE 是**已经死掉的 socket**，
  /// 不重开就永远收不到帧 —— 界面上表现就是「一直转圈 / 任务跑完了没反应」，
  /// 用户只能杀进程。这条重连让 App 自己缓过来。
  void _scheduleRetry(StreamController<LiveFrame> ctrl) {
    if (_closedByUser || ctrl.isClosed) return;
    _retry?.cancel();
    final wait = _backoff;
    _retry = Timer(wait, () {
      if (_closedByUser || ctrl.isClosed) return;
      // 退避翻倍，封顶 30 秒
      _backoff = Duration(
        seconds: math.min(_backoff.inSeconds * 2, 30),
      );
      unawaited(_lineSub?.cancel());
      _lineSub = null;
      _client?.close(force: true);
      _client = null;
      _start(ctrl);
    });
  }

  /// 逐块读字节 → 按行切 → 解析 `data:` 行。
  ///
  /// 坑（踩坑文档 5.3）：**不要在流上直接用 utf8.decoder**。
  /// 分块边界可能切断多字节汉字，结果是乱码。这里先攒字节，
  /// 遇到换行才解码整行 —— 行内一定是完整的 UTF-8 序列。
  StreamSubscription _pump(Stream<List<int>> stream, StreamController<LiveFrame> ctrl) {
    final pending = <int>[];

    return stream.listen(
      (chunk) {
        pending.addAll(chunk);
        while (true) {
          final idx = pending.indexOf(0x0A); // '\n'
          if (idx < 0) break;
          final lineBytes = pending.sublist(0, idx);
          pending.removeRange(0, idx + 1);
          if (lineBytes.isEmpty) continue;

          final line = utf8.decode(lineBytes, allowMalformed: true).trimRight();

          // 注释帧 / 空行：忽略。宿主每 20s 发 `: ping` 保活。
          if (line.isEmpty || line.startsWith(':')) continue;
          if (!line.startsWith('data:')) continue;

          final payload = line.substring(5).trimLeft();
          final frame = parseLiveFrame(payload);
          if (frame != null && !ctrl.isClosed) {
            ctrl.add(frame);
          }
        }
      },
      onError: (Object e) {
        if (!ctrl.isClosed) ctrl.add(const LiveStatus('', false));
        _scheduleRetry(ctrl);
      },
      onDone: () {
      },
      cancelOnError: false,
    );
  }

  /// 关闭。**必须在页面 dispose 里调**，否则连接泄漏、后台还在收数据；
  /// 更要紧的是：不关掉的话**下一条流没法重新开**（见 `_handed`）。
  Future<void> close() async {
    _closedByUser = true;
    _retry?.cancel();
    _retry = null;
    await _lineSub?.cancel();
    _lineSub = null;
    _client?.close(force: true);
    _client = null;
    final c = _ctrl;
    _ctrl = null;
    _handed = false;
    if (c != null && !c.isClosed) await c.close();
  }
}



