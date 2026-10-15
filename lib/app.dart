import 'package:flutter/material.dart';
import 'package:ssh_app/screens/server_list_screen.dart';
import 'package:ssh_app/theme/app_theme.dart';

class SshApp extends StatelessWidget {
  const SshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSH',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const ServerListScreen(),
    );
  }
}
