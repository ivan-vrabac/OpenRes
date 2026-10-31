import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../branding.dart';
import '../services/api_service.dart';
import '../services/fcm_service.dart';
import '../services/google_auth.dart';
import '../services/storage_service.dart';
import '../models/player_provider.dart';
import 'game_screen.dart';

import '../app_colors.dart';
import '../widgets/top_banner.dart';
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _ctrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  int _titleTaps = 0;
  bool _form = false;                        // the log in form instead of the Google button
  bool _loading = false;
  bool _showPw = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  static final _validName = RegExp(r'^[a-zA-Z0-9 .,\[\]()\-]+$');

  Future<void> _submit() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter your company name');
      return;
    }
    if (name.length > 20) {
      setState(() => _error = 'Name must be 20 characters or less');
      return;
    }
    if (!_validName.hasMatch(name)) {
      setState(() => _error = 'Only letters, digits, spaces and . , [ ] ( ) - allowed');
      return;
    }
    final password = _pwCtrl.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter a password');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final res = await ApiService.signIn(name, password);
      if (res.error != null) {
        setState(() {
          _error = res.error;
          _loading = false;
        });
        return;
      }

      await _enter(res.hid!, res.sid!, deletionCancelled: res.deletionCancelled);
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _loading = false;
      });
    }
  }

  /// Signed in (password or Google): remember the session and open the game.
  Future<void> _enter(String hid, String sid, {bool deletionCancelled = false}) async {
    await StorageService.saveSession(hid, sid);
    final player = await ApiService.getPlayerData(sid);
    if (!mounted) return;
    if (player != null) {
      context.read<PlayerProvider>().setPlayer(player, sid: sid);
      FcmService.init(context.read<PlayerProvider>().sid);
    }
    if (deletionCancelled) {
      AppNotify.show(context, 'Welcome back! The deletion of your company was cancelled.');
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const GameScreen()));
  }

  /// Sign in with Google (owner 2026-10-25: the only way). A Google account we don't know yet
  /// names a new company, or links an existing one once with its old name and password.
  Future<void> _google() async {
    setState(() { _loading = true; _error = null; });
    try {
      // left Google's account picker for another app, its answer never comes
      final token = await GoogleAuth.idToken(pick: true).timeout(const Duration(minutes: 2));
      if (token == null) {
        setState(() => _loading = false);
        return;
      }
      var r = await GoogleAuth.signIn(token);
      while (r.code == 'need_name' || r.code == 'name_taken' || r.code == 'invalid_name' ||
          r.code == 'wrong_password' || r.code == 'already_linked' || r.code == 'rate_limited') {
        if (!mounted) return;
        final note = r.code == 'need_name' ? null : r.message;
        final choice = await _newOrLink(note);
        if (choice == null) {
          setState(() => _loading = false);
          return;
        }
        r = choice.link
            ? await GoogleAuth.signIn(token, linkName: choice.name, linkPassword: choice.password)
            : await GoogleAuth.signIn(token, name: choice.name);
      }
      if (!r.ok) {
        setState(() { _error = r.message; _loading = false; });
        return;
      }
      if (r.data['created'] == true && mounted) AppNotify.show(context, 'Welcome, ${r.data['name']}!');
      await _enter(r.data['hID'] as String, r.data['sid'] as String);
    } on TimeoutException {
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      setState(() { _error = GoogleAuth.errorText(e); _loading = false; });
    }
  }

  /// New Google account: a new company (name), or an existing one (name + its old password).
  Future<({bool link, String name, String? password})?> _newOrLink(String? note) async {
    final name = TextEditingController(), pw = TextEditingController();
    var link = false;
    return showDialog<({bool link, String name, String? password})>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text(link ? 'Your company' : 'Name your company'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('New company')),
              ButtonSegment(value: true, label: Text('I have one')),
            ],
            selected: {link},
            onSelectionChanged: (v) => setD(() => link = v.first),
          ),
          const SizedBox(height: 12),
          Text(link
              ? 'Played before with a password? Enter your company name and password once. From then on '
                'you sign in with Google and the password is no longer used.'
              : '3-20 letters, digits, spaces and . , [ ] ( ) -',
              style: TextStyle(fontSize: 12, color: AppColors.t54)),
          const SizedBox(height: 8),
          TextField(controller: name, maxLength: 20, autofocus: true,
              decoration: const InputDecoration(labelText: 'Company name', border: OutlineInputBorder(), counterText: '')),
          if (link) ...[
            const SizedBox(height: 8),
            TextField(controller: pw, obscureText: true,
                decoration: const InputDecoration(labelText: 'Old password', border: OutlineInputBorder())),
          ],
          if (note != null) ...[
            const SizedBox(height: 8),
            Text(note, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ],
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final n = name.text.trim();
              if (n.isEmpty || !_validName.hasMatch(n)) return;
              Navigator.pop(ctx, (link: link, name: n, password: link ? pw.text : null));
            },
            child: Text(link ? 'Link' : 'Create'),
          ),
        ],
      )),
    );
  }

  Widget _googleOnly() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Sign in with your Google account to play. New here? You choose a company name next.',
            style: TextStyle(color: AppColors.t54, fontSize: 13), textAlign: TextAlign.center),
        const SizedBox(height: 24),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
          const SizedBox(height: 8),
        ],
        FilledButton.icon(
          onPressed: _loading ? null : _google,
          icon: _loading
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.account_circle),
          label: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Sign in with Google')),
        ),
      ]);

  Widget _passwordField(TextEditingController c) =>
      TextField(
        controller: c,
        obscureText: !_showPw,
        textInputAction: TextInputAction.go,
        autofillHints: const [AutofillHints.password],
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'Password',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showPw = !_showPw),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (Branding.logoAsset.isNotEmpty) ...[
                    Image.asset(Branding.logoAsset, height: 96),
                    const SizedBox(height: 16),
                  ],
                  // tapping the title 5 times opens the log in form (the Google Play review account; old
                  // companies not switched to Google yet), 5 more go back to Google
                  GestureDetector(
                    onTap: () => setState(() {
                      if (++_titleTaps < 5) return;
                      _titleTaps = 0;
                      _form = !_form;
                      _error = null;
                      _loading = false;
                    }),
                    child: Text(
                      Branding.appTitle,
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (GoogleAuth.enabled && !_form) _googleOnly() else ...[
                  TextField(
                    controller: _ctrl,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    maxLength: 20,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(
                      labelText: 'Company name',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _passwordField(_pwCtrl),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Text(_error!,
                        style: const TextStyle(color: Colors.redAccent),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                  ],
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Log in'),
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
