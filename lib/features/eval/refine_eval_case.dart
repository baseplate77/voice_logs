import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// One row from `assets/eval/refine_eval_cases.json`. Plain Dart so the
/// debug-only eval screen does not pull in freezed/json_serializable
/// codegen.
class RefineEvalCase {
  const RefineEvalCase({
    required this.id,
    required this.rawTranscript,
    required this.expectedCleanedText,
    required this.expectedEntities,
    required this.expectedReminders,
    required this.phenomena,
  });

  final String id;
  final String rawTranscript;
  final String expectedCleanedText;
  final List<RefineEvalEntity> expectedEntities;
  final List<String> expectedReminders;
  final List<String> phenomena;

  factory RefineEvalCase.fromJson(Map<String, Object?> json) {
    return RefineEvalCase(
      id: json['id']! as String,
      rawTranscript: json['rawTranscript']! as String,
      expectedCleanedText: json['expectedCleanedText']! as String,
      expectedEntities: (json['expectedEntities']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map(RefineEvalEntity.fromJson)
          .toList(),
      expectedReminders: (json['expectedReminders']! as List<Object?>)
          .cast<String>()
          .toList(),
      phenomena: (json['phenomena']! as List<Object?>).cast<String>().toList(),
    );
  }
}

class RefineEvalEntity {
  const RefineEvalEntity({required this.text, required this.type});

  final String text;
  final String type;

  factory RefineEvalEntity.fromJson(Map<String, Object?> json) {
    return RefineEvalEntity(
      text: json['text']! as String,
      type: json['type']! as String,
    );
  }
}

/// Loads the bundled fixture. Errors propagate; callers wrap in try/catch
/// since this is a debug surface.
Future<List<RefineEvalCase>> loadRefineEvalCases() async {
  final raw = await rootBundle.loadString('assets/eval/refine_eval_cases.json');
  final decoded = jsonDecode(raw) as List<Object?>;
  return decoded
      .cast<Map<String, Object?>>()
      .map(RefineEvalCase.fromJson)
      .toList();
}
