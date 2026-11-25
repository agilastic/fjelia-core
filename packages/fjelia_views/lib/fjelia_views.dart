/// What each Fjelia screen shows and when, shared by the mobile and desktop
/// apps: read from the database (`fjelia_data`) and worked out with
/// `fjelia_core`. The apps decide only how and where to render it, and
/// put it into words.
library;

export 'src/activities.dart';
export 'src/analysis.dart';
export 'src/calendar.dart';
export 'src/diary.dart';
export 'src/health.dart';
export 'src/sport_stats.dart';
export 'src/today.dart';
export 'src/training_load.dart';
