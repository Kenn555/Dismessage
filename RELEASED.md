# Notes de version

Les nouveautés de chaque version de Dismessage, la plus récente en premier.

---

## 0.4.0 — 6 novembre 2026

### Nouveautés

- **Vue caméra en direct.** Bouton caméra en haut de la conversation : demandez à voir la caméra de votre interlocuteur (webcam ou appareil photo). Il répond « Autoriser » ou « Refuser », et rien n'est filmé sans son accord. La vue apparaît au-dessus du champ de saisie, de la moitié de sa largeur ; sur grand écran, en bas de la liste des conversations.
- **Plein écran.** Cliquez sur la vue, ou appuyez sur **F11** ou **Ctrl+Alt+F** ; Échap pour revenir. L'image passe à la meilleure résolution que la caméra et le réseau permettent, et le bandeau de la conversation s'affiche en bas de l'écran pour continuer à écrire.
- **Caméra dans le mode superposition.** La vue s'affiche à gauche du bandeau, à sa hauteur initiale. Un clic dessus (ou Ctrl+Alt+F, depuis n'importe quelle appli) la met en plein écran, puis le bandeau revient.
- **Envoyer plusieurs fichiers d'un coup.** Le trombone permet d'en choisir jusqu'à 20. Votre interlocuteur n'a qu'une validation à donner : « Tout accepter » ou « Tout refuser ». Les fichiers arrivent les uns après les autres, dans une seule bulle.
- **Coller des fichiers de tout type** : Ctrl+V dans une conversation ou le bandeau, après les avoir copiés dans l'Explorateur (ou coller dans le navigateur). Un fichier qui est une image s'affiche comme les autres images.
- **Coller dans le mode superposition.** Une ligne demande confirmation : Entrée envoie, Échap annule. Le texte copié se colle aussi dans le bandeau.
- **Répondre depuis le bandeau** : Ctrl+O accepte et Ctrl+N refuse une demande de caméra ou les fichiers reçus ; Ctrl+K coupe la caméra.
- **Choix de la caméra et du micro** dans les Réglages de l'accueil. Le choix sert à la vue caméra, aux photos prises à la webcam et aux messages vocaux. Le son reste joué sur la sortie audio par défaut de l'appareil.

### Sécurité et vie privée

- La caméra ne s'allume qu'après votre accord, demandé à chaque fois : il n'est jamais mémorisé. Touche Entrée ou notification ne peuvent pas y répondre à votre place.
- Tant que votre caméra est partagée, un bandeau rouge l'indique, avec ce que voit l'autre et un bouton « Arrêter ». Elle se coupe si vous réduisez l'application ou la mettez en arrière-plan, et si la conversation se termine.
- Les images de la vue sont chiffrées de bout en bout, comme tout le reste, et jamais enregistrées.
- Après un refus, les nouvelles demandes sont écartées pendant 10 secondes.
- Android : la permission Caméra est désormais demandée, à la première utilisation de la vue comme à la première photo.

### Améliorations

- **Application plus légère.** La frappe de l'interlocuteur ne redessine plus toute la conversation à chaque lettre, les conversations cachées n'animent ni ne décodent plus rien, les points « … » consomment beaucoup moins, et le bandeau ne se recopie plus à chaque image.
- **Vue caméra fluide** : jusqu'à 30 images par seconde à intervalles réguliers, même par un serveur lointain. La taille et la qualité suivent le réseau, et les images qui arrivent par paquets sont redistribuées à un rythme régulier. La cadence dépend aussi de la caméra : dans une pièce sombre, une webcam peut descendre autour de 15 images par seconde.

### Corrections

- **Mode superposition : ce qu'on tapait pouvait ne pas s'afficher.** Le bandeau reprend toujours le clavier en entrant, et une image perdue en route est réaffichée en moins d'une seconde.

---

## 0.3.0 — 29 octobre 2026

### Nouveautés

- **Plusieurs photos d'un coup** : choisissez jusqu'à 10 images dans la galerie, chacune part dans sa propre bulle.
- **Coller une image** dans le champ de saisie : Ctrl+V sur Windows (image copiée, capture d'écran ou fichiers images copiés dans l'Explorateur), coller dans le navigateur, ou le presse-papiers du clavier sur Android. Les images s'affichent d'abord pour confirmation, rien ne part par erreur.
- **Mode superposition (Windows)** : bouton dans l'en-tête de la conversation, ou **Ctrl+Alt+D** depuis n'importe quelle appli. La conversation devient un bandeau translucide de deux lignes en haut de l'écran (il s'agrandit tout seul pour un long texte), aux bords en fondu, par-dessus les autres fenêtres : l'interlocuteur en blanc (seulement ses deux derniers messages : celui en cours et le précédent, plus pâle), votre saisie en bleu juste en dessous (votre dernier message y reste jusqu'à ce que vous tapiez de nouveau). Les clics passent au travers : vous pouvez regarder une vidéo ou lire une page derrière tout en continuant d'écrire. Entrée envoie, Échap ou Ctrl+Alt+D revient à la fenêtre normale ; après un clic derrière le bandeau, Ctrl+Alt+D lui rend le clavier.

### Sécurité et vie privée

- Le bandeau est, comme la fenêtre, absent des captures et enregistrements d'écran.
- Le presse-papiers n'est lu qu'au moment où vous collez dans la conversation.

---

## 0.2.0 — 8 octobre 2026

Une version centrée sur la sécurité et la vie privée, en vue de l'ouverture au public.

### ⚠️ À lire avant de mettre à jour

- **Mise à jour obligatoire.** Les anciennes versions ne peuvent plus se connecter : elles affichent « installez la nouvelle version ».
- **Android : désinstallez d'abord l'ancienne version.** L'application est désormais signée avec sa clé définitive, et Android refuse de l'installer par-dessus l'ancienne. Vos contacts enregistrés sur le téléphone seront perdus.
- **Votre ID peut changer.** Les IDs sont maintenant attribués par le serveur. Sauf période de transition décidée par l'éditeur, chaque installation reçoit un nouvel ID à sa première connexion : partagez-le à nouveau avec vos contacts.

### Nouveautés

- **Chiffrement de bout en bout.** Tout le contenu des conversations (texte, frappe en direct, réactions, photos, vocaux, fichiers) est chiffré sur votre appareil. Le serveur ne transmet plus que des données illisibles, et refuse tout ce qui n'est pas chiffré. Les clés sont créées pour chaque conversation, puis oubliées.
- **Code de sécurité.** Menu ⋮ d'une conversation → « Vérifier le chiffrement » : comparez le code avec votre interlocuteur pour vous assurer que personne ne s'est interposé.
- **Bloquer quelqu'un**, depuis sa demande de conversation, depuis un contact ou depuis la conversation. Ses demandes sont ensuite ignorées, sans qu'il le sache.
- **« Seuls mes contacts peuvent me joindre »** : les demandes des inconnus sont ignorées, sans notification.
- **Réglages sur toutes les plateformes** : options de confidentialité et liste des IDs bloqués, avec « Débloquer ».
- **À propos** : version, lien vers le code source sur GitHub, licences des composants, mentions légales.
- **Pages légales** : mentions légales, politique de confidentialité et conditions d'utilisation, dans l'application et sur le web.
- **Accueil au premier lancement** : confirmation de l'âge (18 ans et plus) et acceptation des conditions, avant toute connexion au serveur.

### Sécurité et vie privée

- **Captures d'écran bloquées** sur Android et Windows : captures, enregistrements d'écran, partage d'écran et miniature des applications récentes ne montrent plus les conversations.
- **IDs protégés contre le vol.** Le serveur choisit et signe chaque ID : personne ne peut s'approprier celui d'un autre, même après un redémarrage du serveur.
- **Protection contre les abus** : limites de demandes de conversation, d'enregistrements, de nouveaux IDs et de connexions par adresse. Un usage normal ne les atteint jamais ; un transfert de fichier très rapide est seulement ralenti.
- **Version web** : le moteur d'affichage est servi par le site lui-même, et non plus par les serveurs de Google.

### Améliorations

- Sur un petit téléphone, les boutons de l'en-tête sont regroupés dans un menu ⋮.
- Un ID différent par serveur, retrouvé quand on revient au serveur précédent.
- Les refus du serveur (limite atteinte, version trop ancienne) sont expliqués à l'écran.

---

## 0.1.0 — 6 octobre 2026

Première version.

### Messagerie en direct

- Voir son interlocuteur écrire **caractère par caractère**, avec les trois points `…` quand il fait une pause.
- **ID à 9 chiffres** pour se joindre (`482 913 075`), masqué à l'écran (`482 *** 075`) avec un bouton pour l'afficher.
- **Demandes de conversation** à accepter ou refuser, **contacts** enregistrés sur l'appareil, **présence** en ligne / hors ligne.
- **Plusieurs conversations à la fois**, avec avatars flottants sur téléphone et barre latérale sur grand écran.
- Réponses (glisser une bulle), réactions, émojis, saisie multiligne.

### Médias

- **Photos** (appareil photo, galerie, webcam sur PC) : une miniature floutée part d'abord, l'image nette n'est transférée que si le destinataire l'ouvre. Position GPS supprimée.
- **Messages vocaux**.
- **Fichiers** jusqu'à 512 Mo, acceptés ou refusés par le destinataire, enregistrés dans ses téléchargements.

### Partout

- Applications **Android**, **Windows** (installateur, lancement au démarrage) et **web**.
- **Notifications** des messages, de la frappe et des demandes, avec réponse directe depuis la notification (Android, Windows).
- **Arrière-plan Android** : rester joignable écran éteint, dès le démarrage du téléphone.
- Messages **éphémères** : rien n'est enregistré, ni sur le serveur ni sur l'appareil.
