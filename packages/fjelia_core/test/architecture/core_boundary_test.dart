import 'dart:io';

import 'package:test/test.dart';

/// fjelia_core runs on the Dart SDK alone: no Flutter, no plugins, no app
/// code. Platform work reaches it through interfaces the apps implement.
const _allowedPackages = {
  'fjelia_core',
  'fjelia_service_api',
  'collection',
  'crypto',
  'fit_sdk',
  'intl',
  'meta',
  'xml',
};

const _forbiddenDartLibraries = {
  'dart:ui',
  'dart:io',
  'dart:ffi',
  'dart:html',
  'dart:isolate',
};

void main() {
  test('lib imports only the Dart SDK and allowed pure-Dart packages', () {
    final directive = RegExp(r"^(?:import|export)\s+'([^']+)'", multiLine: true);
    final violations = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      for (final match in directive.allMatches(file.readAsStringSync())) {
        final uri = match.group(1)!;
        if (uri.startsWith('dart:')) {
          if (_forbiddenDartLibraries.contains(uri)) {
            violations.add('${file.path}: $uri');
          }
        } else if (uri.startsWith('package:')) {
          final package = uri.substring(8).split('/').first;
          if (!_allowedPackages.contains(package)) {
            violations.add('${file.path}: $uri');
          }
        }
      }
    }
    expect(violations, isEmpty);
  });
}
