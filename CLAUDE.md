# Dismessage

Messagerie « contextuelle » : on voit l'interlocuteur écrire **en direct**, caractère par caractère, de façon fluide.
Quand il fait une pause, trois points animés `…` s'affichent **à la fin du texte déjà tapé**.
Chaque installation a un **ID à 9 chiffres** (style AnyDesk, ex. `482 913 075`) qui ne change que si l'utilisateur en génère un nouveau.

## Architecture

| Dossier | Rôle | Techno |
| --- | --- | --- |
| `packages/protocol/` | Trames du protocole, IDs, algorithme de diff, état du brouillon reçu | Dart pur (aucune dépendance Flutter) |
| `server/` | Relais WebSocket : enregistrement des IDs, mise en relation, relais des trames | Dart (`shelf`, `shelf_web_socket`) |
| `app/` | Client (Android, Web, Windows) | Flutter, Material 3 |

**Règle d'or : toute logique qui n'est pas de l'affichage va dans `packages/protocol`**, où elle est testable sans Flutter.

- Les messages sont **éphémères** : rien n'est stocké, ni côté serveur ni côté client.
- Les **contacts** (`ContactsService`) sont stockés **uniquement sur l'appareil** (clé `dismessage.contacts`). Ils ne contiennent qu'un ID et un nom, jamais de message.
- Le serveur ne persiste que `ID → sha256(secret)` dans `server/data/ids.json`, pour empêcher le vol d'un ID.
- Transport : JSON sur WebSocket (`ws://` en dev, `wss://` en prod). Le chiffrement de bout en bout est prévu plus tard.

## Commandes

Toutes les commandes passent par le SDK fourni avec Flutter (`C:\dev\flutter`). Privilégier `--offline` pour `pub get` : le cache local contient les paquets et la bande passante est limitée.

```sh
# Dépendances
cd packages/protocol && dart pub get --offline
cd server && dart pub get --offline
cd app && flutter pub get --offline

# Tests
cd packages/protocol && dart test
cd server && dart test
cd app && flutter test

# Analyse statique
dart analyze packages/protocol server
cd app && flutter analyze

# Lancer
cd server && dart run bin/server.dart            # PORT=8080 par défaut
cd app && flutter run -d chrome                   # web
cd app && flutter run -d windows                  # Windows
cd app && flutter run -d <android> --dart-define=SERVER_URL=ws://10.0.2.2:8080
```

## Accès depuis internet (tunnel VS Code)

Le serveur sert à la fois le relais (`/ws`) et le client web (`app/build/web`, variable `DISMESSAGE_WEB`). Un seul lien public suffit donc.

1. Double-cliquer sur `start-server.bat` (à la racine). Il compile le client web s'il manque (`--rebuild` pour forcer), puis démarre le serveur sur le port 8080 (`start-server.bat 9000` pour un autre port).
2. VS Code, onglet **Ports** : transférer le port `8080` et passer sa **visibilité en Public**. En privé, les clients extérieurs sont redirigés vers une connexion GitHub.
3. Navigateur : ouvrir le lien `https://xxxx-8080.<région>.devtunnels.ms`. La page parle à son propre serveur (`ServerAddress.sameOrigin`).
4. Windows et Android : bouton **Serveur** de l'accueil, puis coller le même lien. Il est converti en `wss://…/ws` (`ServerAddress.parse`) et mémorisé.
   Ou bien, à la compilation : `--dart-define=SERVER_URL=https://xxxx-8080…`.

Le tunnel est lent (10 à 20 Ko/s mesurés) : le serveur compresse les fichiers statiques en gzip (`gzip_middleware.dart`), et `web/index.html` affiche un écran de chargement jusqu'au premier rendu Flutter (`web/flutter_bootstrap.js`). Il faut compter environ 1 minute au premier chargement, puis le cache du navigateur prend le relais.

Le tunnel tourne sur ta machine : si le PC s'éteint ou si VS Code est fermé, plus personne ne peut se connecter.

## Protocole

Enveloppe : `{"t": "<type>", ...champs}`. Les trames de session portent `sid`.

| Type | Sens | Champs |
| --- | --- | --- |
| `register` | C→S | `id`, `secret` |
| `registered` | S→C | `id` |
| `id_taken` | S→C | `id` |
| `release` | C→S | `id`, `secret` |
| `connect_request` | C→S | `to` |
| `incoming_request` | S→C | `from` |
| `connect_accept` | C→S | `from` |
| `connect_reject` | C→S / S→C | `peer` |
| `connect_cancel` | C→S / S→C | `peer` |
| `session_started` | S→C | `sid`, `peer` |
| `peer_offline` | S→C | `peer` |
| `peer_left` | S→C | `sid` |
| `session_leave` | C→S | `sid` |
| `draft_ops` | C→S→C | `sid`, `seq`, `ops[{pos,del,ins}]` |
| `draft_snapshot` | C→S→C | `sid`, `seq`, `text` |
| `draft_resync` | C→S→C | `sid` |
| `draft_clear` | C→S→C | `sid`, `seq` |
| `message_commit` | C→S→C | `sid`, `seq`, `text` |
| `error` | S→C | `code`, `message` |
| `ping` / `pong` | C↔S | — |

## Règles

- **Toute modification du protocole** met à jour, dans le même changement : `packages/protocol/lib/src/frames.dart`, le tableau ci-dessus et les tests d'aller-retour JSON (`frames_test.dart`).
- Une trame invalide ne doit **jamais** faire planter le serveur : elle est rejetée par une trame `error`.
- Le **secret** d'un ID ne transite que dans `register` / `release`. Il n'est jamais loggé, et le serveur ne stocke que son hash. Le journal du serveur (`Relay(log: …)`) affiche les connexions, les IDs et les demandes, et un test vérifie qu'aucun secret n'y apparaît.
- **Connexion :** ouverture du WebSocket puis confirmation `registered`, chacune limitée à `kConnectTimeoutSeconds`. Les tentatives sont réessayées avec un délai exponentiel (plafond `kMaxReconnectDelaySeconds`). L'accueil affiche la cause de l'échec (`ConnectionService.lastError`), ne jamais la masquer.
- Ne jamais écrire une chaîne Dart contenant `\n` ou une apostrophe via un script Python ou `sed` : l'échappement casse le code. Utiliser l'outil d'édition.
- `TextDiff.compute` doit rester en **O(n)** (préfixe et suffixe communs), sans couper une paire UTF-16 (emoji). L'invariant `apply(old, compute(old, new)) == new` est couvert par un test aléatoire, qu'on ne supprime pas.
- Les **constantes UX** vivent dans `packages/protocol/lib/src/constants.dart` (`kDraftBatchMs`, `kPauseDotsMs`, `kSnapshotEvery`, …). Ne jamais les dupliquer en dur ailleurs.
- **Cibles : Android, Web et Windows.** Windows exige le **mode développeur Windows** (liens symboliques pour les plugins) et Visual Studio Build Tools C++. Pas de dépendance native lourde.
- Après un `flutter create`, supprimer le `app/test/widget_test.dart` régénéré (il référence un `MyApp` inexistant).
- Le code, les identifiants et les commentaires sont en **anglais**. L'interface et la documentation sont en **français**.
- Avant de déclarer une tâche terminée : analyse statique sans erreur et tous les tests verts dans les trois paquets.
- Tout nouveau comportement arrive avec ses tests : unitaires dans `protocol`, d'intégration WebSocket dans `server`, de widgets dans `app`.

## Tests

| Fichier | Couvre |
| --- | --- |
| `packages/protocol/test/*` | IDs, diff (dont le test aléatoire de 1 000 paires), émetteur et récepteur de brouillon, trames JSON |
| `server/test/relay_test.dart` | Vrai serveur sur port éphémère : enregistrement, vol d'ID, release, mise en relation, relais isolé par session, robustesse |
| `app/test/live_draft_bubble_test.dart` | Points absents pendant la frappe, présents après `kPauseDotsMs` et collés au texte, déroulé progressif, fondu, emoji |
| `app/test/home_screen_test.dart` | Affichage de l'ID, validation de l'ID saisi, régénération avec confirmation |
| `app/test/end_to_end_test.dart` | Deux `ConnectionService` réels + vrai relais : frappe en direct, envoi, départ, ID stable, régénération, annulation |
| `app/test/home_requests_test.dart` | Faux serveur scripté (`test/fakes.dart`) : attente, annulation, refus, expiration, boîte entrante, contacts |
| `app/test/connection_diagnostics_test.dart` | Délais de connexion, nouvelles tentatives, bandeau d'erreur, bouton « Réessayer » |
| `app/test/contacts_service_test.dart`, `chat_screen_test.dart` | Carnet de contacts (persistance, validation) et enregistrement depuis le chat |

- Le test de bout en bout utilise `test()` et non `testWidgets()` : sans binding de widgets, les vraies sockets et les vrais timers fonctionnent.
- Pour simuler plusieurs clients dans un même process, on injecte `MemoryStore` dans `IdentityService` (`SharedPreferences` est un singleton).
- `TypingDots` tourne en boucle : dans un test de widgets, utiliser `pump(durée)`, jamais `pumpAndSettle()` quand les points sont affichés.
