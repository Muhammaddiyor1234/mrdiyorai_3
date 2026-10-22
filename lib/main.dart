import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings();
  await settings.load();
  runApp(MrDiyorApp(settings: settings));
}

// ═════════════════════════════════════════════════════════════════════
//  API QISMI
// ═════════════════════════════════════════════════════════════════════

// DIQQAT: kalit kodga yozilgan. Bu faylni GitHub'ga yoki boshqalarga bermang!
// Xavfsizroq usullar:
//
// 1) Ishga tushirishda berish:
//    flutter run --dart-define=GROQ_KEY=gsk_yangi_kalitingiz
//    flutter build apk --dart-define=GROQ_KEY=gsk_yangi_kalitingiz
//
// 2) Bo'sh qoldirib, ilovadagi 🔑 tugmasi orqali kiritish.
//
// Agar --dart-define berilsa, o'sha kalit ustun turadi.
String get groqKey {
  const envKey = String.fromEnvironment('GROQ_KEY');
  if (envKey.isNotEmpty) return envKey;
  try {
    return utf8.decode(
      base64.decode('Z3NrX2ZHUEJmZFJBTnliRlNSYlJjVktXR2R5YjNZUUI5MXJBSEhocnUwcG03d1Mya0RjU0c='),
    );
  } catch (_) {
    return '';
  }
}

// Faqat Qwen modeli ishlatiladi
const String kQwenModel = 'qwen/qwen3.8-27b';
const List<String> kModels = [kQwenModel];

// Rasm uchun ham faqat Qwen (u rasm tushunishni qo'llaydi)
const List<String> kVisionModels = [kQwenModel];

// Groq BEPUL reja (qwen/qwen3.8-27b): 30 so'rov/daqiqa, 1 000 so'rov/kun,
// 8 000 token/daqiqa, 200 000 token/kun.
// Modelning texnik maksimumi 16 384, lekin bepul rejada daqiqalik limit 8 000
// bo'lgani uchun katta qiymat so'rovni rad ettirishi mumkin. Shuning uchun 4 000.
const int kMaxTokens = 4000;

// Suhbat tarixidan oxirgi nechta xabar yuboriladi (token tejash uchun)
const int kHistoryLimit = 12;

const String kGroqUrl = 'https://api.groq.com/openai/v1/chat/completions';

const String kGroqSttUrl =
    'https://api.groq.com/openai/v1/audio/transcriptions';
const String kSttModel = 'whisper-large-v3-turbo';
// Til avtomatik aniqlansin desangiz '' qoldiring
const String kSttLanguage = 'uz';

// ───────── Rasm yaratish (Pollinations, kalit shart emas) ─────────
const String kImageUrl = 'https://image.pollinations.ai/prompt';

// Ixtiyoriy: Pollinations kaliti (https://enter.pollinations.ai).
// Kalitsiz rejim 403 bersa, shu yerga kalit qo'ying yoki:
//   flutter run --dart-define=POLLI_KEY=sizning_kalitingiz
const String kPollinationsKey = String.fromEnvironment('POLLI_KEY');
const String kImageUrlKeyed = 'https://gen.pollinations.ai/image';

// Zaxira: AI Horde — bepul, ro'yxatdan o'tish shart emas (anonim kalit 0000000000).
// Pollinations 403 bersa, ilova avtomatik shunga o'tadi. Navbat bo'lgani uchun
// sekinroq (odatda 20–120 soniya).
const String kHordeUrl = 'https://aihorde.net/api/v2';
const String kHordeKey =
String.fromEnvironment('HORDE_KEY', defaultValue: '0000000000');

const String kImagePromptSystem =
    'You are an expert prompt engineer for a text-to-image model (FLUX). '
    'The request may be in ANY language (Uzbek, Russian, English, etc). '
    'Translate it faithfully to English and expand it into one vivid, detailed prompt: '
    'subject, specific details, composition, lighting, colors, mood, camera or medium, quality keywords. '
    'Keep every specific detail the request asks for. '
    'If the request wants text inside the image, include that text exactly in quotes. '
    'Pick the best style for the request (photorealistic, illustration, anime, 3D render, '
    'oil painting, flat vector logo, pixel art, etc) unless a style is specified. '
    'Never add watermarks or signatures. Maximum 90 words. '
    'Also choose the aspect: square (logo, avatar, icon, object), landscape (scenery, banner, desktop wallpaper), '
    'portrait (full-body person, phone wallpaper, poster). '
    'Output ONLY valid JSON, nothing else: {"prompt":"...","aspect":"square|landscape|portrait"}';

const String kSystemPrompt =
    "Sen Mr.Diyor AI san — foydalanuvchi bilan birga ishlaydigan aqlli yordamchi. "
    "Foydalanuvchi qaysi tilda yozsa, shu tilda javob ber (asosan o'zbek tilida). "
    "Hech qachon xitoy tilida yozma. "
    "Aniq, qisqa va foydali bo'l. Kod so'ralsa, ishlaydigan kod ber. "
    "Sen Muhammaddiyor Yusupov ismli shaxs tomonidan yaratilgansan. "
    "Ilovada rasm yaratish imkoniyati bor: foydalanuvchi rasm so'rasa, uni ilovaning o'zi chizadi. "
    "Hech qachon 'rasm yarata olmayman' dema; kerak bo'lsa foydalanuvchiga "
    "'rasm yarat: ...' deb yozishni yoki 🖌 tugmasini bosishni ayt.";

// ───────────────────────── Model ─────────────────────────
class Msg {
  final String role; // 'user' | 'assistant'
  final String text;
  final bool isError;
  final Uint8List? image;
  final GenImage? gen; // ilova yaratgan rasm
  Msg(this.role, this.text, {this.isError = false, this.image, this.gen});
}

class GenImage {
  final Uint8List bytes;
  final String prompt; // modelga ketgan inglizcha prompt
  final String request; // foydalanuvchining asl so'rovi
  final int width, height, seed;
  GenImage({
    required this.bytes,
    required this.prompt,
    required this.request,
    required this.width,
    required this.height,
    required this.seed,
  });
}

// ───────────────────────── AI xizmati ─────────────────────────
class AiService {
  static Future<String> send(List<Msg> history, String apiKey) async {
    final all = history.where((m) => !m.isError).toList();
    final clean =
    all.length > kHistoryLimit ? all.sublist(all.length - kHistoryLimit) : all;
    final hasImage = clean.isNotEmpty && clean.last.image != null;
    final models = hasImage ? kVisionModels : kModels;

    dynamic contentOf(int i, Msg m) {
      if (m.gen != null) {
        return '${m.text}\n[yaratilgan rasm tavsifi: ${m.gen!.prompt}]';
      }
      if (m.image == null) return m.text;
      if (i == clean.length - 1) {
        return [
          {
            'type': 'text',
            'text': m.text.isEmpty ? "Bu rasmni tushuntirib ber." : m.text
          },
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:image/jpeg;base64,${base64Encode(m.image!)}'
            }
          },
        ];
      }
      return '${m.text}\n[rasm yuborilgan edi]';
    }

    String lastError = '';
    for (final model in models) {
      final res = await http.post(
        Uri.parse(kGroqUrl),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer ${apiKey.trim()}',
        },
        body: jsonEncode({
          'model': model,
          'temperature': 0.7,
          'max_tokens': kMaxTokens,
          'messages': [
            {'role': 'system', 'content': kSystemPrompt},
            for (int i = 0; i < clean.length; i++)
              {'role': clean[i].role, 'content': contentOf(i, clean[i])},
          ],
        }),
      );

      Object? data;
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        data = null;
      }

      if (res.statusCode == 200 && data is Map) {
        final choices = data['choices'];
        String raw = '';
        if (choices is List && choices.isNotEmpty) {
          final msg = choices[0]['message'];
          if (msg is Map && msg['content'] != null) {
            raw = msg['content'].toString();
          }
        }
        // Qwen ba'zan <think>...</think> qismini qaytaradi — olib tashlaymiz
        final text =
        raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
        return text.isEmpty
            ? "Javob bo'sh keldi, qayta urinib ko'ring."
            : text;
      }

      String? apiMsg;
      if (data is Map && data['error'] is Map) {
        apiMsg = (data['error'] as Map)['message']?.toString();
      }
      lastError = apiMsg?.toString() ?? "Noma'lum xato (${res.statusCode})";
      if (res.statusCode == 401) {
        lastError = "API kalit noto'g'ri yoki bekor qilingan (401). $lastError";
      }
      if (res.statusCode == 413) {
        lastError =
        "So'rov juda katta (bepul limit: daqiqasiga 8 000 token). Yangi suhbat boshlang yoki 1 daqiqa kuting. $lastError";
      }
      if (res.statusCode == 429) {
        lastError =
        "Bepul limit tugadi (daqiqalik yoki kunlik). Biroz kutib qayta urinib ko'ring. $lastError";
      }
      if (res.statusCode == 403) {
        lastError =
        "Groq ruxsat bermadi (403). Hudud cheklovi yoki tarmoq bloki bo'lishi mumkin — VPN yoqib ko'ring. $lastError";
      }
      if (res.statusCode == 401 || res.statusCode == 429 || res.statusCode == 413) break;
    }
    throw Exception(lastError);
  }

  /// Har qanday tilda yozilgan so'rovdan rasm yaratadi.
  /// 1) Qwen so'rovni inglizcha batafsil promptga aylantiradi va nisbatni tanlaydi
  /// 2) Pollinations (FLUX) rasmni chizadi
  static Future<GenImage> generateImage(String request, String apiKey,
      {void Function(String)? onStatus}) async {
    String prompt = request;
    String aspect = 'square';

    try {
      final res = await http
          .post(
        Uri.parse(kGroqUrl),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer ${apiKey.trim()}',
        },
        body: jsonEncode({
          'model': kQwenModel,
          'temperature': 0.4,
          'max_tokens': 2500,
          'messages': [
            {'role': 'system', 'content': kImagePromptSystem},
            {'role': 'user', 'content': '$request /no_think'},
          ],
        }),
      )
          .timeout(const Duration(seconds: 45));

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        String raw = '';
        if (data is Map) {
          final ch = data['choices'];
          if (ch is List && ch.isNotEmpty) {
            final m = ch[0]['message'];
            if (m is Map && m['content'] != null) raw = m['content'].toString();
          }
        }
        raw = raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
        final jm = RegExp(r'\{[\s\S]*\}').firstMatch(raw);
        if (jm != null) {
          final j = jsonDecode(jm.group(0)!);
          if (j is Map) {
            final pr = (j['prompt'] ?? '').toString().trim();
            if (pr.isNotEmpty) prompt = pr;
            final asp = (j['aspect'] ?? '').toString().toLowerCase();
            if (asp == 'landscape' || asp == 'portrait' || asp == 'square') {
              aspect = asp;
            }
          }
        }
      }
    } catch (_) {
      // Prompt yaxshilanmasa ham, asl so'rov bilan davom etamiz
    }

    if (prompt.length > 900) prompt = prompt.substring(0, 900);

    final int w = aspect == 'landscape' ? 1344 : (aspect == 'portrait' ? 768 : 1024);
    final int h = aspect == 'landscape' ? 768 : (aspect == 'portrait' ? 1344 : 1024);
    final int seed = DateTime.now().millisecondsSinceEpoch % 1000000;

    final bytes = await _renderImage(prompt, w, h, seed, onStatus);
    return GenImage(
      bytes: bytes,
      prompt: prompt,
      request: request,
      width: w,
      height: h,
      seed: seed,
    );
  }

  static bool _looksLikeImage(Uint8List b) {
    if (b.length < 1000) return false;
    final jpg = b[0] == 0xFF && b[1] == 0xD8;
    final png = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E;
    final webp = b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46;
    return jpg || png || webp;
  }

  static String _clean(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('TimeoutException', 'Vaqt tugadi');

  static bool _polliBlocked = false; // 403 bo'lsa, qayta urinib o'tirmaymiz

  /// Avval Pollinations, bo'lmasa AI Horde.
  static Future<Uint8List> _renderImage(String prompt, int w, int h, int seed,
      void Function(String)? onStatus) async {
    final errors = <String>[];

    if (!_polliBlocked) {
      try {
        onStatus?.call('Rasm yaratilmoqda…');
        return await _pollinations(prompt, w, h, seed);
      } catch (e) {
        errors.add('Pollinations: ${_clean(e)}');
      }
    }

    try {
      return await _horde(prompt, w, h, seed, onStatus);
    } catch (e) {
      errors.add('AI Horde: ${_clean(e)}');
    }

    throw Exception(errors.join('\n'));
  }

  static Future<Uint8List> _pollinations(
      String prompt, int w, int h, int seed) async {
    final base = kPollinationsKey.isNotEmpty ? kImageUrlKeyed : kImageUrl;
    final url =
        '$base/${Uri.encodeComponent(prompt)}?width=$w&height=$h&seed=$seed&model=flux&nologo=true';
    final headers = <String, String>{
      if (!kIsWeb)
        'User-Agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
      'Accept': 'image/*,*/*;q=0.8',
      if (kPollinationsKey.isNotEmpty)
        'Authorization': 'Bearer $kPollinationsKey',
    };

    String lastErr = '';
    for (int attempt = 0; attempt < 3; attempt++) {
      final res = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 90));
      final ct = res.headers['content-type'] ?? '';
      if (res.statusCode == 200 &&
          (ct.startsWith('image/') || _looksLikeImage(res.bodyBytes))) {
        return res.bodyBytes;
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        _polliBlocked = true;
        throw Exception('ruxsat yo\'q (${res.statusCode})');
      }
      lastErr = res.statusCode == 429
          ? "server band (429)"
          : 'server xatosi (${res.statusCode})';
      if (attempt < 2) await Future.delayed(const Duration(seconds: 8));
    }
    throw Exception(lastErr);
  }

  static Future<Uint8List> _horde(String prompt, int w, int h, int seed,
      void Function(String)? onStatus) async {
    // Horde o'lchamlari 64 ga karrali bo'lishi kerak
    final hw = w > h ? 768 : 512;
    final hh = h > w ? 768 : 512;
    final headers = <String, String>{
      'content-type': 'application/json',
      'apikey': kHordeKey,
      'Client-Agent': 'MrDiyorAI:1.0:anonymous',
    };

    onStatus?.call("Zaxira server: navbatga qo'yilmoqda…");
    final sub = await http
        .post(
      Uri.parse('$kHordeUrl/generate/async'),
      headers: headers,
      body: jsonEncode({
        'prompt': prompt,
        'params': {
          'width': hw,
          'height': hh,
          'steps': 25,
          'n': 1,
          'cfg_scale': 7,
          'sampler_name': 'k_euler_a',
          'seed': '$seed',
        },
        'nsfw': false,
        'censor_nsfw': true,
        'r2': true,
        'slow_workers': true,
      }),
    )
        .timeout(const Duration(seconds: 30));

    final subData = jsonDecode(utf8.decode(sub.bodyBytes));
    if ((sub.statusCode != 200 && sub.statusCode != 202) ||
        subData is! Map ||
        subData['id'] == null) {
      String msg = 'xato (${sub.statusCode})';
      if (subData is Map && subData['message'] != null) {
        msg = subData['message'].toString();
      }
      throw Exception(msg);
    }
    final id = subData['id'].toString();

    // Tayyor bo'lguncha kutamiz (eng ko'pi bilan ~5 daqiqa)
    bool done = false;
    for (int i = 0; i < 100 && !done; i++) {
      await Future.delayed(const Duration(seconds: 3));
      final c = await http
          .get(Uri.parse('$kHordeUrl/generate/check/$id'),
          headers: {'Client-Agent': headers['Client-Agent']!})
          .timeout(const Duration(seconds: 20));
      final cd = jsonDecode(utf8.decode(c.bodyBytes));
      if (cd is! Map) continue;
      if (cd['faulted'] == true) {
        throw Exception('generatsiya xatosi (faulted)');
      }
      if (cd['done'] == true) {
        done = true;
        break;
      }
      final qp = cd['queue_position'];
      final wt = cd['wait_time'];
      onStatus?.call(
          'Zaxira server: navbat ${qp ?? '?'} · taxminan ${wt ?? '?'} soniya…');
    }
    if (!done) {
      try {
        await http.delete(Uri.parse('$kHordeUrl/generate/status/$id'),
            headers: headers);
      } catch (_) {}
      throw Exception("juda uzoq kutildi (navbat band). Keyinroq urinib ko'ring");
    }

    final st = await http
        .get(Uri.parse('$kHordeUrl/generate/status/$id'),
        headers: {'Client-Agent': headers['Client-Agent']!})
        .timeout(const Duration(seconds: 30));
    final sd = jsonDecode(utf8.decode(st.bodyBytes));
    if (sd is! Map || sd['generations'] is! List || (sd['generations'] as List).isEmpty) {
      throw Exception('natija topilmadi');
    }
    final gen = (sd['generations'] as List)[0];
    if (gen is Map && gen['censored'] == true) {
      throw Exception("rasm filtrdan o'tmadi, boshqacha tasvirlab ko'ring");
    }
    final img = (gen is Map ? gen['img'] : null)?.toString() ?? '';
    if (img.isEmpty) throw Exception("rasm bo'sh keldi");

    if (img.startsWith('http')) {
      final r = await http.get(Uri.parse(img)).timeout(const Duration(seconds: 60));
      if (r.statusCode == 200 && _looksLikeImage(r.bodyBytes)) return r.bodyBytes;
      throw Exception('rasmni yuklab bo\'lmadi (${r.statusCode})');
    }
    final bytes = base64Decode(img);
    if (!_looksLikeImage(Uint8List.fromList(bytes))) {
      throw Exception("rasm formati noto'g'ri");
    }
    return Uint8List.fromList(bytes);
  }

  /// Ovozni matnga aylantiradi (bayt orqali, web va mobil uchun bir xil)
  static Future<String> transcribe(
      Uint8List bytes, String filename, String apiKey) async {
    final req = http.MultipartRequest('POST', Uri.parse(kGroqSttUrl))
      ..headers['authorization'] = 'Bearer ${apiKey.trim()}'
      ..fields['model'] = kSttModel
      ..fields['response_format'] = 'json';
    if (kSttLanguage.isNotEmpty) req.fields['language'] = kSttLanguage;
    req.files
        .add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    final res = await http.Response.fromStream(await req.send());
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode == 200) return (data['text'] ?? '').toString().trim();
    throw Exception(
        data['error']?['message'] ?? "Noma'lum xato (${res.statusCode})");
  }
}

// ═════════════════════════════════════════════════════════════════════
//  DIZAYN TIZIMI
// ═════════════════════════════════════════════════════════════════════

enum DesignStyle { minimal, neumorphism, glass, clay, maximal }

extension DesignStyleInfo on DesignStyle {
  String get title => switch (this) {
    DesignStyle.minimal => 'Minimalizm',
    DesignStyle.neumorphism => 'Neumorfizm',
    DesignStyle.glass => 'Glassmorfizm',
    DesignStyle.clay => 'Claymorfizm',
    DesignStyle.maximal => 'Maksimalizm',
  };

  String get subtitle => switch (this) {
    DesignStyle.minimal => 'Toza va tez',
    DesignStyle.neumorphism => 'Yumshoq 3D',
    DesignStyle.glass => 'Shishasimon',
    DesignStyle.clay => 'Puflama loy',
    DesignStyle.maximal => 'Yorqin va jasur',
  };

  String get emoji => switch (this) {
    DesignStyle.minimal => '◻️',
    DesignStyle.neumorphism => '🫧',
    DesignStyle.glass => '💎',
    DesignStyle.clay => '🧸',
    DesignStyle.maximal => '🎉',
  };
}

const List<Color> kSwatches = [
  Color(0xFF7C5CFF),
  Color(0xFF22D3EE),
  Color(0xFFFF4D9D),
  Color(0xFFFF7A00),
  Color(0xFF2979FF),
  Color(0xFF00BFA5),
  Color(0xFF43A047),
  Color(0xFFFFC400),
];

const Color kErrorPink = Color(0xFFFF4D9D);

class AppSettings extends ChangeNotifier {
  DesignStyle style = DesignStyle.glass;
  bool dark = true;
  int accentIndex = 0;
  double fontSize = 15;

  Color get accent => kSwatches[accentIndex];

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final si = p.getInt('ui_style');
      if (si != null && si >= 0 && si < DesignStyle.values.length) {
        style = DesignStyle.values[si];
      }
      dark = p.getBool('ui_dark') ?? dark;
      final ai = p.getInt('ui_accent');
      if (ai != null && ai >= 0 && ai < kSwatches.length) accentIndex = ai;
      fontSize = p.getDouble('ui_font') ?? fontSize;
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('ui_style', style.index);
      await p.setBool('ui_dark', dark);
      await p.setInt('ui_accent', accentIndex);
      await p.setDouble('ui_font', fontSize);
    } catch (_) {}
  }

  void change(VoidCallback fn) {
    fn();
    notifyListeners();
    _save();
  }
}

class SettingsScope extends InheritedNotifier<AppSettings> {
  const SettingsScope({
    super.key,
    required AppSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static AppSettings of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<SettingsScope>()!.notifier!;

  static AppSettings read(BuildContext c) =>
      c.getInheritedWidgetOfExactType<SettingsScope>()!.notifier!;
}

// ───────────────────────── Rang yordamchilari ─────────────────────────
Color a(Color c, double o) => c.withAlpha((o.clamp(0.0, 1.0) * 255).round());

Color lighten(Color c, double amt) {
  final h = HSLColor.fromColor(c);
  return h
      .withLightness((h.lightness + amt).clamp(0.0, 1.0).toDouble())
      .toColor();
}

Color darken(Color c, double amt) => lighten(c, -amt);

Color onColor(Color c) =>
    c.computeLuminance() > 0.55 ? const Color(0xFF111111) : Colors.white;

class Pal {
  const Pal({
    required this.bg,
    required this.surface,
    required this.text,
    required this.sub,
    required this.ink,
    required this.shadowInk,
    required this.border,
  });

  final Color bg, surface, text, sub, ink, shadowInk, border;

  static Pal of(DesignStyle s, bool d) {
    switch (s) {
      case DesignStyle.minimal:
        return d
            ? const Pal(
            bg: Color(0xFF0B0B0D),
            surface: Color(0xFF17171A),
            text: Color(0xFFF4F4F5),
            sub: Color(0xFFA1A1AA),
            ink: Color(0xFFF4F4F5),
            shadowInk: Color(0xFFF4F4F5),
            border: Color(0xFF2A2A2E))
            : const Pal(
            bg: Color(0xFFFAFAFA),
            surface: Color(0xFFFFFFFF),
            text: Color(0xFF18181B),
            sub: Color(0xFF71717A),
            ink: Color(0xFF18181B),
            shadowInk: Color(0xFF18181B),
            border: Color(0xFFE4E4E7));
      case DesignStyle.neumorphism:
        return d
            ? const Pal(
            bg: Color(0xFF2B2E33),
            surface: Color(0xFF2B2E33),
            text: Color(0xFFE4E7EB),
            sub: Color(0xFF9AA3AD),
            ink: Color(0xFFE4E7EB),
            shadowInk: Color(0xFF000000),
            border: Color(0x00000000))
            : const Pal(
            bg: Color(0xFFE0E5EC),
            surface: Color(0xFFE0E5EC),
            text: Color(0xFF3D4852),
            sub: Color(0xFF7A8794),
            ink: Color(0xFF3D4852),
            shadowInk: Color(0xFFA3B1C6),
            border: Color(0x00000000));
      case DesignStyle.glass:
        return d
            ? const Pal(
            bg: Color(0xFF0A0B1E),
            surface: Color(0xFF1B2347),
            text: Color(0xFFF2F3FF),
            sub: Color(0xFFA6A9C9),
            ink: Color(0xFFF2F3FF),
            shadowInk: Color(0xFF000000),
            border: Color(0x38FFFFFF))
            : const Pal(
            bg: Color(0xFFDDE6FF),
            surface: Color(0xFFFFFFFF),
            text: Color(0xFF14213D),
            sub: Color(0xFF4A5878),
            ink: Color(0xFF14213D),
            shadowInk: Color(0xFF000000),
            border: Color(0xCCFFFFFF));
      case DesignStyle.clay:
        return d
            ? const Pal(
            bg: Color(0xFF2B2340),
            surface: Color(0xFF3E3360),
            text: Color(0xFFF3ECFF),
            sub: Color(0xFFBDB0D8),
            ink: Color(0xFFF3ECFF),
            shadowInk: Color(0xFF000000),
            border: Color(0x2EFFFFFF))
            : const Pal(
            bg: Color(0xFFF1E7FF),
            surface: Color(0xFFFFFFFF),
            text: Color(0xFF4A3B63),
            sub: Color(0xFF8C7BA8),
            ink: Color(0xFF4A3B63),
            shadowInk: Color(0xFF6B4FA0),
            border: Color(0xB3FFFFFF));
      case DesignStyle.maximal:
        return d
            ? const Pal(
            bg: Color(0xFF1B0B33),
            surface: Color(0xFF3B1C73),
            text: Color(0xFFFFFFFF),
            sub: Color(0xFFE0D0FF),
            ink: Color(0xFFFFFFFF),
            shadowInk: Color(0xFFFF2E93),
            border: Color(0xFFFFFFFF))
            : const Pal(
            bg: Color(0xFFFFE45E),
            surface: Color(0xFFBDF4FF),
            text: Color(0xFF000000),
            sub: Color(0xFF3A3A3A),
            ink: Color(0xFF000000),
            shadowInk: Color(0xFF000000),
            border: Color(0xFF000000));
    }
  }
}

const _dur = Duration(milliseconds: 220);

// ───────────────────────── Universal Surface ─────────────────────────
class Surface extends StatelessWidget {
  const Surface({
    super.key,
    this.child = const SizedBox.shrink(),
    this.radius = 20,
    this.padding = const EdgeInsets.all(14),
    this.filled = false,
    this.pressed = false,
    this.sunken = false,
    this.color,
    this.styleOverride,
    this.width,
    this.height,
  });

  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final bool filled;
  final bool pressed;
  final bool sunken;
  final Color? color;
  final DesignStyle? styleOverride;
  final double? width, height;

  @override
  Widget build(BuildContext context) {
    final cfg = SettingsScope.of(context);
    final st = styleOverride ?? cfg.style;
    final d = cfg.dark;
    final p = Pal.of(st, d);
    final tint = filled ? cfg.accent : color;

    final hasSize = width != null || height != null;
    final inner = hasSize
        ? Center(child: Padding(padding: padding, child: child))
        : Padding(padding: padding, child: child);

    final out = switch (st) {
      DesignStyle.minimal => _minimal(p, tint, inner),
      DesignStyle.neumorphism => _neu(p, d, tint, inner),
      DesignStyle.glass => _glass(d, tint, inner),
      DesignStyle.clay => _clay(p, d, tint, inner),
      DesignStyle.maximal => _maximal(p, cfg.accent, tint, inner),
    };
    return hasSize ? SizedBox(width: width, height: height, child: out) : out;
  }

  Widget _minimal(Pal p, Color? tint, Widget inner) {
    var fill = tint ?? p.surface;
    if (pressed) fill = darken(fill, .04);
    return AnimatedContainer(
      duration: _dur,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: tint != null ? fill : p.border, width: 1),
      ),
      child: inner,
    );
  }

  Widget _neu(Pal p, bool d, Color? tint, Widget inner) {
    final base = tint ?? p.bg;
    final down = pressed || sunken;
    final shLight = d ? a(Colors.white, .07) : a(Colors.white, .9);
    final shDark = d ? a(Colors.black, .55) : a(p.shadowInk, .65);
    final dist = down ? 2.5 : 7.0;
    final blur = down ? 5.0 : 16.0;
    return AnimatedContainer(
      duration: _dur,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: down
              ? [darken(base, .05), lighten(base, .03)]
              : [lighten(base, .035), darken(base, .04)],
        ),
        boxShadow: [
          BoxShadow(color: shDark, offset: Offset(dist, dist), blurRadius: blur),
          BoxShadow(
              color: shLight, offset: Offset(-dist, -dist), blurRadius: blur),
        ],
      ),
      child: inner,
    );
  }

  Widget _glass(bool d, Color? tint, Widget inner) {
    final br = BorderRadius.circular(radius);
    final colors = tint != null
        ? [a(tint, .80), a(tint, .50)]
        : [a(Colors.white, d ? .16 : .60), a(Colors.white, d ? .05 : .22)];
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: [
          BoxShadow(
              color: a(Colors.black, d ? .35 : .10),
              blurRadius: 30,
              offset: const Offset(0, 10)),
        ],
      ),
      child: ClipRRect(
        borderRadius: br,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: AnimatedContainer(
            duration: _dur,
            decoration: BoxDecoration(
              borderRadius: br,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: pressed ? colors.reversed.toList() : colors,
              ),
              border:
              Border.all(color: a(Colors.white, d ? .22 : .85), width: 1.2),
            ),
            child: inner,
          ),
        ),
      ),
    );
  }

  Widget _clay(Pal p, bool d, Color? tint, Widget inner) {
    final c = tint ?? p.surface;
    return AnimatedContainer(
      duration: _dur,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius * 1.25),
        gradient: RadialGradient(
          center: const Alignment(-.6, -.8),
          radius: 1.7,
          colors: [lighten(c, .14), c, darken(c, .10)],
          stops: const [0, .5, 1],
        ),
        border: Border.all(color: a(Colors.white, d ? .18 : .70), width: 2),
        boxShadow: [
          BoxShadow(
            color: a(darken(c, .30), d ? .70 : .45),
            offset: Offset(0, pressed ? 4 : 10),
            blurRadius: pressed ? 8 : 20,
            spreadRadius: -2,
          ),
          BoxShadow(
            color: a(Colors.white, d ? .10 : .90),
            offset: const Offset(-4, -4),
            blurRadius: 8,
          ),
        ],
      ),
      child: inner,
    );
  }

  Widget _maximal(Pal p, Color accent, Color? tint, Widget inner) {
    final off = pressed ? 2.0 : 6.0;
    final fill = tint ?? p.surface;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      transform: Matrix4.translationValues(pressed ? 4 : 0, pressed ? 4 : 0, 0),
      decoration: BoxDecoration(
        color: filled ? null : fill,
        gradient: filled
            ? LinearGradient(colors: [accent, const Color(0xFFFF3D81)])
            : null,
        borderRadius: BorderRadius.circular(radius * .6),
        border: Border.all(color: p.ink, width: 3),
        boxShadow: [
          BoxShadow(color: p.shadowInk, offset: Offset(off, off), blurRadius: 0),
        ],
      ),
      child: inner,
    );
  }
}

// ───────────────────────── Bosiladigan element ─────────────────────────
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.builder, this.onTap});

  final Widget Function(bool pressed) builder;
  final VoidCallback? onTap;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: enabled
          ? () {
        HapticFeedback.selectionClick();
        widget.onTap!();
      }
          : null,
      child: AnimatedScale(
        scale: _down ? .96 : 1,
        duration: const Duration(milliseconds: 120),
        child: widget.builder(_down),
      ),
    );
  }
}

// ───────────────────────── Orqa fon ─────────────────────────
class StyleBackground extends StatelessWidget {
  const StyleBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final cfg = SettingsScope.of(context);
    final p = Pal.of(cfg.style, cfg.dark);
    final key = ValueKey('${cfg.style}-${cfg.dark}-${cfg.accentIndex}');
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: SizedBox.expand(key: key, child: _build(cfg, p)),
    );
  }

  Widget _orb(Color c, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [a(c, .85), a(c, 0)]),
    ),
  );

  Widget _build(AppSettings cfg, Pal p) {
    switch (cfg.style) {
      case DesignStyle.minimal:
      case DesignStyle.neumorphism:
        return ColoredBox(color: p.bg);

      case DesignStyle.glass:
        if (cfg.dark) {
          return Stack(children: [
            ColoredBox(color: p.bg, child: const SizedBox.expand()),
            Positioned(
                top: -120,
                left: -100,
                child: _orb(const Color(0xFF7C5CFF), 460)),
            Positioned(
                top: 220,
                right: -160,
                child: _orb(const Color(0xFF22D3EE), 420)),
            Positioned(
                bottom: -140,
                left: -60,
                child: _orb(const Color(0xFFFF4D9D), 440)),
          ]);
        }
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFDDE6FF), Color(0xFFFDE7F3), Color(0xFFFFF1DB)],
            ),
          ),
          child: Stack(children: [
            Positioned(top: -90, left: -70, child: _orb(cfg.accent, 320)),
            Positioned(
                bottom: -110,
                right: -90,
                child: _orb(const Color(0xFF7B61FF), 360)),
            Positioned(
                top: 320,
                right: -70,
                child: _orb(const Color(0xFF00D1FF), 240)),
          ]),
        );

      case DesignStyle.clay:
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [lighten(p.bg, .03), darken(p.bg, .03)],
            ),
          ),
          child: Stack(children: [
            Positioned(top: -60, right: -60, child: _orb(cfg.accent, 260)),
            Positioned(
                bottom: -80,
                left: -80,
                child: _orb(const Color(0xFF8E7CFF), 300)),
          ]),
        );

      case DesignStyle.maximal:
        return ColoredBox(
          color: p.bg,
          child: CustomPaint(
              painter: _MaximalPainter(p.ink, cfg.accent), size: Size.infinite),
        );
    }
  }
}

class _MaximalPainter extends CustomPainter {
  _MaximalPainter(this.ink, this.accent);
  final Color ink, accent;

  @override
  void paint(Canvas canvas, Size s) {
    final dot = Paint()..color = a(ink, .16);
    for (double x = 14; x < s.width; x += 28) {
      for (double y = 14; y < s.height; y += 28) {
        canvas.drawCircle(Offset(x, y), 1.8, dot);
      }
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = ink;

    final c = Offset(s.width * .92, s.height * .14);
    canvas.drawCircle(c, 58, Paint()..color = accent);
    canvas.drawCircle(c, 58, stroke);

    canvas.save();
    canvas.translate(s.width * .07, s.height * .60);
    canvas.rotate(.4);
    final r = RRect.fromRectAndRadius(
        const Rect.fromLTWH(-34, -34, 68, 68), const Radius.circular(10));
    canvas.drawRRect(r, Paint()..color = const Color(0xFFFF3D81));
    canvas.drawRRect(r, stroke);
    canvas.restore();

    final path = Path()
      ..moveTo(s.width * .80, s.height * .86)
      ..lineTo(s.width * .93, s.height * .86)
      ..lineTo(s.width * .865, s.height * .78)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF00D1FF));
    canvas.drawPath(path, stroke);

    final zig = Path()..moveTo(s.width * .05, s.height * .22);
    for (int i = 1; i <= 6; i++) {
      zig.relativeLineTo(14, i.isOdd ? -14 : 14);
    }
    canvas.drawPath(zig, stroke);
  }

  @override
  bool shouldRepaint(_MaximalPainter o) => o.ink != ink || o.accent != accent;
}

// ═════════════════════════════════════════════════════════════════════
//  ILOVA
// ═════════════════════════════════════════════════════════════════════

TextTheme _fontFor(DesignStyle s, TextTheme base) => switch (s) {
  DesignStyle.minimal => GoogleFonts.interTextTheme(base),
  DesignStyle.neumorphism => GoogleFonts.nunitoTextTheme(base),
  DesignStyle.glass => GoogleFonts.manropeTextTheme(base),
  DesignStyle.clay => GoogleFonts.nunitoTextTheme(base),
  DesignStyle.maximal => GoogleFonts.spaceGroteskTextTheme(base),
};

class MrDiyorApp extends StatelessWidget {
  const MrDiyorApp({super.key, required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return SettingsScope(
      settings: settings,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final base = ThemeData(
            useMaterial3: true,
            brightness: settings.dark ? Brightness.dark : Brightness.light,
            colorSchemeSeed: settings.accent,
          );
          return MaterialApp(
            title: 'Mr.Diyor AI',
            debugShowCheckedModeBanner: false,
            theme: base.copyWith(
              textTheme: _fontFor(settings.style, base.textTheme),
            ),
            home: const ChatPage(),
          );
        },
      ),
    );
  }
}

// ───────────────────────── Chat sahifasi ─────────────────────────
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final List<Msg> _messages = [];
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _picker = ImagePicker();
  final _recorder = AudioRecorder();

  bool _loading = false;
  String _apiKey = '';
  Uint8List? _pendingImage;
  bool _recording = false;
  bool _transcribing = false;
  bool _imageMode = false; // 🖌 tugmasi: har bir xabar rasmga aylanadi
  bool _generating = false;
  String _genStatus = 'Rasm yaratilmoqda…';

  static const _suggestions = [
    "Menga bugungi ish rejasini tuzib ber",
    "Flutter'da state management nima?",
    "Ingliz tilida rasmiy xat yozishga yordam ber",
    "Bu g'oyani birga muhokama qilaylik",
    "Quyosh botayotgan tog' manzarasining rasmini yarat",
  ];

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  // Agar --dart-define=GROQ_KEY berilgan bo'lsa, o'sha kalit ustun turadi.
  // Aks holda telefonda saqlangan kalit ishlatiladi.
  Future<void> _loadKey() async {
    final p = await SharedPreferences.getInstance();
    final saved = (p.getString('api_key') ?? '').trim();
    if (!mounted) return;
    setState(() => _apiKey = saved.isNotEmpty ? saved : groqKey.trim());
  }

  Future<void> _saveKey(String key) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('api_key', key.trim());
    if (!mounted) return;
    setState(() => _apiKey = key.trim());
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ───────────── Rasm: kamera / galereya ─────────────
  Future<void> _pickImage(ImageSource src) async {
    try {
      final x = await _picker.pickImage(
        source: src,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 75,
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (!mounted) return;
      setState(() => _pendingImage = bytes);
    } catch (e) {
      _toast("Rasmni olib bo'lmadi: $e");
    }
  }

  void _openAttach() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final cfg = SettingsScope.of(ctx);
        final p = Pal.of(cfg.style, cfg.dark);
        Widget tile(IconData icon, String label, ImageSource src) => Pressable(
          onTap: () {
            Navigator.pop(ctx);
            _pickImage(src);
          },
          builder: (pressed) => Surface(
            radius: 18,
            pressed: pressed,
            padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(children: [
              Icon(icon, color: p.text),
              const SizedBox(width: 14),
              Text(label,
                  style: TextStyle(
                      color: p.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
            ]),
          ),
        );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Surface(
              radius: 28,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  tile(Icons.photo_camera_outlined, 'Rasmga olish',
                      ImageSource.camera),
                  const SizedBox(height: 12),
                  tile(Icons.photo_library_outlined, 'Galereyadan tanlash',
                      ImageSource.gallery),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ───────────── Ovozli xabar ─────────────
  Future<void> _toggleRecord() async {
    if (_transcribing || _loading) return;

    // To'xtatish va matnga aylantirish
    if (_recording) {
      String? path;
      try {
        path = await _recorder.stop();
      } catch (e) {
        _toast("Yozishni to'xtatib bo'lmadi: $e");
      }
      setState(() {
        _recording = false;
        _transcribing = path != null;
      });
      if (path == null) return;
      try {
        // XFile ham mobil yo'l, ham web blob URL bilan ishlaydi
        final bytes = await XFile(path).readAsBytes();
        final name = kIsWeb ? 'voice.webm' : 'voice.m4a';
        final t = await AiService.transcribe(bytes, name, _apiKey);
        if (t.isEmpty) {
          _toast("Ovoz tanilmadi, qayta urinib ko'ring");
        } else {
          final cur = _controller.text;
          _controller.text = cur.isEmpty ? t : '$cur $t';
          _controller.selection =
              TextSelection.collapsed(offset: _controller.text.length);
        }
      } catch (e) {
        _toast('Xatolik: ${e.toString().replaceFirst('Exception: ', '')}');
      } finally {
        if (mounted) setState(() => _transcribing = false);
      }
      return;
    }

    // Yozishni boshlash
    if (_apiKey.isEmpty) {
      _openSettings();
      return;
    }
    try {
      if (!await _recorder.hasPermission()) {
        _toast('Mikrofonga ruxsat berilmadi');
        return;
      }
      String path = '';
      if (!kIsWeb) {
        final dir = await getTemporaryDirectory();
        path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      }
      await _recorder.start(
        RecordConfig(encoder: kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc),
        path: path,
      );
      setState(() => _recording = true);
    } catch (e) {
      _toast("Mikrofonni ishga tushirib bo'lmadi: $e");
    }
  }

  // ───────────── Rasm yaratish ─────────────
  // Matnda "rasm yarat", "logo chizib ber", "draw ...", "нарисуй ..." kabi
  // iboralar bo'lsa, ilova o'zi rasm yaratadi.
  static final RegExp _imgAsk = RegExp(
    r'(rasm|surat|tasvir|logo|poster|banner|illyustratsiya|ikonka|avatar|portret|oboy|wallpaper|картин|изображ|рисун|image|picture|photo|illustration)\w*[^.!?\n]{0,60}(yarat|yasa|chiz|generat|tayyorla|сгенер|созда|нарису|make|create|draw|paint)'
    r'|(yarat|yasa|chiz|generat|нарисуй|сгенерируй|создай|create|make|draw|paint|imagine)\w*[^.!?\n]{0,60}(rasm|surat|tasvir|logo|poster|banner|ikonka|avatar|portret|картин|изображ|рисун|image|picture|photo|illustration)'
    r'|^(/imagine|/rasm)',
    caseSensitive: false,
    unicode: true,
  );
  static final RegExp _codeWords = RegExp(
    r'(flutter|dart|canvas|custompaint|painter|python|javascript|html|css|kod\b|code|funksiya|function|\bapi\b|svg|opencv|matplotlib|class\b)',
    caseSensitive: false,
  );

  bool _wantsImage(String t) => _imgAsk.hasMatch(t) && !_codeWords.hasMatch(t);

  Future<void> _generate(String request) async {
    setState(() {
      _loading = true;
      _generating = true;
      _genStatus = 'Rasm yaratilmoqda…';
    });
    _scrollDown();
    try {
      final g = await AiService.generateImage(
        request,
        _apiKey,
        onStatus: (t) {
          if (mounted) setState(() => _genStatus = t);
        },
      );
      if (mounted) {
        setState(() =>
            _messages.add(Msg('assistant', 'Mana sizning rasmingiz 🎨', gen: g)));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _messages.add(Msg(
          'assistant',
          "Rasm yaratib bo'lmadi: ${e.toString().replaceFirst('Exception: ', '')}\n"
              "Birozdan so'ng qayta urinib ko'ring.",
          isError: true,
        )));
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _generating = false;
        });
        _scrollDown();
        _focus.requestFocus();
      }
    }
  }

  void _regenerate(String request) {
    if (_loading) return;
    _generate(request);
  }

  // ───────────── Yuborish ─────────────
  Future<void> _send([String? preset]) async {
    final text = (preset ?? _controller.text).trim();
    final img = preset == null ? _pendingImage : null;
    if ((text.isEmpty && img == null) || _loading) return;

    // Rasm biriktirilgan bo'lsa — tahlil (chat); aks holda rasm so'ralganmi?
    final makeImage =
        img == null && text.isNotEmpty && (_imageMode || _wantsImage(text));

    if (!makeImage && _apiKey.isEmpty) {
      _openSettings();
      return;
    }

    setState(() {
      _messages.add(Msg('user', text, image: img));
      _pendingImage = null;
      _loading = true;
      _controller.clear();
    });
    _scrollDown();

    if (makeImage) {
      await _generate(text);
      return;
    }

    try {
      final reply = await AiService.send(_messages, _apiKey);
      if (mounted) setState(() => _messages.add(Msg('assistant', reply)));
    } catch (e) {
      if (mounted) {
        setState(() => _messages.add(Msg(
          'assistant',
          "Xatolik: ${e.toString().replaceFirst('Exception: ', '')}\n"
              "API kalitni sozlamalarda tekshiring.",
          isError: true,
        )));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _scrollDown();
        _focus.requestFocus();
      }
    }
  }

  // 🔑 API kalit oynasi
  void _openSettings() {
    final ctrl = TextEditingController(text: _apiKey);
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) {
        final cfg = SettingsScope.of(ctx);
        final p = Pal.of(cfg.style, cfg.dark);
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Surface(
              radius: 28,
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Groq API kalit',
                      style: TextStyle(
                          color: p.text,
                          fontSize: 20,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text(
                    "Groq API kalitingizni kiriting (gsk_...). Kalit faqat shu qurilmada saqlanadi.",
                    style: TextStyle(color: p.sub, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  Surface(
                    radius: 16,
                    sunken: true,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: ctrl,
                      obscureText: true,
                      cursorColor: cfg.accent,
                      style: TextStyle(color: p.text),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'gsk_...',
                        hintStyle: TextStyle(color: p.sub),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text('Bekor qilish',
                            style: TextStyle(color: p.sub)),
                      ),
                      const SizedBox(width: 8),
                      Pressable(
                        onTap: () {
                          _saveKey(ctrl.text);
                          Navigator.pop(ctx);
                        },
                        builder: (pressed) => Surface(
                          radius: 16,
                          filled: true,
                          pressed: pressed,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 22, vertical: 12),
                          child: Text('Saqlash',
                              style: TextStyle(
                                  color: onColor(cfg.accent),
                                  fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // 🎨 Dizayn sozlamalari
  void _openDesign() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DesignSheet(onClear: () => setState(_messages.clear)),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _focus.dispose();
    _recorder.dispose();
    super.dispose();
  }

  // ───────────── UI ─────────────
  @override
  Widget build(BuildContext context) {
    final cfg = SettingsScope.of(context);
    final p = Pal.of(cfg.style, cfg.dark);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: cfg.dark ? Brightness.light : Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: p.bg,
        body: Stack(
          children: [
            const Positioned.fill(child: StyleBackground()),
            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                    child: Column(
                      children: [
                        _header(cfg, p),
                        const SizedBox(height: 12),
                        Expanded(
                          child: _messages.isEmpty
                              ? _welcome(cfg, p)
                              : _list(cfg),
                        ),
                        const SizedBox(height: 12),
                        _inputBar(cfg, p),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(
      IconData icon, Color color, String tip, VoidCallback? onTap) =>
      Tooltip(
        message: tip,
        child: Pressable(
          onTap: onTap,
          builder: (pressed) => Surface(
            width: 40,
            height: 40,
            radius: 20,
            pressed: pressed,
            padding: EdgeInsets.zero,
            child: Icon(icon, color: color, size: 20),
          ),
        ),
      );

  Widget _header(AppSettings cfg, Pal p) {
    final maxi = cfg.style == DesignStyle.maximal;
    return Surface(
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Surface(
            width: 42,
            height: 42,
            radius: 21,
            filled: true,
            padding: EdgeInsets.zero,
            child:
            Icon(Icons.auto_awesome, size: 20, color: onColor(cfg.accent)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mr.Diyor AI',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: p.text,
                        fontSize: 18,
                        fontWeight: maxi ? FontWeight.w900 : FontWeight.w800,
                        letterSpacing: maxi ? 1 : 0)),
                Text(
                  _loading
                      ? (_generating ? 'Rasm chizmoqda…' : 'Yozmoqda…')
                      : 'Siz bilan birga ishlashga tayyor',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: p.sub),
                ),
              ],
            ),
          ),
          _iconBtn(Icons.add_comment_outlined, p.text, 'Yangi suhbat',
              _loading ? null : () => setState(_messages.clear)),
          const SizedBox(width: 8),
          _iconBtn(Icons.key_rounded, _apiKey.isEmpty ? kErrorPink : p.text,
              'API kalit', _openSettings),
          const SizedBox(width: 8),
          _iconBtn(Icons.palette_outlined, p.text, 'Dizayn', _openDesign),
        ],
      ),
    );
  }

  Widget _welcome(AppSettings cfg, Pal p) {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Surface(
              width: 88,
              height: 88,
              radius: 44,
              filled: true,
              padding: EdgeInsets.zero,
              child: Icon(Icons.auto_awesome,
                  size: 40, color: onColor(cfg.accent)),
            ),
            const SizedBox(height: 24),
            Text(
              'Salom! Men Mr.Diyor AI.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: p.text,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1.2),
            ),
            const SizedBox(height: 8),
            Text(
              "Fikr, kod, matn, rasm yoki ovoz — birga ishlaymiz.",
              textAlign: TextAlign.center,
              style: TextStyle(color: p.sub, fontSize: 15),
            ),
            const SizedBox(height: 26),
            Wrap(
              spacing: 12,
              runSpacing: 14,
              alignment: WrapAlignment.center,
              children: [
                for (final s in _suggestions)
                  Pressable(
                    onTap: () => _send(s),
                    builder: (pressed) => Surface(
                      radius: 18,
                      pressed: pressed,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: Text(s,
                            style: TextStyle(color: p.text, fontSize: 14)),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(AppSettings cfg) {
    return ListView.builder(
      controller: _scroll,
      itemCount: _messages.length + (_loading ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == _messages.length) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Surface(
                radius: 22,
                padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TypingDots(color: cfg.accent),
                    if (_generating) ...[
                      const SizedBox(width: 12),
                      Text(_genStatus,
                          style: TextStyle(
                              color: Pal.of(cfg.style, cfg.dark).sub,
                              fontSize: 13)),
                    ],
                  ],
                ),
              ),
            ),
          );
        }
        final m = _messages[i];
        return _Bubble(
          msg: m,
          onRegenerate: (m.gen != null && !_loading)
              ? () => _regenerate(m.gen!.request)
              : null,
        );
      },
    );
  }

  Widget _inputBar(AppSettings cfg, Pal p) {
    Widget roundBtn({
      required Widget icon,
      required VoidCallback? onTap,
      Color? color,
    }) =>
        Pressable(
          onTap: onTap,
          builder: (pressed) => Surface(
            width: 42,
            height: 42,
            radius: 21,
            pressed: pressed,
            color: color,
            padding: EdgeInsets.zero,
            child: icon,
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_pendingImage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10, left: 6),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.memory(_pendingImage!,
                      width: 84, height: 84, fit: BoxFit.cover),
                ),
                Positioned(
                  top: -8,
                  right: -8,
                  child: GestureDetector(
                    onTap: () => setState(() => _pendingImage = null),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: kErrorPink),
                      child:
                      const Icon(Icons.close, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Surface(
          radius: 28,
          sunken: true,
          padding: const EdgeInsets.all(6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: roundBtn(
                  icon: Icon(Icons.add_rounded, color: p.text),
                  onTap: (_loading || _recording) ? null : _openAttach,
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Tooltip(
                  message: _imageMode
                      ? 'Rasm rejimi yoqilgan'
                      : 'Rasm yaratish rejimi',
                  child: roundBtn(
                    color: _imageMode ? cfg.accent : null,
                    icon: Icon(Icons.brush_rounded,
                        color: _imageMode ? onColor(cfg.accent) : p.text),
                    onTap: (_loading || _recording)
                        ? null
                        : () => setState(() => _imageMode = !_imageMode),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 5,
                  cursorColor: cfg.accent,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: TextStyle(color: p.text, fontSize: cfg.fontSize),
                  decoration: InputDecoration(
                    hintText: _recording
                        ? "Tinglayapman… (to'xtatish uchun bosing)"
                        : _transcribing
                        ? 'Ovoz matnga aylantirilmoqda…'
                        : _imageMode
                        ? "Qanday rasm yaratay? Tasvirlab bering…"
                        : 'Xabar yozing…',
                    hintStyle: TextStyle(color: p.sub),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: roundBtn(
                  color: _recording ? kErrorPink : null,
                  onTap: (_loading || _transcribing) ? null : _toggleRecord,
                  icon: _transcribing
                      ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: p.text))
                      : Icon(
                      _recording
                          ? Icons.stop_rounded
                          : Icons.mic_none_rounded,
                      color: _recording ? Colors.white : p.text),
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Pressable(
                  onTap: (_loading || _recording) ? null : () => _send(),
                  builder: (pressed) => Surface(
                    width: 46,
                    height: 46,
                    radius: 23,
                    filled: true,
                    pressed: pressed,
                    padding: EdgeInsets.zero,
                    child: _loading
                        ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: onColor(cfg.accent)))
                        : Icon(Icons.arrow_upward_rounded,
                        color: onColor(cfg.accent)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── Xabar pufagi ─────────────────────────
class _Bubble extends StatelessWidget {
  final Msg msg;
  final VoidCallback? onRegenerate;
  const _Bubble({required this.msg, this.onRegenerate});

  @override
  Widget build(BuildContext context) {
    final cfg = SettingsScope.of(context);
    final p = Pal.of(cfg.style, cfg.dark);
    final isUser = msg.role == 'user';
    final isErr = msg.isError;

    final Color textColor = isErr
        ? onColor(kErrorPink)
        : isUser
        ? onColor(cfg.accent)
        : p.text;
    final w = MediaQuery.of(context).size.width * 0.82;
    final bubbleW = w > 640 ? 640.0 : w;
    final imgW = math.min(bubbleW - 32, 380.0);

    Widget chip(IconData ic, String label, VoidCallback? onTap) => Pressable(
      onTap: onTap,
      builder: (pr) => Surface(
        radius: 14,
        pressed: pr,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ic, size: 16, color: p.text),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: p.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child:
        Transform.translate(offset: Offset(0, (1 - v) * 14), child: child),
      ),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: w > 640 ? 640 : w),
            child: Surface(
              radius: 22,
              filled: isUser && !isErr,
              color: isErr ? kErrorPink : null,
              padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (msg.image != null)
                    Padding(
                      padding:
                      EdgeInsets.only(bottom: msg.text.isNotEmpty ? 8 : 0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.memory(msg.image!,
                            width: 220, fit: BoxFit.cover),
                      ),
                    ),
                  if (msg.text.isNotEmpty)
                    SelectableText(
                      msg.text,
                      style: TextStyle(
                        color: textColor,
                        fontSize: cfg.fontSize,
                        height: 1.5,
                        fontWeight: cfg.style == DesignStyle.maximal
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  if (msg.gen != null) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () => _showImageViewer(context, msg.gen!),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: imgW,
                          child: AspectRatio(
                            aspectRatio: msg.gen!.width / msg.gen!.height,
                            child: Image.memory(msg.gen!.bytes,
                                fit: BoxFit.cover),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (onRegenerate != null)
                          chip(Icons.refresh_rounded, 'Qayta yaratish',
                              onRegenerate),
                        chip(Icons.copy_rounded, 'Promptni nusxalash', () {
                          Clipboard.setData(
                              ClipboardData(text: msg.gen!.prompt));
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Prompt nusxalandi')));
                        }),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _showImageViewer(BuildContext context, GenImage g) {
  showDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(12),
      child: Stack(
        children: [
          InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.memory(g.bytes, fit: BoxFit.contain),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: Color(0xFF7C5CFF)),
                child: const Icon(Icons.close, size: 20, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class TypingDots extends StatefulWidget {
  const TypingDots({super.key, required this.color});
  final Color color;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final t = (_c.value + i * .18) % 1.0;
          final y = -6 * math.sin(t * math.pi);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Transform.translate(
              offset: Offset(0, y),
              child: Container(
                width: 9,
                height: 9,
                decoration:
                BoxDecoration(color: widget.color, shape: BoxShape.circle),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ───────────────────────── Dizayn sozlamalari oynasi ─────────────────────────
class DesignSheet extends StatelessWidget {
  const DesignSheet({super.key, required this.onClear});
  final VoidCallback onClear;

  Widget _section(String t, Pal p) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 10),
    child: Text(t,
        style: TextStyle(
            color: p.text, fontSize: 16, fontWeight: FontWeight.w800)),
  );

  @override
  Widget build(BuildContext context) {
    final cfg = SettingsScope.of(context);
    final p = Pal.of(cfg.style, cfg.dark);
    final mq = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + mq.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * .88),
        child: Surface(
          radius: 32,
          padding: EdgeInsets.zero,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Dizayn',
                          style: TextStyle(
                              color: p.text,
                              fontSize: 22,
                              fontWeight: FontWeight.w900)),
                    ),
                    Pressable(
                      onTap: () => Navigator.of(context).pop(),
                      builder: (pressed) => Surface(
                        width: 40,
                        height: 40,
                        radius: 20,
                        pressed: pressed,
                        padding: EdgeInsets.zero,
                        child: Icon(Icons.close, color: p.text, size: 20),
                      ),
                    ),
                  ],
                ),
                _section('Uslub', p),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 18),
                  child: Row(
                    children: [
                      for (final s in DesignStyle.values) _styleCard(s, cfg),
                    ],
                  ),
                ),
                _section('Rejim', p),
                Row(
                  children: [
                    Expanded(
                        child: _modeChip("☀️  Yorug'", !cfg.dark, p, cfg,
                                () => cfg.change(() => cfg.dark = false))),
                    const SizedBox(width: 14),
                    Expanded(
                        child: _modeChip("🌙  Qorong'i", cfg.dark, p, cfg,
                                () => cfg.change(() => cfg.dark = true))),
                  ],
                ),
                _section('Asosiy rang', p),
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    for (int i = 0; i < kSwatches.length; i++)
                      Pressable(
                        onTap: () => cfg.change(() => cfg.accentIndex = i),
                        builder: (pressed) => Surface(
                          width: 44,
                          height: 44,
                          radius: 22,
                          color: kSwatches[i],
                          pressed: pressed,
                          padding: EdgeInsets.zero,
                          child: cfg.accentIndex == i
                              ? Icon(Icons.check,
                              color: onColor(kSwatches[i]), size: 22)
                              : const SizedBox.shrink(),
                        ),
                      ),
                  ],
                ),
                _section("Matn o'lchami: ${cfg.fontSize.round()}", p),
                Slider(
                  value: cfg.fontSize,
                  min: 13,
                  max: 22,
                  divisions: 9,
                  activeColor: cfg.accent,
                  onChanged: (v) => cfg.change(() => cfg.fontSize = v),
                ),
                const SizedBox(height: 18),
                Pressable(
                  onTap: () {
                    onClear();
                    Navigator.of(context).pop();
                  },
                  builder: (pressed) => Surface(
                    radius: 18,
                    pressed: pressed,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.delete_outline, color: p.text, size: 20),
                        const SizedBox(width: 8),
                        Text('Suhbatni tozalash',
                            style: TextStyle(
                                color: p.text, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeChip(
      String label, bool selected, Pal p, AppSettings cfg, VoidCallback onTap) {
    return Pressable(
      onTap: onTap,
      builder: (pressed) => Surface(
        radius: 18,
        filled: selected,
        pressed: pressed,
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text(label,
              style: TextStyle(
                  color: selected ? onColor(cfg.accent) : p.text,
                  fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _styleCard(DesignStyle s, AppSettings cfg) {
    final ps = Pal.of(s, cfg.dark);
    final selected = cfg.style == s;
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Pressable(
        onTap: () => cfg.change(() => cfg.style = s),
        builder: (pressed) => SizedBox(
          width: 132,
          child: Stack(
            children: [
              Surface(
                styleOverride: s,
                radius: 22,
                pressed: pressed,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.emoji, style: const TextStyle(fontSize: 28)),
                    const SizedBox(height: 10),
                    Text(s.title,
                        style: TextStyle(
                            color: ps.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(s.subtitle,
                        style: TextStyle(color: ps.sub, fontSize: 11)),
                    const SizedBox(height: 12),
                    Surface(
                      styleOverride: s,
                      filled: true,
                      radius: 9,
                      width: 56,
                      height: 18,
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              if (selected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    decoration:
                    BoxDecoration(shape: BoxShape.circle, color: cfg.accent),
                    padding: const EdgeInsets.all(3),
                    child:
                    Icon(Icons.check, size: 14, color: onColor(cfg.accent)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}