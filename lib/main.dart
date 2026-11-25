import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'services/history_store.dart';
import 'ui/screens/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: HD.bg,
  ));
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // Loads history and cleans up anything left by an interrupted export.
  await HistoryStore.instance.init();
  runApp(const HDCleanApp());
}

class HDCleanApp extends StatelessWidget {
  const HDCleanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HD CLEAN',
      debugShowCheckedModeBanner: false,
      theme: HD.theme(),
      home: const HomeScreen(),
    );
  }
}
