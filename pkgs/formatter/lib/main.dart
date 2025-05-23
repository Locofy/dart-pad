import 'package:dart_style/dart_style.dart';
import 'package:js/js.dart' as js_package;
import 'dart:js_util' as dart_js_util;

class DartFormatterInterop {
  String format(String code) {
    final formatter = DartFormatter(
      languageVersion: DartFormatter.latestShortStyleLanguageVersion,
    );
    return formatter.format(code);
  }
}

void main() {
  final interop = DartFormatterInterop();

  dart_js_util.setProperty(
      dart_js_util.globalThis,
      'dartFormatter',
      dart_js_util.jsify({
        'format': js_package.allowInterop(interop.format),
      }));
}
