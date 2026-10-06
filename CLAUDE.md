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
- **Images :** seule une miniature déjà floutée part à l'envoi (`image_offer`). L'image nette n'est transférée (`image_data`) que quand le destinataire appuie pour l'ouvrir (`image_request`), et l'expéditeur voit alors « Ouverte ». `ImageCodec` réduit l'image à `kMaxImageSide`, la recompresse sous `kMaxImageBytes` et **supprime l'EXIF** (dont la position GPS). Les images ne vivent qu'en mémoire, comme les messages. Un client n'accepte un `image_data` que pour une image qu'il a demandée.
- **Émojis :** panneau intégré (`EmojiPanel`), sans paquet externe. L'émoji est inséré au curseur puis diffusé en direct comme une frappe.
- **Bulles :** chaque bulle (texte, image, vocal) porte un `EntryId` (16 hex aléatoires), commun aux deux pairs. Il sert aux **réponses** (champ `reply`, glisser la bulle vers la droite ou appui long → « Répondre ») et aux **réactions** (une seule par bulle, uniquement sur les bulles de l'interlocuteur ; renvoyer le même émoji la retire). Une référence vers une bulle inconnue est ignorée.
- **IDs masqués :** mon ID et ceux des contacts enregistrés s'affichent `482 *** 075` (`DismessageId.mask`), avec un bouton œil pour les dévoiler (`IdPrivacy`, non mémorisé : masqué à chaque lancement). « Copier » copie l'ID complet. L'ID d'un inconnu reste complet, pour savoir qui c'est.
- **Accueil sur grand écran :** à partir de `kWideLayoutWidth` (`app_theme.dart`, 840 px de large, donc PC et tablette en paysage, quelle que soit la plateforme), deux colonnes qui défilent chacune de leur côté : « Conversations en cours », mon ID et « Nouvelle conversation » à gauche, les contacts à droite. En dessous, une seule colonne.
- **Multisession :** plusieurs conversations ouvertes à la fois (le relais l'a toujours permis, aucune trame en plus). `ConnectionService.sessions` (ordre d'ouverture), `active` (celle à l'écran, `activate`), `liveSessionWith(peer)`, `closeSession`. Une nouvelle session ne termine pas les autres ; une session avec le même pair remplace l'ancienne à sa place. `ChatSession.unread` compte les bulles reçues hors affichage (`viewing`). Écran : `ChatsShell`, route unique poussée par l'accueil dès qu'une session devient active (nouvelle session, clic sur notification, conversation en cours, contact déjà en conversation au lieu d'une nouvelle demande) ; un `ChatScreen` par session dans un `IndexedStack` (saisie, défilement et réponse conservés). À partir de `kWideLayoutWidth` : sidebar (`SessionTile` : nom, présence, « écrit… », non-lus, ✕). En dessous, dès 2 conversations : avatars flottants centrés à gauche (`PresenceAvatar` + badge ; appui long = fermer). Retour ramène à l'accueil **sans fermer** ; on quitte par le bouton de l'en-tête, le ✕ ou le bandeau « Fermer ». Notifications système inchangées (appli cachée seulement), une par `sid`.
- **Défilement :** la frappe de l'interlocuteur est dans une zone **fixe** au-dessus de la saisie (hors de la liste, ≤ 35 % de la hauteur) : on peut remonter pendant qu'il écrit. La liste ne descend que pour une nouvelle bulle, si elle est de moi ou si j'étais déjà en bas ; sinon le bouton « ↓ » s'affiche avec un point.
- **Saisie :** multiligne. Clavier physique : Entrée envoie, Maj+Entrée ajoute une ligne. Clavier virtuel : Entrée ajoute une ligne, le bouton envoie. Le curseur revient **toujours** dans le champ après une action (émoji, photo envoyée ou annulée, vocal, réponse…) : `_refocus`, `TextFieldTapRegion` autour de la barre et du panneau, `ExcludeFocus` sur le panneau. Panneau d'émojis ouvert : `TextInputType.none` (curseur sans clavier virtuel).
- **Photo :** un seul bouton propose « Prendre une photo » et « Choisir dans la galerie » (`image_picker`). Sur Android et dans les navigateurs de téléphone, `image_picker` ouvre l'appareil photo du système. Sur PC, il ne sait pas piloter la webcam : `CameraCapture` (`camera_capture*.dart`) l'affiche dans `CameraScreen` (aperçu en direct + déclencheur), via `getUserMedia` sur le web (aperçu en miroir, photo à l'endroit) et via `camera_windows` dans l'appli Windows. `camera_windows` enregistre chaque photo dans le dossier Images : le fichier est supprimé aussitôt lu. Ne pas monter `camera_windows` au-delà de 0.2.6+4 sans Flutter ≥ 3.38. Le sélecteur réduit déjà l'image à `kMaxImageSide` (nativement, ou par le canvas du navigateur) : sur le web, `compute` tourne sur le fil de l'interface, et encoder une photo de 12 Mpx en Dart figeait la page ~10 s.
- **Vocaux :** bouton micro à la place d'« Envoyer » quand la saisie est vide. Enregistrement en AAC (`audio/mp4`), à défaut Opus (navigateurs), à défaut WAV 8 kHz ; la durée est plafonnée pour tenir dans `kMaxVoiceBytes`. Le fichier temporaire est supprimé aussitôt lu : le vocal ne vit qu'en mémoire. Lecture par `VoicePlayer`, un vocal à la fois.
  - **Android :** canal maison `dismessage/voice` (`android/app/src/main/kotlin/.../VoiceHandler.kt`, MediaRecorder + MediaPlayer). Ne **pas** ajouter `record` ni `audioplayers` (paquets « app-facing ») : `record_android` et `audioplayers_android` exigent AGP 7.3.1 / 8.12.3 et Kotlin 1.7.10 / 2.2.20, absents du cache Gradle. L'APK se construit hors ligne : `cd app/android && ./gradlew.bat assembleRelease --offline`.
  - **Web et Windows :** implémentations `record_web` / `record_windows` et `audioplayers_web` / `audioplayers_windows`, appelées via leurs interfaces (`PluginVoiceRecorder`, `PluginAudioBackend`). Sur un build Windows propre, `audioplayers_windows` télécharge `nuget.exe` et le paquet WIL (~10 Mo) dans `app/build/` : ne pas supprimer ce dossier sans raison. Le lecteur web met le type dans une URI `data:` : ne lui passer que le type de base (`baseMime`, sans `;codecs=…`), sinon le navigateur refuse de lire.
- **Présence :** l'accueil envoie la liste des contacts (`presence_watch`) ; le serveur répond puis prévient à chaque connexion ou déconnexion (`presence`). Point vert / gris sur l'avatar, rien tant que l'état est inconnu. Pour que « Hors ligne » soit fiable : le serveur envoie un `ping` WebSocket toutes les `kHeartbeatSeconds` et coupe un client muet (réseau perdu) ; le client web ferme sa connexion sur `pagehide` et la rouvre sur `pageshow` (`ConnectionService.suspend` / `resume`, `page_lifecycle.dart`), car Chrome peut garder la page figée, socket ouverte, dans son cache « précédent / suivant ».
- **Notifications :** seulement ce que l'utilisateur ne voit pas (appli non `resumed` : arrière-plan, réduite, autre fenêtre ou onglet devant). Une notification par conversation (étiquette = `sid`) : messages non lus (`kNotificationMaxLines`) puis la frappe en cours « ✍️ … ». Le début de la frappe est annoncé avec son, puis mis à jour **sans son**, au plus toutes les `kTypingNotificationMs` ; un message la remplace avec son ; revenir dans l'appli l'efface. Logique : `ChatNotifications` ; affichage : `SystemNotifier`. Les **demandes de conversation** sont notifiées aussi (étiquette `request-<ID>`, nom du contact ou ID complet d'un inconnu), avec les boutons « Accepter » (ramène l'appli) et « Refuser » sur Android et Windows ; elles disparaissent si la personne annule ou si on répond ailleurs (`IncomingRequestAnsweredEvent` ferme aussi la boîte de dialogue). La permission est demandée au démarrage.
  - **Réponse depuis la notification :** Android (champ de réponse intégré, `NotificationHandler.kt` + `ReplyReceiver`) et Windows (toast avec champ, `windows/runner/notifications.cpp`, C++/WinRT du SDK Windows), même canal `dismessage/notify`. `ChatSession.sendQuickReply` envoie le texte sans perdre le brouillon en cours (`DraftSender.commitText`, puis le brouillon est renvoyé). Le web n'a pas de champ de réponse : un clic ramène la conversation (`ChatNotifications.onOpen` → `activate`).
  - **Windows :** identité `Dismessage.Desktop` enregistrée par l'appli (`HKCU\Software\Classes\AppUserModelId`, sans droits admin) et posée sur les raccourcis par l'installateur. Le texte est lié (`{title}`, `{body}`) pour être mis à jour sur place sans réafficher le toast ; les clics arrivent sur un autre thread et repassent par la fenêtre (`WM_APP`).
  - **Limites :** l'appli doit tourner (pas de serveur de notifications push).
- **Arrière-plan Android :** option « Rester joignable en arrière-plan » (bouton Réglages de l'accueil, Android seulement, désactivée par défaut ; `BackgroundMode`, clé `dismessage.background`). Un service de premier plan (`BackgroundService.kt`, type `specialUse`, notification discrète « Dismessage est actif ») garde la connexion avec l'écran fermé, et `BootReceiver` le relance au démarrage du téléphone. Un **seul moteur Flutter** (`EngineHolder`) sert l'écran et le service : `MainActivity` s'y rattache (`provideFlutterEngine`, `shouldDestroyEngineWithHost = false`) ; les canaux `dismessage/voice`, `dismessage/notify` et `dismessage/background` sont créés une fois avec le contexte de l'application, l'activité ne sert qu'aux demandes de permission. Démarrée sans écran, l'appli se considère non visible (`main.dart`) et redemande la permission de notifier à l'ouverture. Certains fabricants (Xiaomi, Huawei…) tuent quand même les applis en arrière-plan : il faut alors autoriser Dismessage dans leurs réglages de batterie.
  - **Émulateur :** Flutter ne tourne pas sur une image Android x86 32 bits (`libflutter.so` est ARM / x86_64). L'image `android-30 x86` présente ne convient donc pas ; il faudrait une image x86_64 (téléchargement de plus d'1 Go).
  - **Pair de test :** `cd server && dart run tool/test_peer.dart ws://localhost:8099/ws` donne un second client piloté par HTTP (port 9555 : `/request?to=`, `/cancel`, `/draft?text=`, `/send?text=`, `/log`), pour essayer l'appli sur un vrai appareil.
- **Essai réel dans un navigateur :** Chrome sans interface piloté par le protocole DevTools (deux contextes isolés = deux utilisateurs, micro simulé par `--use-fake-device-for-media-stream`, sélecteur de fichiers intercepté), contre un serveur de test sur un autre port. Compiler ce client avec `--no-web-resources-cdn` pour ne pas retélécharger CanvasKit.
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

## Identité visuelle

- **Logo :** bulle de dialogue blanche avec les trois points de saisie (le dernier plus pâle) sur un carré arrondi en dégradé `#5B5BD6` → `#8B5CF6`. **Source unique :** `app/lib/branding/logo_geometry.dart` (Dart pur).
- **Icônes :** `cd app && dart run tool/generate_icons.dart` régénère tout à partir de cette géométrie, à relancer après toute modification du logo. Sont produits : `web/favicon.png`, `web/icons/*` (dont `logo.svg` et les versions maskable), les mipmaps Android (legacy, adaptive avec foreground/background, monochrome pour Android 13), `windows/runner/resources/app_icon.ico` (16 à 256 px) et `assets/branding/` (logo 1024 px et SVG).
- **Dans l'application :** le widget `DismessageLogo` dessine le logo (pas d'image). `AppTheme` (`app/lib/theme/app_theme.dart`) centralise les couleurs, le dégradé de marque, la typographie et le style des composants. Ne pas recréer de `ThemeData` ailleurs.
- **Styles de texte des boutons :** ne jamais y mettre de `color`, qui écraserait la couleur du bouton.
- **Avatars :** `ContactAvatar` attribue une couleur stable dérivée de l'ID.

## Production

| Élément | Où | Comment |
| --- | --- | --- |
| Relais | Render (Web Service, offre Free) : `https://dismessage.onrender.com` | `Dockerfile` à la racine, déploiement automatique à chaque push sur `main`. Health check : `/health` |
| Client web | GitHub Pages | `.github/workflows/pages.yml` (tests + `flutter build web --base-href /<dépôt>/`) |
| APK / EXE | `dist/` (local) | `cd app/android && ./gradlew.bat assembleRelease --offline` / `flutter build windows --release` |
| Installateur Windows | `dist/Dismessage-Setup.exe` | Double-cliquer sur `build-installer.bat` (compile l'appli puis `installer/dismessage.iss`, Inno Setup 6 installé dans `%LOCALAPPDATA%\Programs\Inno Setup 6`) |

- **Installateur :** assistant en français, sans droits administrateur (ou « pour tous les utilisateurs »), raccourcis menu Démarrer et Bureau, entrée dans Paramètres > Applications, option « Lancer Dismessage au démarrage de Windows » (clé `HKCU\…\Run`, avec `--minimized`), runtime Visual C++ copié à côté de l'appli. Ne jamais changer l'`AppId` du script : c'est lui qui fait qu'une nouvelle version remplace l'ancienne. La version vient de `app/pubspec.yaml`. Non signé : SmartScreen affiche « Éditeur inconnu ».
- **Appli Windows :** une seule instance par session en release (mutex nommé ; relancer ramène la fenêtre existante, car deux copies se disputeraient le même ID ; pas en debug, pour lancer `flutter run` à côté de l'appli installée) ; `--minimized` ouvre la fenêtre réduite sans prendre le focus (`windows/runner/main.cpp`).

- **Serveur par défaut :** `kProductionServer` dans `app/lib/config.dart`, utilisé par les versions release et par le web sur `*.github.io` (`chooseServerUri`, testé dans `config_test.dart`). Les versions debug visent un relais local.
- **Limites de Render Free :** mise en veille après environ 15 min d'inactivité (premier réveil de 30 à 60 s), et pas de disque persistant. `ids.json` est perdu au redémarrage, et chaque client réenregistre son ID avec son secret.
- **Android :** le NDK est fixé à `29.0.13113456` (déjà installé). Ne pas revenir à `flutter.ndkVersion`, qui déclencherait un téléchargement.

## Accès depuis internet (tunnel VS Code)

Le serveur sert à la fois le relais (`/ws`) et le client web (`app/build/web`, variable `DISMESSAGE_WEB`). Un seul lien public suffit donc.

1. Double-cliquer sur `start-server.bat` (à la racine). Il compile le client web s'il manque ou si le code a changé depuis la dernière compilation (commit noté dans `app/build/web/.dismessage-commit`, ou modifications non commitées ; `--rebuild` pour forcer). Un client web périmé face à un serveur récent produit des erreurs de trame, puis démarre le serveur sur le port 8080 (`start-server.bat 9000` pour un autre port).
2. VS Code, onglet **Ports** : transférer le port `8080` et passer sa **visibilité en Public**. En privé, les clients extérieurs sont redirigés vers une connexion GitHub.
3. Navigateur : ouvrir le lien `https://xxxx-8080.<région>.devtunnels.ms`. La page parle à son propre serveur (`ServerAddress.sameOrigin`).
4. Windows et Android : bouton **Serveur** de l'accueil, puis coller le même lien. Il est converti en `wss://…/ws` (`ServerAddress.parse`) et mémorisé.
   Ou bien, à la compilation : `--dart-define=SERVER_URL=https://xxxx-8080…`.

Le tunnel est lent (10 à 20 Ko/s mesurés) : le serveur compresse les fichiers statiques en gzip (`gzip_middleware.dart`) et les sert avec `Cache-Control: no-cache` (le navigateur garde sa copie mais vérifie qu'elle est à jour : un `304` si rien n'a changé). Sans cet en-tête, un navigateur réutilisait l'ancienne police d'icônes (même nom à chaque compilation, réduite aux icônes utilisées) et les nouvelles icônes restaient vides, et `web/index.html` affiche un écran de chargement jusqu'au premier rendu Flutter (`web/flutter_bootstrap.js`). Il faut compter environ 1 minute au premier chargement, puis le cache du navigateur prend le relais.

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
| `message_commit` | C→S→C | `sid`, `seq`, `text`, `mid` (EntryId ; absent chez les anciennes versions → `EntryId.legacy(seq)`), `reply`? (EntryId de la bulle citée) |
| `image_offer` | C→S→C | `sid`, `img` (EntryId), `w`, `h`, `preview` (JPEG base64, déjà flouté, ≤ `kMaxImagePreviewLength`), `reply`? |
| `image_request` | C→S→C | `sid`, `img` (le destinataire ouvre l'image ; sert aussi d'accusé « Ouverte ») |
| `image_data` | C→S→C | `sid`, `img`, `data` (JPEG base64, ≤ `kMaxImageDataLength`) |
| `voice` | C→S→C | `sid`, `mid`, `ms` (durée), `mime` (`audio/…`), `data` (base64, ≤ `kMaxVoiceDataLength`), `reply`? |
| `reaction` | C→S→C | `sid`, `ref` (EntryId d'une bulle du destinataire), `emoji` (`""` = retirée, ≤ `kMaxReactionLength`) |
| `presence_watch` | C→S | `ids` (≤ `kMaxPresenceWatch`, remplace la liste précédente ; enregistrement requis) |
| `presence` | S→C | `id`, `online` (une par ID à la réception de `presence_watch`, puis à chaque changement) |
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
| `server/test/relay_test.dart` | Vrai serveur sur port éphémère : enregistrement, vol d'ID, release, mise en relation, relais isolé par session (dont réponses, réactions, vocaux, un client dans deux sessions), présence, robustesse |
| `app/test/live_draft_bubble_test.dart` | Points absents pendant la frappe, présents après `kPauseDotsMs` et collés au texte, déroulé progressif, fondu, emoji |
| `app/test/home_screen_test.dart` | Affichage de l'ID, validation de l'ID saisi, régénération avec confirmation |
| `app/test/end_to_end_test.dart` | Deux `ConnectionService` réels + vrai relais : frappe en direct, envoi, départ, ID stable, régénération, annulation, A ↔ B et A ↔ C en même temps |
| `app/test/multi_session_test.dart` | Plusieurs sessions : routage par `sid`, non-lus, `peer_left` isolé, fermeture, remplacement du même pair, perte du relais, nouvel ID |
| `app/test/chats_shell_test.dart` | Avatars flottants (dès 2), badge, bascule, fermeture par appui long, saisie conservée ; sidebar (noms, présence, non-lus, ✕) ; Retour garde les conversations (« Conversations en cours ») ; contact déjà en conversation rouvert |
| `app/test/home_requests_test.dart` | Faux serveur scripté (`test/fakes.dart`) : attente, annulation, refus, expiration, boîte entrante, contacts |
| `app/test/connection_diagnostics_test.dart` | Délais de connexion, nouvelles tentatives, bandeau d'erreur, bouton « Réessayer » |
| `app/test/contacts_service_test.dart`, `chat_screen_test.dart` | Carnet de contacts (persistance, validation) et enregistrement depuis le chat |
| `app/test/image_codec_test.dart` | Redimensionnement, plafond de taille, miniature, transparence, **suppression de l'EXIF**, fichier corrompu |
| `app/test/chat_session_images_test.dart`, `chat_media_test.dart` | Flux miniature, ouverture, données et accusé ; données non sollicitées ignorées ; bulle floutée ; panneau d'émojis (insertion au curseur, diffusion en direct) |
| `app/test/chat_session_features_test.dart` | IDs de bulles, réponses (référence inconnue ignorée), réactions (bascule, seulement sur les bulles d'autrui), vocaux (taille, doublons) |
| `app/test/chat_features_test.dart` | Multiligne et Entrée / Maj+Entrée, réponse par menu et par glissement, réactions, bouton photo (appareil / galerie, webcam PC : prise, fermeture, refus), enregistrement, annulation, durée max, refus du micro, lecture, défilement (frappe fixe, bouton « ↓ »), curseur rendu après émoji / photo |
| `app/test/background_mode_test.dart` | Option arrière-plan : désactivée par défaut, enregistrée (lue au démarrage du téléphone), transmise au service ; absente hors Android |
| `app/test/presence_test.dart` | Liste surveillée, point vert / gris, ajout de contact, présence oubliée à la déconnexion |
| `app/test/chat_notifications_test.dart` | Rien si visible ; message caché (son, réponse) ; empilement limité ; frappe annoncée une fois puis mise à jour silencieuse et espacée ; effacement ; retour dans l'appli ; réponse depuis la notification (brouillon conservé) |
| `app/tool/check_windows_notifications.dart` | Vrais toasts Windows (`flutter run -d windows -t tool/check_windows_notifications.dart`, affiche OK / ÉCHEC) : affichage avec champ de réponse, mise à jour sur place, remplacement, retrait. Deux identités en mémoire et relais dans le processus : l'ID de l'utilisateur n'est jamais utilisé. Pas de paquet `integration_test` : sa partie Android exige un plugin Gradle absent du cache et casserait la compilation de l'APK hors ligne |

- Le test de bout en bout utilise `test()` et non `testWidgets()` : sans binding de widgets, les vraies sockets et les vrais timers fonctionnent.
- Pour simuler plusieurs clients dans un même process, on injecte `MemoryStore` dans `IdentityService` (`SharedPreferences` est un singleton).
- `TypingDots` tourne en boucle : dans un test de widgets, utiliser `pump(durée)`, jamais `pumpAndSettle()` quand les points sont affichés.
- `ChatScreen` reçoit ses dépendances matérielles par injection (`pickImage`, `cameraAvailable`, `createRecorder`, `createAudioBackend`) : dans les tests, utiliser `FakeVoiceRecorder` et `FakeAudioBackend` (`test/fakes.dart`). `VoicePlayer` ne crée son lecteur qu'à la première lecture.
