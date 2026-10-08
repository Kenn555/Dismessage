# Dismessage

Messagerie « contextuelle » : on voit l'interlocuteur écrire **en direct**, caractère par caractère, de façon fluide.
Quand il fait une pause, trois points animés `…` s'affichent **à la fin du texte déjà tapé**.
Chaque installation a un **ID à 9 chiffres** (style AnyDesk, ex. `482 913 075`), **attribué par le relais**, qui ne change que si l'utilisateur en génère un nouveau.

## Architecture

| Dossier | Rôle | Techno |
| --- | --- | --- |
| `packages/protocol/` | Trames du protocole, IDs, algorithme de diff, état du brouillon reçu | Dart pur (aucune dépendance Flutter) |
| `server/` | Relais WebSocket : enregistrement des IDs, mise en relation, relais des trames | Dart (`shelf`, `shelf_web_socket`) |
| `app/` | Client (Android, Web, Windows) | Flutter, Material 3 |

**Règle d'or : toute logique qui n'est pas de l'affichage va dans `packages/protocol`**, où elle est testable sans Flutter.

- Les messages sont **éphémères** : rien n'est stocké, ni côté serveur ni côté client. Seule exception voulue : un **fichier** que le destinataire accepte est enregistré dans ses téléchargements.
- Les **contacts** (`ContactsService`) sont stockés **uniquement sur l'appareil** (clé `dismessage.contacts`). Ils ne contiennent qu'un ID et un nom, jamais de message.
- **Images :** seule une miniature déjà floutée part à l'envoi (`image_offer`). L'image nette n'est transférée (`image_data`) que quand le destinataire appuie pour l'ouvrir (`image_request`), et l'expéditeur voit alors « Ouverte ». `ImageCodec` réduit l'image à `kMaxImageSide`, la recompresse sous `kMaxImageBytes` et **supprime l'EXIF** (dont la position GPS). Les images ne vivent qu'en mémoire, comme les messages. Un client n'accepte un `image_data` que pour une image qu'il a demandée.
- **Fichiers :** bouton trombone (`ChatScreen._chooseFile`). Seule l'offre part (`file_offer` : nom, taille) ; le destinataire voit « Accepter » / « Refuser » dans la bulle (`FileBubble`). Une fois accepté, le fichier passe par morceaux de `kFileChunkBytes` (`file_chunk`), au plus `kFileWindowChunks` d'avance sur les accusés (`file_ack`, envoyés après écriture sur disque) : le relais ne stocke rien et la frappe en direct reste fluide pendant le transfert. Le dernier accusé signifie « enregistré » (« Reçu » chez l'expéditeur). `file_cancel` sert au refus comme à l'annulation par l'un ou l'autre ; une erreur de lecture ou d'écriture, un départ ou la fermeture de la conversation arrêtent le transfert et **suppriment le fichier partiel**. Plafond `kMaxFileBytes` (512 Mo). Le nom reçu est assaini (`FileNames.sanitize` : pas de chemin, de caractère interdit ni de nom réservé Windows) et jamais un fichier existant n'est écrasé (`nom (2).ext`). Logique pure : `OutgoingTransfer` / `IncomingTransfer` (`file_transfer.dart`) ; flux : `ChatSession.sendFile` / `acceptFile` / `cancelFile` ; E/S : `FileStorage` / `ChosenFile` (`file_storage*.dart`, injectés : `ConnectionService(fileStorage:)`, `ChatScreen(pickFile:)`).
  - **Windows :** sélecteur `file_selector_windows` (via son interface, comme `record_windows`) ; écriture dans **Téléchargements** sous `nom.part`, renommé une fois complet ; « Ouvrir » et « Afficher dans le dossier » (`explorer.exe`).
  - **Android :** canal maison `dismessage/files` (`FileHandler.kt`, sans dépendance Gradle) : sélecteur système (`ACTION_OPEN_DOCUMENT`, réponse via `MainActivity.onActivityResult`), lecture par morceaux, écriture MediaStore dans **Téléchargements/Dismessage** (masqué tant que `IS_PENDING`). Avant Android 10 : dossier Téléchargements propre à l'appli (pas de permission), sans « Ouvrir ».
  - **Web :** `<input type=file>` lu par tranches (`Blob.slice`) ; une page ne peut pas écrire sur le disque, les morceaux restent en mémoire puis le navigateur télécharge le fichier comme d'habitude.
- **Blocage et « contacts seulement » :** sur l'appareil seulement, avec les contacts (`ContactsService`, clés `dismessage.blocked` et `dismessage.contactsOnly`) ; le relais n'en sait rien. Une demande d'un ID bloqué, ou d'un inconnu avec « Seuls mes contacts peuvent me joindre », est **ignorée sans réponse** (`ConnectionService(acceptsRequestFrom:)`, branché sur `allowsRequestFrom`) : ni boîte de dialogue ni notification, et le demandeur ne voit qu'une absence de réponse. On bloque depuis la demande (« Bloquer » = refuser + bloquer, annulable), le menu d'un contact (Bloquer / Débloquer) ou le menu ⋮ de la conversation (confirmation, puis fermeture). Le bouton **Réglages** de l'accueil existe désormais partout : arrière-plan (Android), « contacts seulement », liste des IDs bloqués avec « Débloquer ».
- **Émojis :** panneau intégré (`EmojiPanel`), sans paquet externe. L'émoji est inséré au curseur puis diffusé en direct comme une frappe.
- **Bulles :** chaque bulle (texte, image, vocal) porte un `EntryId` (16 hex aléatoires), commun aux deux pairs. Il sert aux **réponses** (champ `reply`, glisser la bulle vers la droite ou appui long → « Répondre ») et aux **réactions** (une seule par bulle, uniquement sur les bulles de l'interlocuteur ; renvoyer le même émoji la retire). Une référence vers une bulle inconnue est ignorée.
- **IDs masqués :** mon ID et ceux des contacts enregistrés s'affichent `482 *** 075` (`DismessageId.mask`), avec un bouton œil pour les dévoiler (`IdPrivacy`, non mémorisé : masqué à chaque lancement). « Copier » copie l'ID complet. L'ID d'un inconnu reste complet, pour savoir qui c'est.
- **Captures d'écran bloquées** (toujours, debug compris) : Android pose `FLAG_SECURE` (`MainActivity.onCreate` : captures, enregistrements, diffusion et miniature des applis récentes en noir) ; Windows appelle `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` (`flutter_window.cpp` : fenêtre absente des captures depuis Windows 10 2004, noire avant via `WDA_MONITOR`). Impossible sur le web : un navigateur ne laisse pas une page l'empêcher. Les notifications restent capturables. Les outils qui photographient l'écran ne voient donc pas l'appli Windows.
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
- **Arrière-plan Android :** option « Rester joignable en arrière-plan » (bouton Réglages de l'accueil, option présente sur Android seulement, désactivée par défaut ; `BackgroundMode`, clé `dismessage.background`). Un service de premier plan (`BackgroundService.kt`, type `specialUse`, notification discrète « Dismessage est actif ») garde la connexion avec l'écran fermé, et `BootReceiver` le relance au démarrage du téléphone. Un **seul moteur Flutter** (`EngineHolder`) sert l'écran et le service : `MainActivity` s'y rattache (`provideFlutterEngine`, `shouldDestroyEngineWithHost = false`) ; les canaux `dismessage/voice`, `dismessage/notify` et `dismessage/background` sont créés une fois avec le contexte de l'application, l'activité ne sert qu'aux demandes de permission. Démarrée sans écran, l'appli se considère non visible (`main.dart`) et redemande la permission de notifier à l'ouverture. Certains fabricants (Xiaomi, Huawei…) tuent quand même les applis en arrière-plan : il faut alors autoriser Dismessage dans leurs réglages de batterie.
  - **Émulateur :** Flutter ne tourne pas sur une image Android x86 32 bits (`libflutter.so` est ARM / x86_64). L'image `android-30 x86` présente ne convient donc pas ; il faudrait une image x86_64 (téléchargement de plus d'1 Go).
  - **Pair de test :** `cd server && dart run tool/test_peer.dart ws://localhost:8099/ws` donne un second client piloté par HTTP (port 9555 : `/request?to=`, `/cancel`, `/draft?text=`, `/send?text=`, `/log`), pour essayer l'appli sur un vrai appareil.
- **Essai réel dans un navigateur :** Chrome sans interface piloté par le protocole DevTools (deux contextes isolés = deux utilisateurs, micro simulé par `--use-fake-device-for-media-stream`, sélecteur de fichiers intercepté), contre un serveur de test sur un autre port. Compiler ce client avec `--no-web-resources-cdn` pour ne pas retélécharger CanvasKit.
- **Limites du relais** (`server/lib/src/rate_limit.dart`, seaux de jetons : une rafale puis un débit, valeurs `kRate*` dans `constants.dart`, injectables : `Relay(limits:, clock:)`). Le débit (trames, octets) est **freiné** : le relais cesse de lire la socket le temps nécessaire, rien n'est perdu et un fichier ralentit sans casser. Le reste est **refusé** par `error` `rate_limited` : demandes de conversation (par connexion et par IP, ID hors ligne compris, pour qu'on ne puisse pas sonder les IDs), enregistrements par IP, **nouveaux** IDs par IP (chacun grossit `ids.json`), listes de présence. Au-delà de `kMaxConnectionsPerIp`, la connexion reçoit `too_many_connections` et se ferme. Une seule ligne de journal par connexion et par limite. Côté client : un refus avant `registered` ferme la connexion et réessaie avec le délai habituel, la cause s'affiche dans le bandeau ; une demande refusée cesse d'attendre et le message s'affiche.
  - **IP du client** (`clientIp`) : en-tête nommé par `DISMESSAGE_IP_HEADER` (Render : `cf-connecting-ip`, posé par Cloudflare, dans le `Dockerfile`), sinon la **dernière** entrée de `X-Forwarded-For` (les précédentes viennent du client et peuvent être forgées ; Render ne les efface pas), sinon l'adresse de la socket. Si l'en-tête manque en production, tous les clients risquent de partager l'IP du proxy : vérifier dans le journal Render que les connexions affichent des IPs variées.
- **Pages légales** (`app/lib/legal/legal_texts.dart`, Dart pur, **source unique**) : mentions légales (éditeur « Kenn », particulier, régime de l'art. 6 III-2 LCEN : adresse et téléphone remplacés par les hébergeurs Render et GitHub), politique de confidentialité, conditions d'utilisation (18 ans minimum, `kMinimumAge`). Affichées dans l'appli (`LegalScreen`, liens dans « À propos » et sur l'écran d'accord) et publiées sur le web : `cd app && dart run tool/generate_legal.dart` écrit `web/legal/*.html` (autonomes, sans ressource externe), publiés avec le client web (`<site>/legal/confidentialite.html`, l'adresse à donner aux magasins d'applis). Un test vérifie que ces fichiers sont à jour. **Chaque phrase doit rester vraie** : tout changement de ce qui est stocké, journalisé ou envoyé met à jour ces textes, `kLegalUpdated` et, si c'est important, `kTermsVersion` (redemande l'accord).
  - **Premier lancement** (`ConsentGate`, `LegalConsent`, clé `dismessage.termsAccepted` = `kTermsVersion`) : « J'ai 18 ans ou plus » et « J'accepte les conditions… » cochés avant « Continuer ». **Aucune connexion au relais avant** (`main.dart` : `startConnection` seulement une fois accepté).
- **À propos** (bouton ⓘ de l'accueil, `AboutDismessageDialog`) : version, ce qui est conservé, lien GitHub (`kRepositoryUrl`), licences des composants. Lien ouvert par `openLink` (`link_opener*.dart`, injecté : `HomeScreen(openLink:)`) : méthode `openUrl` du canal `dismessage/files` sur Android (pas de `url_launcher`, qui ajouterait des dépendances Gradle), `explorer.exe` sur Windows, nouvel onglet sur le web ; à défaut, le lien est copié. Sous `kCompactHeaderWidth` (480 px), Réglages / Serveur / À propos passent dans un menu ⋮, et le titre se raccourcit plutôt que de déborder.
- **Version :** `version` de `app/pubspec.yaml` (installateur, APK) et `kAppVersion` (`config.dart`, affichée dans « À propos ») doivent rester égales, un test le vérifie. Changer aussi le numéro de build `+N` (versionCode Android : sans hausse, la mise à jour est refusée). Gradle lit la version dans `app/android/local.properties` (généré, non versionné), que seul `flutter build apk` réécrit : avec `gradlew assembleRelease`, y mettre à jour `flutter.versionName` et `flutter.versionCode`.
- **IDs signés** (`IdSigner`, `server/lib/src/id_signer.dart`) : le relais choisit l'ID (`id_request` → `id_assigned`) et son secret vaut `HMAC-SHA256(clé, id)`. Il vérifie donc un secret **sans rien mémoriser** : un ID survit à un redémarrage qui perd `ids.json` (Render Free), et personne ne peut obtenir le secret d'un ID choisi. Clé : variable `DISMESSAGE_ID_KEY` (32 caractères ou plus, à définir dans Render et **à ne jamais changer** : tous les IDs changeraient), sinon fichier `id_key` à côté de `ids.json` (local). Jamais loggée. Un ID tiré au sort évite les IDs en ligne ou connus ; un propriétaire hors ligne inconnu depuis un redémarrage pourrait être retiré (1 chance sur 900 millions par propriétaire).
  - `register` : secret signé → accepté ; sinon ID connu de `ids.json` (`ID → sha256(secret)`) → comparé, et accepté avec, en plus, `id_assigned` (même ID, secret signé) ; sinon `error` `unsigned_id` (« version trop ancienne »), sauf `DISMESSAGE_LEGACY_IDS=1` (transition : ID inconnu pris par le premier venu, puis signé). L'ancien secret reste en mémoire tant que le relais s'en souvient : un ancien client ignore `id_assigned`.
  - **Client** (`IdentityService`) : une identité **par relais** (clé `dismessage.id@hôte:port`), puisque chaque relais signe avec sa propre clé ; changer de serveur puis revenir retrouve l'ID. L'identité des anciennes versions (`dismessage.id`, choisie par l'appli) est essayée sur un relais qui n'en a pas encore donné, jamais écrasée. Premier lancement : pas d'ID (« attribué dès la connexion ») ; `id_taken` ou `unsigned_id` → `id_request`. « Générer un nouvel ID » n'est possible qu'en ligne ; l'ancien est libéré (`release`) une fois le nouveau enregistré.
- Transport : JSON sur WebSocket (`ws://` en dev, `wss://` en prod).
- **Chiffrement de bout en bout** (`E2eSession`, `packages/protocol/lib/src/e2e.dart`, paquet `cryptography`) : le relais ne voit que `key_offer` (clés publiques) et `sealed` (chiffré), et **refuse toute autre trame de conversation** (`error` `unencrypted`). Chaque conversation a sa paire X25519 éphémère ; HKDF-SHA256 (sel = `sid`, info = clé de l'émetteur puis du destinataire) donne une clé par sens ; chaque trame (son JSON) est chiffrée en ChaCha20-Poly1305, nonce = compteur `n` (croissant : rejeu et désordre refusés), `sid` authentifié. Rien n'est conservé après la conversation.
  - **App** (`ConnectionService`) : à `session_started`, envoie sa clé, puis scelle chaque trame de `ChatSession` dans l'ordre (`_sendInSession`, file d'attente par session) ; ouvre les `sealed` reçus dans l'ordre (`_inOrder`, `peer_left` y passe aussi). Une trame en clair, altérée ou rejouée est ignorée. Sans la clé de l'autre au bout de `kE2eHandshakeSeconds`, la conversation est fermée (`EncryptionFailedEvent`, « rien n'a été envoyé ») : **jamais de repli en clair**. `ChatSession` ne voit que des trames en clair : le chiffrement lui est transparent (ses tests aussi).
  - **Code de sécurité** (menu ⋮ de la conversation → « Vérifier le chiffrement », `safetyCode`) : 20 chiffres tirés des deux clés publiques, identiques des deux côtés sauf si le relais s'interpose dans l'échange de clés. À comparer de vive voix ; il change à chaque conversation.
  - **Tailles :** `kMaxInnerFrameLength` (trame avant chiffrement, une image), `kMaxSealedDataLength`, `kMaxFrameLength` (trame brute). Le relais ne peut plus valider le contenu : c'est le destinataire qui applique `Frame.decode` à la trame déchiffrée.
  - **Tests :** les faux serveurs jouent l'autre côté (`ScriptedChannel.startSession` / `receiveSecure` / `openedSent` / `peerSafetyCode`), les clients des tests du relais chiffrent aussi (`TestClient.sendSecure` / `expectSecure`). Dans `testWidgets`, attendre ces futures directement, jamais dans `tester.runAsync` (créées dans la zone du faux temps, elles n'y aboutiraient pas).
- **Version du protocole :** `register` porte `v` (`kProtocolVersion`, absent = 1). Le relais refuse sous `kMinProtocolVersion` (`error` `update_required`, affiché dans le bandeau). Actuellement 2 : la version 1 ne chiffre pas. Monter `kProtocolVersion` (et au besoin le minimum) à chaque changement qui exige une mise à jour.

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
# Chiffrement compilé en JavaScript (le web passe par Web Crypto) : à relancer après tout changement de e2e.dart
cd packages/protocol && CHROME_EXECUTABLE="C:/Program Files/Google/Chrome/Application/chrome.exe" dart test -p chrome test/e2e_test.dart test/e2e_vectors_test.dart

# Analyse statique
dart analyze packages/protocol server
cd app && flutter analyze

# Lancer
cd server && dart run bin/server.dart            # PORT=8080 par défaut
cd server && dart run tool/check_relay.dart wss://dismessage.onrender.com/ws   # vérifie un relais en ligne (après un déploiement) : IDs signés, conversation, chiffrement, refus du clair
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
- **Limites de Render Free :** mise en veille après environ 15 min d'inactivité (premier réveil de 30 à 60 s), et pas de disque persistant. `ids.json` est perdu au redémarrage : les IDs tiennent grâce à leur signature (`DISMESSAGE_ID_KEY` doit être définie dans Render).
- **Android :** le NDK est fixé à `29.0.13113456` (déjà installé). Ne pas revenir à `flutter.ndkVersion`, qui déclencherait un téléchargement.
- **Signature Android :** `app/android/key.properties` (jamais commité) désigne la clé `C:\Users\GAMING_HERICO\.dismessage\dismessage-release.jks` (alias `dismessage`, mot de passe dans le fichier ; copie de `key.properties` dans le même dossier). **Sauvegarder ce dossier** : sans cette clé, plus aucune mise à jour ne s'installe par-dessus. Sans `key.properties`, `assembleRelease` signe avec la clé de débogage. Un APK signé avec l'ancienne clé de débogage doit être désinstallé avant d'installer la version signée. `./gradlew.bat :app:signingReport --offline` montre la clé utilisée.

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
| `id_request` | C→S | — (demande un nouvel ID, avant ou après enregistrement) |
| `id_assigned` | S→C | `id`, `secret` (signé ; réponse à `id_request`, ou même ID re-signé après un `register` à l'ancienne) |
| `register` | C→S | `id`, `secret`, `v` (version du protocole, absent = 1) |
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
| `key_offer` | C→S→C | `sid`, `key` (clé publique X25519, base64url), relayée telle quelle |
| `sealed` | C→S→C | `sid`, `n` (compteur ≥ 1, nonce), `data` (base64 : JSON de l'une des trames ci-dessous, chiffré, + étiquette de 16 octets ; ≤ `kMaxSealedDataLength`). **Les trames suivantes ne voyagent qu'à l'intérieur de `sealed`** ; en clair, le relais les refuse |
| `draft_ops` | C→S→C | `sid`, `seq`, `ops[{pos,del,ins}]` |
| `draft_snapshot` | C→S→C | `sid`, `seq`, `text` |
| `draft_resync` | C→S→C | `sid` |
| `draft_clear` | C→S→C | `sid`, `seq` |
| `message_commit` | C→S→C | `sid`, `seq`, `text`, `mid` (EntryId ; absent chez les anciennes versions → `EntryId.legacy(seq)`), `reply`? (EntryId de la bulle citée) |
| `image_offer` | C→S→C | `sid`, `img` (EntryId), `w`, `h`, `preview` (JPEG base64, déjà flouté, ≤ `kMaxImagePreviewLength`), `reply`? |
| `image_request` | C→S→C | `sid`, `img` (le destinataire ouvre l'image ; sert aussi d'accusé « Ouverte ») |
| `image_data` | C→S→C | `sid`, `img`, `data` (JPEG base64, ≤ `kMaxImageDataLength`) |
| `voice` | C→S→C | `sid`, `mid`, `ms` (durée), `mime` (`audio/…`), `data` (base64, ≤ `kMaxVoiceDataLength`), `reply`? |
| `file_offer` | C→S→C | `sid`, `fid` (EntryId), `name` (≤ `kMaxFileNameLength`, sans caractère de contrôle), `size` (0 à `kMaxFileBytes`), `reply`? |
| `file_accept` | C→S→C | `sid`, `fid` (le destinataire accepte : les morceaux peuvent partir) |
| `file_cancel` | C→S→C | `sid`, `fid` (refus, annulation ou erreur, dans les deux sens) |
| `file_chunk` | C→S→C | `sid`, `fid`, `i` (index du morceau, dans l'ordre), `data` (base64, ≤ `kMaxFileChunkDataLength`) |
| `file_ack` | C→S→C | `sid`, `fid`, `n` (morceaux écrits sur disque ; `n` = total : fichier enregistré) |
| `reaction` | C→S→C | `sid`, `ref` (EntryId d'une bulle du destinataire), `emoji` (`""` = retirée, ≤ `kMaxReactionLength`) |
| `presence_watch` | C→S | `ids` (≤ `kMaxPresenceWatch`, remplace la liste précédente ; enregistrement requis) |
| `presence` | S→C | `id`, `online` (une par ID à la réception de `presence_watch`, puis à chaque changement) |
| `error` | S→C | `code`, `message` (`ErrorCodes` : `rate_limited` = limite atteinte, la trame est ignorée ; `too_many_connections` = trop de connexions depuis cette IP, la connexion se ferme ; `unsigned_id` = secret non signé pour un ID inconnu, demander `id_request` ; `update_required` = version du protocole trop ancienne. Aussi `unencrypted`, `unknown_session`, `bad_frame`…) |
| `ping` / `pong` | C↔S | — |

## Règles

- **Chaque changement visible** pour l'utilisateur s'ajoute à `RELEASED.md` (notes de version en français, la plus récente en premier : « À lire avant de mettre à jour », Nouveautés, Sécurité et vie privée, Améliorations, Corrections), sous la version de `app/pubspec.yaml`.
- **Toute modification du protocole** met à jour, dans le même changement : `packages/protocol/lib/src/frames.dart`, le tableau ci-dessus et les tests d'aller-retour JSON (`frames_test.dart`).
- Une trame invalide ne doit **jamais** faire planter le serveur : elle est rejetée par une trame `error`.
- Le **secret** d'un ID ne transite que dans `register` / `release` / `id_assigned`, et la **clé des IDs** jamais. Il n'est jamais loggé, et le serveur ne stocke que son hash. Le journal du serveur (`Relay(log: …)`) affiche les connexions, les IDs et les demandes, et un test vérifie qu'aucun secret n'y apparaît.
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
| `packages/protocol/test/*` | IDs, diff (dont le test aléatoire de 1 000 paires), émetteur et récepteur de brouillon, trames JSON (dont version de `register`), chiffrement (`e2e_test.dart` : aller-retour, image maximale, attente des clés, trame altérée / rejouée / déplacée / renvoyée / d'une autre conversation, seconde clé, clé faible, code identique, différent avec un relais au milieu) |
| `server/test/relay_test.dart` | Vrai serveur sur port éphémère, clients qui chiffrent vraiment : enregistrement, vol d'ID, release, mise en relation, relais isolé par session (dont réponses, réactions, vocaux, fichiers, un client dans deux sessions), IDs attribués et signés (redémarrage sans stockage, autre clé, collisions évitées, transition des anciens clients, signataire), seul le chiffré est relayé (trame en clair refusée, contenu illisible pour le relais), version minimale, présence, robustesse, limites (demandes par connexion et par IP puis recharge, nouveaux IDs, enregistrements, présence, connexions par IP, débit freiné sans perte, usage normal non gêné), IP du client |
| `app/test/legal_test.dart` | Textes (contact, âge, éditeur, hébergeurs), pages web à jour et autonomes, écran légal, liens de « À propos », écran d'accord (les deux cases, lecture des textes, accord mémorisé, redemandé si les conditions changent) |
| `app/test/about_dialog_test.dart`, `config_test.dart` | « À propos » : version, lien GitHub (copié si aucun navigateur), licences, menu ⋮ sur petit téléphone ; version égale à `pubspec.yaml` |
| `app/test/live_draft_bubble_test.dart` | Points absents pendant la frappe, présents après `kPauseDotsMs` et collés au texte, déroulé progressif, fondu, emoji |
| `app/test/home_screen_test.dart`, `identity_service_test.dart` | Affichage de l'ID, premier lancement sans ID, validation de l'ID saisi, régénération seulement en ligne (confirmation et échange avec le relais dans `home_requests_test.dart`) ; une identité par relais, ancienne identité essayée sans être écrasée |
| `app/test/end_to_end_test.dart` | Deux `ConnectionService` réels + vrai relais : rien de lisible sur le réseau (connexion espionnée) et même code de sécurité des deux côtés, frappe en direct, envoi, fichier écrit sur disque après acceptation (frappe toujours en direct), départ, ID stable, régénération, annulation, A ↔ B et A ↔ C en même temps, un ID par relais retrouvé au retour, ID conservé après un redémarrage qui perd le stockage, ancien ID signé ou remplacé |
| `app/test/multi_session_test.dart` | Plusieurs sessions : routage par `sid`, trame en clair ignorée et rien n'est envoyé en clair, non-lus, `peer_left` isolé, fermeture, remplacement du même pair, perte du relais, nouvel ID |
| `app/test/chats_shell_test.dart` | Code de sécurité affiché par le menu de la conversation ; Avatars flottants (dès 2), badge, bascule, fermeture par appui long, saisie conservée ; sidebar (noms, présence, non-lus, ✕) ; Retour garde les conversations (« Conversations en cours ») ; contact déjà en conversation rouvert |
| `app/test/home_requests_test.dart` | Faux serveur scripté (`test/fakes.dart`) : conversation fermée sans clé de l'autre (rien envoyé), attente, annulation, refus, expiration, boîte entrante, contacts |
| `app/test/connection_diagnostics_test.dart` | Délais de connexion, nouvelles tentatives, bandeau d'erreur, bouton « Réessayer », enregistrement refusé par une limite |
| `app/test/contacts_service_test.dart`, `chat_screen_test.dart` | Carnet de contacts (persistance, validation), blocage et « contacts seulement » (persistance, entrées invalides), enregistrement et blocage depuis le chat (blocage depuis la demande, un contact, les réglages : `home_requests_test.dart`) |
| `app/test/image_codec_test.dart` | Redimensionnement, plafond de taille, miniature, transparence, **suppression de l'EXIF**, fichier corrompu |
| `app/test/chat_session_images_test.dart`, `chat_media_test.dart` | Flux miniature, ouverture, données et accusé ; données non sollicitées ignorées ; bulle floutée ; panneau d'émojis (insertion au curseur, diffusion en direct) |
| `app/test/chat_session_features_test.dart` | IDs de bulles, réponses (référence inconnue ignorée), réactions (bascule, seulement sur les bulles d'autrui), vocaux (taille, doublons) |
| `packages/protocol/test/file_transfer_test.dart` | Découpage en morceaux, fenêtre d'envoi, accusés impossibles, ordre et taille des morceaux reçus (test aléatoire émetteur / récepteur), assainissement et unicité des noms |
| `app/test/chat_session_files_test.dart` | Offre seule avant acceptation, transfert complet octet pour octet, fenêtre, progression, refus, retrait, annulation et départ en cours (fichier partiel supprimé), erreurs de lecture / d'écriture / de dossier, fichier vide, plafond, nom dangereux, morceaux non sollicités ou désordonnés |
| `app/test/chat_files_test.dart`, `file_storage_test.dart` | Bouton trombone, retrait, fichier trop gros, Accepter / Refuser, progression, Ouvrir / dossier, erreur affichée ; écriture `.part` puis renommage, pas d'écrasement, abandon ; tailles en français |
| `app/test/chat_features_test.dart` | Multiligne et Entrée / Maj+Entrée, réponse par menu et par glissement, réactions, bouton photo (appareil / galerie, webcam PC : prise, fermeture, refus), enregistrement, annulation, durée max, refus du micro, lecture, défilement (frappe fixe, bouton « ↓ »), curseur rendu après émoji / photo |
| `app/test/background_mode_test.dart` | Option arrière-plan : désactivée par défaut, enregistrée (lue au démarrage du téléphone), transmise au service ; absente hors Android |
| `app/test/presence_test.dart` | Liste surveillée, point vert / gris, ajout de contact, présence oubliée à la déconnexion |
| `app/test/chat_notifications_test.dart` | Rien si visible ; message caché (son, réponse) ; empilement limité ; frappe annoncée une fois puis mise à jour silencieuse et espacée ; effacement ; retour dans l'appli ; réponse depuis la notification (brouillon conservé) |
| `app/tool/check_windows_notifications.dart` | Vrais toasts Windows (`flutter run -d windows -t tool/check_windows_notifications.dart`, affiche OK / ÉCHEC) : affichage avec champ de réponse, mise à jour sur place, remplacement, retrait. Deux identités en mémoire et relais dans le processus : l'ID de l'utilisateur n'est jamais utilisé. Pas de paquet `integration_test` : sa partie Android exige un plugin Gradle absent du cache et casserait la compilation de l'APK hors ligne |

- Le test de bout en bout utilise `test()` et non `testWidgets()` : sans binding de widgets, les vraies sockets et les vrais timers fonctionnent.
- Pour simuler plusieurs clients dans un même process, on injecte `MemoryStore` dans `IdentityService` (`SharedPreferences` est un singleton).
- `TypingDots` tourne en boucle : dans un test de widgets, utiliser `pump(durée)`, jamais `pumpAndSettle()` quand les points sont affichés.
- `ChatScreen` reçoit ses dépendances matérielles par injection (`pickImage`, `cameraAvailable`, `createRecorder`, `createAudioBackend`) : dans les tests, utiliser `FakeVoiceRecorder` et `FakeAudioBackend` (`test/fakes.dart`). `VoicePlayer` ne crée son lecteur qu'à la première lecture.
