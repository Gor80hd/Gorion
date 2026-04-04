import 'package:flutter/material.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/features/home/widget/home_page.dart';

class GorionApp extends StatelessWidget {
  const GorionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gorion',
      debugShowCheckedModeBanner: false,
      theme: buildGorionTheme(),
      home: const Scaffold(
        backgroundColor: Color(0xFF0C1210),
        body: HomePage(),
      ),
    );
  }
}