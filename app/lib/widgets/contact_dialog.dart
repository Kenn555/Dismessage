import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';

import '../services/contacts_service.dart';

/// Result of [showContactDialog].
typedef ContactDraft = ({String id, String name});

/// Asks for a contact name, and for the ID when [id] is not given.
Future<ContactDraft?> showContactDialog(
  BuildContext context, {
  String? id,
  String? name,
}) => showDialog<ContactDraft>(
  context: context,
  builder: (_) => _ContactDialog(fixedId: id, initialName: name),
);

class _ContactDialog extends StatefulWidget {
  const _ContactDialog({this.fixedId, this.initialName});

  final String? fixedId;
  final String? initialName;

  @override
  State<_ContactDialog> createState() => _ContactDialogState();
}

class _ContactDialogState extends State<_ContactDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  final _id = TextEditingController();
  String? _nameError;
  String? _idError;

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    super.dispose();
  }

  void _submit() {
    final name = ContactsService.cleanName(_name.text);
    final id = widget.fixedId ?? DismessageId.parse(_id.text);
    setState(() {
      _nameError = name == null ? 'Nom requis' : null;
      _idError = id == null ? 'ID invalide (9 chiffres)' : null;
    });
    if (name == null || id == null) return;
    Navigator.pop<ContactDraft>(context, (id: id, name: name));
  }

  @override
  Widget build(BuildContext context) {
    final fixedId = widget.fixedId;
    return AlertDialog(
      title: Text(
        widget.initialName == null ? 'Enregistrer le contact' : 'Renommer',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('contact-name'),
            controller: _name,
            autofocus: true,
            maxLength: ContactsService.maxNameLength,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Nom',
              errorText: _nameError,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (fixedId == null)
            TextField(
              key: const Key('contact-id'),
              controller: _id,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'ID',
                hintText: '123 456 789',
                errorText: _idError,
              ),
              onSubmitted: (_) => _submit(),
            )
          else
            Text('ID : ${DismessageId.format(fixedId)}'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          key: const Key('contact-save'),
          onPressed: _submit,
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
