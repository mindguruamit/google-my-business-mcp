import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'overlay/overlay_main.dart';
import 'screens/library_screen.dart';
import 'services/script_repository.dart';
import 'state/library_cubit.dart';
import 'utils/app_theme.dart';
import 'utils/constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  final repository = await ScriptRepository.open();
  await repository.seedIfEmpty();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(MindGuruPrompterApp(repository: repository));
}

/// Entry point for the Android floating window (flutter_overlay_window looks
/// this name up in the main library).
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FloatingPrompterApp());
}

class MindGuruPrompterApp extends StatelessWidget {
  const MindGuruPrompterApp({super.key, required this.repository});

  final ScriptRepository repository;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => LibraryCubit(repository),
      child: MaterialApp(
        title: 'MindGuru Prompter',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: const LibraryScreen(),
      ),
    );
  }
}
